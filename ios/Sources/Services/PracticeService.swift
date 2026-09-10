import Foundation

/// 练习进度与复习排期 —— **全在本机算、本机存**。
///
/// 以前这一套在服务器上（`/api/grade`）：打个分要发一次网络请求，
/// 没网就练不了。方案定的是完全脱离服务器，所以搬到手机上。
/// 服务器那份降级成"顺手备份"，成不成都不影响用。
@MainActor
final class PracticeService {
    static let shared = PracticeService(db: .user)
    private let db: DB
    init(db: DB) { self.db = db }

    /// 一句的进度
    struct Prog {
        var reps: Int = 0
        var ease: Double = 2.5
        var due: Double = 0
        var lastScore: Double?
    }

    // MARK: 打分排期（SM-2 简化版）
    //
    // q: 1 没听懂 / 2 勉强 / 3 会了 / 4 脱口而出
    //
    // 为什么不照搬 Anki 的完整 SM-2：这是**听力**，不是背单词。
    // 听懂过一次不代表下次能听懂，间隔涨得比背词慢一档更合适；
    // 而"没听懂"必须立刻回到今天，不能推到明天 —— 走路时练，
    // 一次通勤里就该把没听懂的再撞几遍。

    /// 打分并返回下一次该复习的时间戳
    @discardableResult
    func grade(_ sentId: String, _ q: Int, score: Double? = nil,
               meta: [String: String]? = nil) -> Double {
        let now = Date().timeIntervalSince1970
        var p = progress(sentId) ?? Prog()

        if q <= 1 {
            // 没听懂：从头来，10 分钟后再撞一次（还在这次练习里）
            p.reps = 0
            p.ease = max(1.3, p.ease - 0.2)
            p.due = now + 600
        } else {
            p.reps += 1
            // 打得越好，ease 往上走一点点；勉强则往下压
            p.ease = min(2.8, max(1.3, p.ease + (q == 2 ? -0.15 : (q == 4 ? 0.10 : 0))))
            let days: Double
            switch p.reps {
            case 1:  days = q == 2 ? 0.02 : (q == 4 ? 1 : 0.5)   // 0.02 天≈30 分钟
            case 2:  days = q == 2 ? 0.5 : (q == 4 ? 3 : 2)
            default:
                let prev = max(1, p.reps - 1)
                days = min(180, Double(prev) * p.ease * (q == 2 ? 0.6 : (q == 4 ? 1.3 : 1)))
            }
            p.due = now + days * 86400
        }
        if let score { p.lastScore = score }

        try? db.run("""
            INSERT INTO progress(sent_id, reps, ease, due, last_score, updated_at)
            VALUES(?,?,?,?,?,?)
            ON CONFLICT(sent_id) DO UPDATE SET
                reps=excluded.reps, ease=excluded.ease, due=excluded.due,
                last_score=COALESCE(excluded.last_score, progress.last_score),
                updated_at=excluded.updated_at
            """, [sentId, p.reps, p.ease, p.due, p.lastScore, now])

        if let meta { remember(sentId, meta) }
        bumpToday()
        return p.due
    }

    // MARK: 每天练了多少（连续天数、热力图都靠它）
    //
    // 以前这两个数字是找服务器要的，断网就变成"你一天都没练过"——
    // 用户攒了两个月的连打卡被显示成 0，比不显示更伤人。现在本机记。

    private func dayIndex(_ t: Double = Date().timeIntervalSince1970) -> Int {
        var c = Calendar.current; c.timeZone = .current
        return Int(c.startOfDay(for: Date(timeIntervalSince1970: t)).timeIntervalSince1970 / 86400)
    }

    private func bumpToday() {
        try? db.run("""
            INSERT INTO day(d, n) VALUES(?, 1)
            ON CONFLICT(d) DO UPDATE SET n = n + 1
            """, [dayIndex()])
    }

    /// 连着练了多少天（今天没练也算，只要昨天以前是连着的就不断链）
    func streak() -> Int {
        let rows = (try? db.rows("SELECT d FROM day WHERE n > 0 ORDER BY d DESC LIMIT 400")) ?? []
        let days = Set(rows.compactMap { $0["d"] as? Int })
        guard !days.isEmpty else { return 0 }
        let today = dayIndex()
        // 今天还没练时从昨天往回数，不然一早打开 App 就显示"连打断了"
        var cur = days.contains(today) ? today : today - 1
        var n = 0
        while days.contains(cur) { n += 1; cur -= 1 }
        return n
    }

