import Foundation

/// 会员、额度、解锁 —— **全在本机判**，没网也知道你是什么身份、还剩多少额度。
///
/// 方案定的（`PLAN.md` 3.1，用户最后一次说的为准）：
/// > 会员做成订阅制+买断，分3种订阅：连续包月/年/买断
/// 定价策略是**引导用户一次买断**，所以订阅价要接近买断价。
///
/// 卡的是三样（3.2）：能解锁多少句预置材料、能导入多少份自己的材料、
/// 能用多少次 AI 拆解。免费用户的两个数是用户点名定死的：
/// **每周 50 句、每日限额 10 句**。别的档"先随便订一个"，都集中在下面这张表里，
/// 以后要改只改这一处。
@MainActor
final class EntitlementService: ObservableObject {
    static let shared = EntitlementService(db: .user)
    private let db: DB
    init(db: DB) { self.db = db }

    // MARK: 身份

    enum Tier: String, Codable, CaseIterable {
        case free, monthly, yearly, lifetime

        var name: String {
            switch self {
            case .free:     return "免费"
            case .monthly:  return "连续包月"
            case .yearly:   return "连续包年"
            case .lifetime: return "买断"
            }
        }
        var paid: Bool { self != .free }
    }

    /// 一档给多少。`nil` = 不限。
    struct Limits {
        var dailySentences: Int?     // 每天能解锁几句预置材料
        var weeklySentences: Int?    // 每周
        var dailyAI: Int?            // 每天能用几次 AI 拆解
        var imports: Int?            // 一共能导入几份自己的材料
        var packs: Int?              // 同时能装几个材料包
    }

    /// **要调数量就改这儿**，别散在各处。
    /// 免费那两个数（每日 10 / 每周 50）是用户点名定的，不能随便动。
    static let limits: [Tier: Limits] = [
        .free:     Limits(dailySentences: 10, weeklySentences: 50,
                          dailyAI: 100, imports: 3, packs: 2),
        .monthly:  Limits(dailySentences: 60, weeklySentences: 300,
                          dailyAI: 200, imports: 20, packs: 10),
        .yearly:   Limits(dailySentences: 120, weeklySentences: 600,
                          dailyAI: 400, imports: 50, packs: 30),
        .lifetime: Limits(dailySentences: nil, weeklySentences: nil,
                          dailyAI: nil, imports: nil, packs: nil)
    ]

    /// 免费用户的 AI 拆解是**试用**性质：用户原话「每天最多100个，最多用7天」。
    static let freeAIDays = 7

    @Published private(set) var tier: Tier = .free

    /// 当前身份。凭证由 `Purchases`（StoreKit）写进来，这里只读本机记录 ——
    /// 断网时也得知道你是会员，不能因为校验不了就把人降级。
    func reload() {
        let v = (try? db.row("SELECT v FROM meta WHERE k='tier'")?["v"] as? String) as? String
        tier = Tier(rawValue: v ?? "") ?? .free
    }

    func setTier(_ t: Tier) {
        try? db.run("INSERT OR REPLACE INTO meta(k,v) VALUES('tier',?)", [t.rawValue])
        if firstRunDay() == nil { markFirstRun() }
        tier = t
    }

    var limits: Limits { Self.limits[tier] ?? Self.limits[.free]! }

    // MARK: 额度

    enum Kind: String {
        case sentenceDaily = "sent.d"
        case sentenceWeekly = "sent.w"
        case ai = "ai.d"
        case importFile = "import"
        case adDaily = "ad.d"
    }

    /// 看广告最多能多解锁几次（每天）。
    /// 用户原话：「我想在app里增加免费用户给看广告后可学习更多材料的功能」。
    /// 广告 SDK 还没接 —— Google 广告在国内 iOS 能不能正常展示，用户说"先记下研究清楚之后再说"。
    /// 所以这里先只有额度逻辑，界面上的入口由 `adsEnabled` 控制，默认关。
    static let adsPerDay = 3
    static let sentencesPerAd = 5

    var adsEnabled: Bool { UserDefaults.standard.bool(forKey: "ads.enabled") }

    private func period(_ k: Kind) -> String {
        var c = Calendar(identifier: .iso8601)
        c.timeZone = .current
        let now = Date()
        switch k {
        case .sentenceWeekly:
            let w = c.component(.weekOfYear, from: now)
            let y = c.component(.yearForWeekOfYear, from: now)
            return String(format: "%04d-W%02d", y, w)
        case .importFile:
            return "all"                       // 导入是累计的，不按周期清零
        default:
            let d = c.dateComponents([.year, .month, .day], from: now)
            return String(format: "%04d-%02d-%02d", d.year ?? 0, d.month ?? 0, d.day ?? 0)
        }
    }

    func used(_ k: Kind) -> Int {
        (try? db.row("SELECT used FROM quota WHERE kind=? AND period=?",
                     [k.rawValue, period(k)])?["used"] as? Int) as? Int ?? 0
    }

    /// 这一项还剩多少；`nil` = 不限
    func remaining(_ k: Kind) -> Int? {
        guard let cap = cap(k) else { return nil }
        return max(0, cap + bonus(k) - used(k))
    }

    /// 这一档这一项的上限
    func cap(_ k: Kind) -> Int? {
        switch k {
        case .sentenceDaily:  return limits.dailySentences
        case .sentenceWeekly: return limits.weeklySentences
        case .importFile:     return limits.imports
        case .adDaily:        return Self.adsPerDay
        case .ai:
            // 免费用户的 AI 是七天试用：过了七天就没有了，不是"每天还给你 100 个"
            if tier == .free, let d = firstRunDay(), daysSince(d) >= Self.freeAIDays { return 0 }
            return limits.dailyAI
        }
    }

