import Foundation

/// 分级听力训练的调度：**出什么题、按什么顺序、练完记在哪**。
///
/// 出题的句子从两个地方来，优先级就是这个顺序：
///   1. 复习队列里到期的（跟 SM-2 共用一套队列，不另起炉灶）
///   2. 装好的材料包里还没练过的
///
/// 两处都要过**难度闸**（`TrainKit.tooHard`）：
/// 用户原话是"练习的句子……就像现在朗文词典里的例句差不多，绝大部分人能够的着"。
@MainActor
final class TrainService: ObservableObject {
    static let shared = TrainService(db: .user, catalog: .shared)

    private let db: DB
    private let catalog: CatalogService
    private let ent: EntitlementService
    init(db: DB, catalog: CatalogService, ent: EntitlementService = .shared) {
        self.db = db; self.catalog = catalog; self.ent = ent
    }

    /// 上一次取题为什么没取满（额度用完 / 材料不够）。界面拿它给一句人话。
    @Published private(set) var blocked: String?

    /// 一道题要用的全部东西
    struct Item: Identifiable, Equatable {
        var id: String              // 句子 id
        var en: String
        var cn: String
        var audio: URL?
        var words: [TrainKit.Word]
        var analysis: TrainKit.Analysis
        static func == (a: Item, b: Item) -> Bool { a.id == b.id }
    }

    // MARK: 取题

    /// 给某个练法取一批题。
    ///
    /// `count` 是想要几道；材料不够就少给几道，**绝不用难句凑数** ——
    /// 凑数正是用户批评别家的那件事（"上来就给一个普通用户完全听不懂的材料"）。
    func items(for mode: TrainMode, count: Int? = nil) -> [Item] {
        let want = count ?? mode.defaultCount
        var out: [Item] = []
        var seen = Set<String>()
        blocked = nil

        for cand in candidates() {
            guard !seen.contains(cand.id) else { continue }
            guard TrainKit.isEasyEnough(cand.en) else { continue }
            guard let item = build(cand), usable(item, for: mode) else { continue }
            // 额度：**练过的句子不再扣**（复习不该花今天的额度），
            // 只有第一次碰的预置材料才算解锁一句。
            if !Demo.on, let pid = cand.packId,
               !CatalogService.isUserPack(pid),          // 自己导的材料不占额度
               PracticeService.shared.progress(cand.id) == nil,
               !ent.unlock(pid, cand.id) {
                blocked = ent.blockedReason(.sentenceDaily) ?? ent.blockedReason(.sentenceWeekly)
                break
            }
            seen.insert(cand.id)
            out.append(item)
            if out.count >= want { break }
        }
        return out
    }

    /// 这道题够不够格给这个练法用 —— 出不了题的句子提前扔掉，
    /// 别让用户点进去看见一片空白。
    private func usable(_ item: Item, for mode: TrainMode) -> Bool {
        guard item.words.count >= 3 else { return false }
        switch mode {
        case .blank:     return !BlankQuiz.make(item.analysis).blanks.isEmpty
        case .group:     return !GroupQuiz.make(item.analysis).answer.isEmpty
        case .stress:    return !item.analysis.stressed.isEmpty
        case .wordId:    return item.words.contains { !TrainKit.isFunction($0.text) }
        default:         return true
        }
    }

    /// 候选句：先到期复习的，再包里没练过的
    private struct Cand { var id: String; var en: String; var cn: String
                          var packId: String?; var audio: URL? }

    private func candidates() -> [Cand] {
        if Demo.on { return demoCands() }
        var out: [Cand] = []
        let due = PracticeService.shared.due(60)
        let packs = catalog.packs()
        // 到期的句子要能找回它的音频，所以按包过一遍
        var byId: [String: (CatalogService.Sent, String)] = [:]
        for p in packs {
            for s in catalog.sentences(p.id, limit: 400) { byId[s.id] = (s, p.id) }
        }
        for c in due {
            if let (s, pid) = byId[c.src] {
                out.append(Cand(id: s.id, en: s.en, cn: s.cn, packId: pid, audio: s.audio))
            }
        }
        // 没练过的
        let practiced = Set(due.map(\.src))
        for p in packs {
            for s in catalog.sentences(p.id, limit: 400) where !practiced.contains(s.id) {
                out.append(Cand(id: s.id, en: s.en, cn: s.cn, packId: p.id, audio: s.audio))
            }
        }
        return out
    }