    /// 最近 N 天各练了多少（热力图用）
    func heat(_ days: Int = 120) -> [Int: Int] {
        let from = dayIndex() - days
        let rows = (try? db.rows("SELECT d, n FROM day WHERE d >= ?", [from])) ?? []
        var out: [Int: Int] = [:]
        for r in rows { if let d = r["d"] as? Int { out[d] = r["n"] as? Int ?? 0 } }
        return out
    }

    func progress(_ sentId: String) -> Prog? {
        guard let r = try? db.row("SELECT * FROM progress WHERE sent_id=?", [sentId]) else { return nil }
        return Prog(reps: r["reps"] as? Int ?? 0,
                    ease: r["ease"] as? Double ?? 2.5,
                    due: r["due"] as? Double ?? 0,
                    lastScore: r["last_score"] as? Double)
    }

    /// 句子的基本信息也存一份 —— 复习卡片上要显示原文译文，
    /// 不能每翻一张卡就去服务器要一次。
    func remember(_ sentId: String, _ m: [String: String]) {
        try? db.run("""
            INSERT INTO sent(id, word, en, cn, grp, tag, kind) VALUES(?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET
                word=excluded.word, en=excluded.en, cn=excluded.cn,
                grp=excluded.grp, tag=excluded.tag, kind=excluded.kind
            """, [sentId, m["word"] ?? "", m["en"] ?? "", m["cn"] ?? "",
                  m["grp"] ?? "", m["tag"] ?? "", m["kind"] ?? "sent"])
    }

    // MARK: 今天该复习哪些

    struct Card {
        var src: String, word: String, en: String, cn: String
        var grp: String, tag: String, reps: Int, due: Double
    }

    /// 到期的（按最该复习的排前面）
    func due(_ limit: Int = 40) -> [Card] {
        let now = Date().timeIntervalSince1970
        let rows = (try? db.rows("""
            SELECT p.sent_id AS src, p.reps, p.due,
                   COALESCE(s.word,'') AS word, COALESCE(s.en,'') AS en,
                   COALESCE(s.cn,'') AS cn, COALESCE(s.grp,'') AS grp,
                   COALESCE(s.tag,'') AS tag
            FROM progress p LEFT JOIN sent s ON s.id = p.sent_id
            WHERE p.due <= ? ORDER BY p.due ASC LIMIT ?
            """, [now, limit])) ?? []
        return rows.map {
            Card(src: $0["src"] as? String ?? "", word: $0["word"] as? String ?? "",
                 en: $0["en"] as? String ?? "", cn: $0["cn"] as? String ?? "",
                 grp: $0["grp"] as? String ?? "", tag: $0["tag"] as? String ?? "",
                 reps: $0["reps"] as? Int ?? 0, due: $0["due"] as? Double ?? 0)
        }
    }

    func dueCount() -> Int {
        let now = Date().timeIntervalSince1970
        return (try? db.row("SELECT COUNT(*) AS n FROM progress WHERE due <= ?", [now])?["n"] as? Int) as? Int ?? 0
    }

    /// 一共碰过多少句（「没练过的还剩几句」要拿它减）
    func practicedCount() -> Int {
        (try? db.row("SELECT COUNT(*) AS n FROM progress")?["n"] as? Int) as? Int ?? 0
    }

    /// 今天练了多少句
    func todayCount() -> Int {
        var c = Calendar.current
        c.timeZone = .current
        let start = c.startOfDay(for: Date()).timeIntervalSince1970
        return (try? db.row("SELECT COUNT(*) AS n FROM progress WHERE updated_at >= ?", [start])?["n"] as? Int) as? Int ?? 0
    }

    // MARK: 收藏

    func isFav(_ sentId: String) -> Bool {
        ((try? db.row("SELECT 1 AS x FROM fav WHERE sent_id=?", [sentId])) ?? nil) != nil
    }

    func setFav(_ sentId: String, _ on: Bool, meta: [String: String]? = nil) {
        if on {
            try? db.run("INSERT OR REPLACE INTO fav(sent_id, at) VALUES(?,?)",
                        [sentId, Date().timeIntervalSince1970])
            if let meta { remember(sentId, meta) }
        } else {
            try? db.run("DELETE FROM fav WHERE sent_id=?", [sentId])
        }
    }

