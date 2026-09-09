import Foundation
import SQLite3

/// 本机数据库。**这是"脱离服务器"的地基** ——
/// 进度、收藏、难点、录音索引、额度全落在这儿，断网照常用。
///
/// 为什么用 SQLite 而不是 SwiftData：
/// 材料包是 CDN 上**预先做好的 .sqlite 文件**，下下来 `ATTACH` 一句就能查；
/// 换成 SwiftData 得逐条导入，几万句要导半天。
///
/// 只做四件事：开库、迁移、执行、查询。不做 ORM ——
/// 这个项目的表就六张，套一层对象映射只会多一层出错的地方。
final class DB {
    /// 用户数据。删不得。
    static let user = DB(name: "user.sqlite")

    private var h: OpaquePointer?
    private let q: DispatchQueue          // SQLite 句柄不是线程安全的，统一串行
    let path: String

    private init(name: String) {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        path = dir.appendingPathComponent(name).path
        q = DispatchQueue(label: "db." + name)
    }

    /// 测试专用：换一个库文件（不碰真的 user.sqlite）
    init(testPath: String) {
        path = testPath
        q = DispatchQueue(label: "db.test")
    }

    // MARK: 开库

    enum Err: Error, CustomStringConvertible {
        case open(String), step(String), prepare(String, String)
        var description: String {
            switch self {
            case .open(let m):           return "开库失败：\(m)"
            case .step(let m):           return "执行失败：\(m)"
            case .prepare(let s, let m): return "SQL 有问题：\(m)\n\(s)"
            }
        }
    }

    @discardableResult
    func open() throws -> DB {
        try q.sync {
            guard h == nil else { return }
            var p: OpaquePointer?
            // FULLMUTEX：句柄自己也做互斥，双保险（上面已经串行了）
            let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
            guard sqlite3_open_v2(path, &p, flags, nil) == SQLITE_OK, let p else {
                let m = p.map { String(cString: sqlite3_errmsg($0)) } ?? "未知"
                sqlite3_close_v2(p)
                throw Err.open(m)
            }
            h = p
            // WAL：读写不互相挡。断电时也比默认的 rollback journal 稳。
            sqlite3_exec(p, "PRAGMA journal_mode=WAL", nil, nil, nil)
            sqlite3_exec(p, "PRAGMA foreign_keys=ON", nil, nil, nil)
            sqlite3_busy_timeout(p, 3000)
        }
        return self
    }

    func close() {
        q.sync { if let h { sqlite3_close_v2(h) }; h = nil }
    }

    // MARK: 迁移
    //
    // 靠 SQLite 自带的 user_version 记版本号。每一版只往后加，**永不改写历史** ——
    // 用户手机上装的是哪一版不知道，只能一版一版往上补。

    private static let migrations: [String] = [
        // v1：第一版表结构
        """
        CREATE TABLE IF NOT EXISTS progress(
            sent_id    TEXT PRIMARY KEY,
            reps       INTEGER NOT NULL DEFAULT 0,
            ease       REAL    NOT NULL DEFAULT 2.5,
            due        REAL    NOT NULL DEFAULT 0,
            last_score REAL,
            updated_at REAL    NOT NULL DEFAULT 0);
        CREATE INDEX IF NOT EXISTS ix_progress_due ON progress(due);

        CREATE TABLE IF NOT EXISTS fav(
            sent_id TEXT PRIMARY KEY,
            at      REAL NOT NULL);

        CREATE TABLE IF NOT EXISTS mark(
            id      INTEGER PRIMARY KEY AUTOINCREMENT,
            sent_id TEXT NOT NULL,
            a       REAL NOT NULL,
            b       REAL NOT NULL,
            note    TEXT NOT NULL DEFAULT '',
            at      REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS ix_mark_sent ON mark(sent_id);

        -- 录音只记索引，文件在 Documents/Recordings 下，永远不上传（方案红线）
        CREATE TABLE IF NOT EXISTS rec(
            id      INTEGER PRIMARY KEY AUTOINCREMENT,
            sent_id TEXT NOT NULL,
            path    TEXT NOT NULL,
            score   REAL,
            dur     REAL NOT NULL DEFAULT 0,
            at      REAL NOT NULL);
        CREATE INDEX IF NOT EXISTS ix_rec_sent ON rec(sent_id);

        -- 额度：kind=ai/material/import，period 是"哪一天/哪一周"，跨期自动归零
        CREATE TABLE IF NOT EXISTS quota(
            kind   TEXT NOT NULL,
            period TEXT NOT NULL,
            used   INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY(kind, period));

        -- 解锁记录：via = member（会员）/ ad（看广告）/ reward（奖励）
        CREATE TABLE IF NOT EXISTS unlock(
            pack_id TEXT NOT NULL,
            sent_id TEXT NOT NULL,
            via     TEXT NOT NULL,
            at      REAL NOT NULL,
            PRIMARY KEY(pack_id, sent_id));
        """,

        // v2：本地要能自己排复习，就得有句子的基本信息（复习卡片上要显示原文译文），
        // 以前这些全从服务器现取。另外加一张 meta 表存"迁没迁过"这类小状态。
        """
        CREATE TABLE IF NOT EXISTS sent(
            id   TEXT PRIMARY KEY,
            word TEXT NOT NULL DEFAULT '',
            en   TEXT NOT NULL DEFAULT '',
            cn   TEXT NOT NULL DEFAULT '',
            grp  TEXT NOT NULL DEFAULT '',
            tag  TEXT NOT NULL DEFAULT '',
            kind TEXT NOT NULL DEFAULT 'sent');
        CREATE INDEX IF NOT EXISTS ix_sent_word ON sent(word);

        CREATE TABLE IF NOT EXISTS meta(
            k TEXT PRIMARY KEY,
            v TEXT NOT NULL);
        """
    ]

