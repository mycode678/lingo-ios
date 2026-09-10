import Foundation
import CryptoKit

/// 材料包：装、列、查、删。
///
/// **这是"脱离服务器"的最后一块**：包里自带句子、译文和预先算好的词边界，
/// 装完就能断网练，一次服务器请求都不用发。
@MainActor
final class CatalogService: ObservableObject {
    static let shared = CatalogService(db: .user)
    private let db: DB
    init(db: DB) { self.db = db }

    struct Manifest: Codable {
        var id: String, name: String, version: Int
        var sentences: Int
        var levels: [String: Int]
        var audio_bytes: Int
        var db_sha256: String
        var restricted: Bool
    }

    struct Pack: Identifiable {
        var id: String, name: String, version: Int
        var sentences: Int, restricted: Bool, installedAt: Double
    }

    struct Sent: Identifiable {
        var id: String, en: String, cn: String
        var level: Int, dur: Double, audio: URL
    }

    enum Err: LocalizedError {
        case badManifest, checksum, restricted
        var errorDescription: String? {
            switch self {
            case .badManifest: return "包里没有 manifest.json，或者格式不对"
            case .checksum:    return "包内容校验不过，可能没下全或被改过"
            case .restricted:  return "这个包有版权限制，这个账号装不了"
            }
        }
    }

    // MARK: 装在哪

    static var root: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Packs", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func dir(_ id: String) -> URL { Self.root.appendingPathComponent(id, isDirectory: true) }

    /// 版权受限的包能不能装。
    /// 方案原话：「词典例句不开，除非用户主动导入词典文件……当然我自己要可以用」。
    /// 判断放在这一层（不是界面藏起来），这样以后加多少入口都绕不过去。
    /// 真正的防线其实是"这个包根本不往 CDN 上放"，这里是第二道。
    var canInstallRestricted: Bool {
        UserDefaults.standard.string(forKey: "owner.key")?.isEmpty == false
    }

    // MARK: 装

    /// 从一个本地 zip 装（下载好的、或者用户自己导入的）
    @discardableResult
    func install(zip: URL) throws -> Pack {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("pack-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: staging) }
        try PackZip.unzip(zip, to: staging)

        guard let mdata = try? Data(contentsOf: staging.appendingPathComponent("manifest.json")),
              let m = try? JSONDecoder().decode(Manifest.self, from: mdata)
        else { throw Err.badManifest }

        if m.restricted && !canInstallRestricted { throw Err.restricted }

        // 校验和：下了一半、或者被人改过，这里就拦住，别等练到一半才崩
        let dbFile = staging.appendingPathComponent("pack.sqlite")
        guard let raw = try? Data(contentsOf: dbFile) else { throw Err.badManifest }
        let sha = SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined()
        guard sha == m.db_sha256 else { throw Err.checksum }

        // 原子替换：先搬到位再记账，中途挂了不会留下"记着装了但文件没有"的状态
        let dst = dir(m.id)
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.moveItem(at: staging, to: dst)

        try db.run("""
            INSERT INTO pack(id, name, version, sentences, restricted, installed_at)
            VALUES(?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET name=excluded.name, version=excluded.version,
                sentences=excluded.sentences, installed_at=excluded.installed_at
            """, [m.id, m.name, m.version, m.sentences, m.restricted ? 1 : 0,
                  Date().timeIntervalSince1970])

        return Pack(id: m.id, name: m.name, version: m.version,
                    sentences: m.sentences, restricted: m.restricted,
                    installedAt: Date().timeIntervalSince1970)
    }

    // MARK: 列 / 删

    func packs() -> [Pack] {
        let rows = (try? db.rows("SELECT * FROM pack ORDER BY installed_at DESC")) ?? []
        return rows.map {
            Pack(id: $0["id"] as? String ?? "", name: $0["name"] as? String ?? "",
                 version: $0["version"] as? Int ?? 1, sentences: $0["sentences"] as? Int ?? 0,
                 restricted: ($0["restricted"] as? Int ?? 0) == 1,
                 installedAt: $0["installed_at"] as? Double ?? 0)
        }
    }

    /// 删包只删材料。**用户数据一条都不动** —— 进度、收藏、难点、录音
    /// 记的是句子 id，包重新装回来它们还在。这是三个库分开存的意义。
    func remove(_ id: String) {
        try? FileManager.default.removeItem(at: dir(id))
        try? db.run("DELETE FROM pack WHERE id=?", [id])
    }

    // MARK: 查（包自己那份 sqlite）

    private func open(_ id: String) -> DB? {
        let f = dir(id).appendingPathComponent("pack.sqlite")
        guard FileManager.default.fileExists(atPath: f.path) else { return nil }
        return try? DB(testPath: f.path).open()
    }

    func sentences(_ packId: String, level: Int? = nil, limit: Int = 200) -> [Sent] {
        guard let p = open(packId) else { return [] }
        let sql = level == nil
            ? "SELECT * FROM sentences ORDER BY level, id LIMIT ?"
            : "SELECT * FROM sentences WHERE level=? ORDER BY id LIMIT ?"
        let args: [Any?] = level == nil ? [limit] : [level!, limit]
        let rows = (try? p.rows(sql, args)) ?? []
        let adir = dir(packId).appendingPathComponent("audio")
        return rows.map {
            Sent(id: $0["id"] as? String ?? "", en: $0["en"] as? String ?? "",
                 cn: $0["cn"] as? String ?? "", level: $0["level"] as? Int ?? 1,
                 dur: $0["dur"] as? Double ?? 0,
                 audio: adir.appendingPathComponent($0["audio"] as? String ?? ""))
        }
    }

    /// 一句的词边界（包里预先算好的，装机即用）
    func words(_ packId: String, _ sentId: String) -> [(w: String, s: Double, e: Double)] {
        guard let p = open(packId) else { return [] }
        let rows = (try? p.rows("SELECT word, s, e FROM words WHERE sent_id=? ORDER BY idx",
                                [sentId])) ?? []
        return rows.compactMap {
            guard let w = $0["word"] as? String,
                  let s = $0["s"] as? Double, let e = $0["e"] as? Double else { return nil }
            return (w, s, e)
        }
    }
}