    func favCount() -> Int {
        (try? db.row("SELECT COUNT(*) AS n FROM fav")?["n"] as? Int) as? Int ?? 0
    }

    // MARK: 难点（一句里标出来的几段）

    func marks(_ sentId: String) -> [(Double, Double)] {
        let rows = (try? db.rows("SELECT a, b FROM mark WHERE sent_id=? ORDER BY a", [sentId])) ?? []
        return rows.compactMap {
            guard let a = $0["a"] as? Double, let b = $0["b"] as? Double else { return nil }
            return (a, b)
        }
    }

    /// 整句的难点一次写完（先删后插）—— 难点本来就是按句子整组改的，
    /// 逐条增删要维护 id，没必要。
    func setMarks(_ sentId: String, _ list: [(Double, Double)]) {
        try? db.run("DELETE FROM mark WHERE sent_id=?", [sentId])
        let now = Date().timeIntervalSince1970
        for (a, b) in list {
            try? db.run("INSERT INTO mark(sent_id, a, b, note, at) VALUES(?,?,?,'',?)",
                        [sentId, a, b, now])
        }
    }

    // MARK: 录音（**只在这台手机上**，没有任何上传路径，见 ios/guard-privacy.sh）

    static var recDir: URL {
        let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// 把刚录的这条留下来并记账。每句只留最近 3 条 ——
    /// 不设上限的话练几个月手机就被自己的录音塞满了。
    @discardableResult
    func addRec(_ sentId: String, from src: URL, score: Double?, dur: Double) -> URL? {
        let safe = sentId.replacingOccurrences(of: "/", with: "_")
        let dst = Self.recDir.appendingPathComponent("\(safe)-\(Int(Date().timeIntervalSince1970)).wav")
        do { try FileManager.default.copyItem(at: src, to: dst) } catch { return nil }
        try? db.run("INSERT INTO rec(sent_id, path, score, dur, at) VALUES(?,?,?,?,?)",
                    [sentId, dst.lastPathComponent, score, dur, Date().timeIntervalSince1970])
        pruneRecs(sentId, keep: 3)
        return dst
    }

    func recs(_ sentId: String) -> [(path: String, score: Double?, at: Double)] {
        let rows = (try? db.rows("SELECT path, score, at FROM rec WHERE sent_id=? ORDER BY at DESC",
                                 [sentId])) ?? []
        return rows.map { ($0["path"] as? String ?? "", $0["score"] as? Double, $0["at"] as? Double ?? 0) }
    }

    func recCount() -> Int {
        (try? db.row("SELECT COUNT(*) AS n FROM rec")?["n"] as? Int) as? Int ?? 0
    }

    private func pruneRecs(_ sentId: String, keep: Int) {
        let all = recs(sentId)
        guard all.count > keep else { return }
        for old in all.dropFirst(keep) {
            try? FileManager.default.removeItem(at: Self.recDir.appendingPathComponent(old.path))
            try? db.run("DELETE FROM rec WHERE sent_id=? AND path=?", [sentId, old.path])
        }
    }

    // MARK: 从服务器搬一次家
    //
    // 老用户（我自己）在服务器上已经攒了进度，第一次跑本地版时搬过来一次。
    // 失败也没关系 —— 下次启动还会再试，而且不影响新用户。

    func seedFromServerIfNeeded() async {
        let done = (try? db.row("SELECT v FROM meta WHERE k='seeded'")?["v"] as? String) as? String
        guard done == nil, !Demo.on else { return }
        guard let cards = try? await Api.due(500), !cards.isEmpty else { return }
        for c in cards {
            remember(c.src, ["word": c.word ?? "", "en": c.en, "cn": c.cn ?? "",
                             "grp": c.grp ?? "", "tag": c.tag ?? "", "kind": c.kind ?? "sent"])
            try? db.run("""
                INSERT INTO progress(sent_id, reps, ease, due, updated_at) VALUES(?,?,?,?,?)
                ON CONFLICT(sent_id) DO NOTHING
                """, [c.src, c.reps ?? 0, 2.5, c.due, Date().timeIntervalSince1970])
        }
        try? db.run("INSERT OR REPLACE INTO meta(k,v) VALUES('seeded',?)",
                    [String(Int(Date().timeIntervalSince1970))])
    }
}