    /// 当前代码带的库版本
    static var latestVersion: Int { migrations.count }

    /// 跑迁移。跑几遍都一样（幂等），这是验收标准之一。
    func migrate() throws {
        try open()
        try q.sync {
            guard let h else { throw Err.open("没开库") }
            var v = Int(try Self.scalarInt(h, "PRAGMA user_version"))
            while v < Self.migrations.count {
                sqlite3_exec(h, "BEGIN", nil, nil, nil)
                do {
                    try Self.exec(h, Self.migrations[v])
                    v += 1
                    try Self.exec(h, "PRAGMA user_version=\(v)")
                    sqlite3_exec(h, "COMMIT", nil, nil, nil)
                } catch {
                    sqlite3_exec(h, "ROLLBACK", nil, nil, nil)
                    throw error
                }
            }
        }
    }

    var version: Int {
        (try? q.sync { () throws -> Int in
            guard let h else { return 0 }
            return try Self.scalarInt(h, "PRAGMA user_version")
        }) ?? 0
    }

    // MARK: 执行与查询

    /// 写。`?` 占位，参数按顺序传。
    func run(_ sql: String, _ args: [Any?] = []) throws {
        try open()
        try q.sync {
            guard let h else { throw Err.open("没开库") }
            let st = try Self.prepare(h, sql, args)
            defer { sqlite3_finalize(st) }
            let r = sqlite3_step(st)
            guard r == SQLITE_DONE || r == SQLITE_ROW else {
                throw Err.step(String(cString: sqlite3_errmsg(h)))
            }
        }
    }

    /// 读。每行是一个 [列名: 值] 字典。
    func rows(_ sql: String, _ args: [Any?] = []) throws -> [[String: Any]] {
        try open()
        return try q.sync {
            guard let h else { throw Err.open("没开库") }
            let st = try Self.prepare(h, sql, args)
            defer { sqlite3_finalize(st) }
            var out: [[String: Any]] = []
            while sqlite3_step(st) == SQLITE_ROW {
                var row: [String: Any] = [:]
                for i in 0..<sqlite3_column_count(st) {
                    let name = String(cString: sqlite3_column_name(st, i))
                    switch sqlite3_column_type(st, i) {
                    case SQLITE_INTEGER: row[name] = Int(sqlite3_column_int64(st, i))
                    case SQLITE_FLOAT:   row[name] = sqlite3_column_double(st, i)
                    case SQLITE_NULL:    break                     // 缺键＝NULL，不塞 NSNull
                    default:
                        if let c = sqlite3_column_text(st, i) { row[name] = String(cString: c) }
                    }
                }
                out.append(row)
            }
            return out
        }
    }

    func row(_ sql: String, _ args: [Any?] = []) throws -> [String: Any]? {
        try rows(sql, args).first
    }

    // MARK: 内部

    /// 绑定字符串时必须用 TRANSIENT：让 SQLite 自己复制一份。
    /// 用 STATIC 的话 Swift 那边的临时字符串一出作用域就没了，读出来是乱码（经典坑）。
    private static let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func prepare(_ h: OpaquePointer, _ sql: String, _ args: [Any?]) throws -> OpaquePointer? {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(h, sql, -1, &st, nil) == SQLITE_OK else {
            throw Err.prepare(sql, String(cString: sqlite3_errmsg(h)))
        }
        for (i, a) in args.enumerated() {
            let k = Int32(i + 1)
            switch a {
            case nil:                 sqlite3_bind_null(st, k)
            case let v as Int:        sqlite3_bind_int64(st, k, Int64(v))
            case let v as Int64:      sqlite3_bind_int64(st, k, v)
            case let v as Bool:       sqlite3_bind_int64(st, k, v ? 1 : 0)
            case let v as Double:     sqlite3_bind_double(st, k, v)
            case let v as String:     sqlite3_bind_text(st, k, v, -1, TRANSIENT)
            case let v as Data:       _ = v.withUnsafeBytes { sqlite3_bind_blob(st, k, $0.baseAddress, Int32(v.count), TRANSIENT) }
            default:                  sqlite3_bind_text(st, k, "\(a!)", -1, TRANSIENT)
            }
        }
        return st
    }

    /// 一次执行多条语句（迁移脚本用）
    private static func exec(_ h: OpaquePointer, _ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(h, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? "未知"
            sqlite3_free(err)
            throw Err.step(m)
        }
    }

    private static func scalarInt(_ h: OpaquePointer, _ sql: String) throws -> Int {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(h, sql, -1, &st, nil) == SQLITE_OK else {
            throw Err.prepare(sql, String(cString: sqlite3_errmsg(h)))
        }
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int64(st, 0)) : 0
    }
}