    func allowed(_ k: Kind, _ n: Int = 1) -> Bool {
        guard let left = remaining(k) else { return true }
        return left >= n
    }

    /// 用掉 n 个额度。**够不够先问 `allowed`** —— 这里不做拦截，
    /// 拦截要发生在动作真的开始之前，不然用户看完广告才被告知超额。
    func consume(_ k: Kind, _ n: Int = 1) {
        try? db.run("""
            INSERT INTO quota(kind, period, used) VALUES(?,?,?)
            ON CONFLICT(kind, period) DO UPDATE SET used = used + ?
            """, [k.rawValue, period(k), n, n])
    }

    // MARK: 解锁一句预置材料
    //
    // **解锁是一次性的**：解过的句子以后随便练，不再扣额度。
    // 否则"复习昨天那句"也要花今天的额度，等于罚用户复习 —— 那是反着来的。

    func isUnlocked(_ packId: String, _ sentId: String) -> Bool {
        ((try? db.row("SELECT 1 AS x FROM unlock WHERE pack_id=? AND sent_id=?",
                      [packId, sentId])) ?? nil) != nil
    }

    /// 解锁一句。够不够额度这里会判；返回 false 说明今天/这周的用完了。
    @discardableResult
    func unlock(_ packId: String, _ sentId: String, via: String = "member") -> Bool {
        if isUnlocked(packId, sentId) { return true }
        guard allowed(.sentenceDaily), allowed(.sentenceWeekly) else { return false }
        try? db.run("INSERT OR REPLACE INTO unlock(pack_id, sent_id, via, at) VALUES(?,?,?,?)",
                    [packId, sentId, via, Date().timeIntervalSince1970])
        consume(.sentenceDaily)
        consume(.sentenceWeekly)
        return true
    }

    /// 今天最多还能解锁几句（日和周取小的那个）；nil = 不限
    func unlockableNow() -> Int? {
        switch (remaining(.sentenceDaily), remaining(.sentenceWeekly)) {
        case (nil, nil):            return nil
        case (let d?, nil):         return d
        case (nil, let w?):         return w
        case (let d?, let w?):      return min(d, w)
        }
    }

    // MARK: 奖励（练够了就多给额度）
    //
    // 用户原话：
    // > 每日练习达到一定数目给予一定的解锁材料数奖励，激励用户持续学习和付费意愿、
    // > 增加用户与app的粘性。
    //
    // 奖励是**加在上限之上**的，不是把已用的抹掉 —— 抹掉会让"我今天练了多少"这个
    // 数字变来变去，用户看不懂。

    func bonus(_ k: Kind) -> Int {
        (try? db.row("SELECT used FROM quota WHERE kind=? AND period=?",
                     ["bonus." + k.rawValue, period(k)])?["used"] as? Int) as? Int ?? 0
    }

    func grant(_ k: Kind, _ n: Int) {
        try? db.run("""
            INSERT INTO quota(kind, period, used) VALUES(?,?,?)
            ON CONFLICT(kind, period) DO UPDATE SET used = used + ?
            """, ["bonus." + k.rawValue, period(k), n, n])
    }

    /// 看一条广告换额度。返回换到了几句；0 = 今天看够了或者广告没开。
    @discardableResult
    func rewardForAd() -> Int {
        guard adsEnabled, allowed(.adDaily) else { return 0 }
        consume(.adDaily)
        grant(.sentenceDaily, Self.sentencesPerAd)
        return Self.sentencesPerAd
    }

    // MARK: 第一次用是哪天（免费 AI 的七天试用要从这天算）

    private func firstRunDay() -> Int? {
        guard let s = (try? db.row("SELECT v FROM meta WHERE k='firstday'")?["v"] as? String) as? String,
              let v = Int(s) else { return nil }
        return v
    }

    func markFirstRun() {
        guard firstRunDay() == nil else { return }
        try? db.run("INSERT OR REPLACE INTO meta(k,v) VALUES('firstday',?)", [String(today())])
    }

    private func today() -> Int {
        var c = Calendar.current; c.timeZone = .current
        return Int(c.startOfDay(for: Date()).timeIntervalSince1970 / 86400)
    }
    private func daysSince(_ d: Int) -> Int { max(0, today() - d) }

    /// 免费 AI 试用还剩几天（0 = 用完了）
    var freeAIDaysLeft: Int {
        guard tier == .free, let d = firstRunDay() else { return Self.freeAIDays }
        return max(0, Self.freeAIDays - daysSince(d))
    }

    // MARK: 说人话的超额提示
    //
    // 用户批评过别家："不断的弹购买会员窗口，做app没有诚意"。
    // 所以超额时要先告诉他**明天就能接着练**，再提会员，而不是上来就堵。

    func blockedReason(_ k: Kind) -> String? {
        guard let left = remaining(k), left <= 0 else { return nil }
        switch k {
        case .sentenceDaily:
            return "今天的 \(cap(k) ?? 0) 句练完了。明天再来 —— "
                 + "每天练一点比一天猛练强，这是记忆规律，不是我们卡你。"
        case .sentenceWeekly:
            return "这周的 \(cap(k) ?? 0) 句练完了，下周一重置。"
        case .ai:
            return tier == .free && freeAIDaysLeft == 0
                ? "AI 拆解的 \(Self.freeAIDays) 天试用结束了。逐词打分和诊断照常免费用。"
                : "今天的 AI 拆解用完了，明天重置。"
        case .importFile:
            return "免费能导入 \(cap(k) ?? 0) 份自己的材料，已经用完了。"
        case .adDaily:
            return "今天的广告奖励领满了。"
        }
    }
}