    private func build(_ c: Cand) -> Item? {
        let raw: [TrainKit.Word]
        if let pid = c.packId, !Demo.on {
            raw = catalog.words(pid, c.id).map { TrainKit.Word($0.w, $0.s, $0.e) }
        } else {
            raw = demoWords(c.id)
        }
        guard raw.count >= 3 else { return nil }
        return Item(id: c.id, en: c.en, cn: c.cn, audio: c.audio,
                    words: raw, analysis: TrainKit.analyze(raw))
    }

    // MARK: 演示数据（云端模拟器里没有材料包，靠它把界面跑起来）

    private func demoCands() -> [Cand] {
        Demo.sentences.enumerated().map { i, s in
            Cand(id: s.src, en: s.en, cn: s.cn ?? "", packId: nil, audio: nil)
        }
    }

    private func demoWords(_ id: String) -> [TrainKit.Word] {
        guard let i = Demo.sentences.firstIndex(where: { $0.src == id }) else { return [] }
        return Demo.words[i].map { TrainKit.Word($0.w, $0.s, $0.e) }
    }

    // MARK: 记账

    /// 记一次练习结果。**只记数字，不记内容** —— 用户打错的字不留档。
    func record(_ mode: TrainMode, sentId: String, right: Int, total: Int, secs: Double = 0) {
        try? db.run("INSERT INTO train(kind, sent_id, at, right_n, total_n, secs) VALUES(?,?,?,?,?,?)",
                    [mode.rawValue, sentId, Date().timeIntervalSince1970, right, total, secs])
        // 训练也算练过这一句：错得多就当"没听懂"，排到十分钟后再撞一次
        guard total > 0 else { return }
        let ratio = Double(right) / Double(total)
        let q = ratio >= 0.95 ? 4 : (ratio >= 0.7 ? 3 : (ratio >= 0.4 ? 2 : 1))
        PracticeService.shared.grade(sentId, q, score: ratio * 100)
    }

    /// 速度阶梯的当前档位（每句各记各的）
    func ladderLevel(_ sentId: String) -> Int {
        (try? db.row("SELECT level FROM ladder WHERE sent_id=?", [sentId])?["level"] as? Int) as? Int ?? 0
    }

    func setLadderLevel(_ sentId: String, _ level: Int) {
        try? db.run("""
            INSERT INTO ladder(sent_id, level, at) VALUES(?,?,?)
            ON CONFLICT(sent_id) DO UPDATE SET level=excluded.level, at=excluded.at
            """, [sentId, level, Date().timeIntervalSince1970])
    }

    // MARK: 统计（今日训练卡片要用）

    struct Stat { var done: Int; var right: Int; var total: Int }

    /// 今天各练法做了多少题
    func today(_ mode: TrainMode? = nil) -> Stat {
        var c = Calendar.current; c.timeZone = .current
        let start = c.startOfDay(for: Date()).timeIntervalSince1970
        let sql = mode == nil
            ? "SELECT COUNT(*) AS n, SUM(right_n) AS r, SUM(total_n) AS t FROM train WHERE at>=?"
            : "SELECT COUNT(*) AS n, SUM(right_n) AS r, SUM(total_n) AS t FROM train WHERE at>=? AND kind=?"
        let args: [Any?] = mode == nil ? [start] : [start, mode!.rawValue]
        guard let r = try? db.row(sql, args) else { return Stat(done: 0, right: 0, total: 0) }
        return Stat(done: r["n"] as? Int ?? 0,
                    right: r["r"] as? Int ?? 0, total: r["t"] as? Int ?? 0)
    }

    /// 今日训练的推荐配比 —— 十分钟，三个练法，句子从同一批材料里出。
    /// 顺序有讲究：先"听得见"（填空），再"听得懂结构"（意群），最后"说得出"（跟读）。
    static let dailyPlan: [(mode: TrainMode, count: Int, minutes: Int)] = [
        (.blank, 8, 3), (.group, 5, 3), (.shadow, 6, 4)
    ]
}
