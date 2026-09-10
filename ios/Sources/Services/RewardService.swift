import Foundation

/// 奖励 —— 练够了就多给点额度，攒够了给一张能发朋友圈的海报。
///
/// 用户原话：
/// > 每日练习达到一定数目给予一定的解锁材料数奖励，激励用户持续学习和付费意愿、
/// > 增加用户与app的粘性。
/// > 针对努力学习的用户，达标后给一个美美的截图，让用户分享到朋友圈……
/// > 既满足了用户炫耀的情绪需求、又扩展了潜在用户，是个很好的闭环
///
/// 两条自律：
/// ① **许了愿就要兑现**。"再练 N 句领奖励"这句话在 D4 之前挂过一次，
///    可发奖那套一行代码都没有 —— 对用户许愿不兑现，比不说更糟。
/// ② **不吹牛**。"你超过了百分之多少的用户"这种话，我们没有别人的数据，
///    真要显示就得编。所以只显示**自己跟自己比**的真实数字（连了几天、练了几句）。
@MainActor
final class RewardService: ObservableObject {
    static let shared = RewardService(db: .user)
    private let db: DB
    init(db: DB) { self.db = db }

    /// 每天练满多少句算达标（跟「今天」那一屏的目标是同一个数）
    var dailyGoal: Int {
        let v = UserDefaults.standard.integer(forKey: "today.goal")
        return v > 0 ? v : 50
    }

    /// 达标给多少解锁额度
    static let dailyBonus = 10
    /// 连续七天再加一笔
    static let streakBonus = 50

    struct Badge: Identifiable {
        var id: String
        var name: String
        var icon: String
        var got: Bool
        var hint: String
    }

    /// 徽章。名字要好听（用户要的是能炫耀的东西），但门槛必须是真的。
    func badges(streak: Int, total: Int) -> [Badge] {
        [
            Badge(id: "d3", name: "开了个头", icon: "leaf.fill", got: streak >= 3,
                  hint: "连续练 3 天"),
            Badge(id: "d7", name: "一周不断", icon: "flame.fill", got: streak >= 7,
                  hint: "连续练 7 天"),
            Badge(id: "d30", name: "满月耳朵", icon: "moon.stars.fill", got: streak >= 30,
                  hint: "连续练 30 天"),
            Badge(id: "s500", name: "五百句", icon: "waveform", got: total >= 500,
                  hint: "累计练 500 句"),
            Badge(id: "s2000", name: "两千句", icon: "medal.fill", got: total >= 2000,
                  hint: "累计练 2000 句")
        ]
    }

    /// 今天该不该发奖；发过就不再发（一天只发一次）。
    /// 返回发了多少额度，0 = 没发。
    @discardableResult
    func settleToday(done: Int, streak: Int, ent: EntitlementService = .shared) -> Int {
        guard done >= dailyGoal else { return 0 }
        let key = "reward." + dayKey()
        let already = (try? db.row("SELECT v FROM meta WHERE k=?", [key])?["v"] as? String) as? String
        guard already == nil else { return 0 }

        var n = Self.dailyBonus
        if streak > 0 && streak % 7 == 0 { n += Self.streakBonus }
        ent.grant(.sentenceDaily, n)
        try? db.run("INSERT OR REPLACE INTO meta(k,v) VALUES(?,?)", [key, String(n)])
        return n
    }

    /// 今天已经领到的奖励（界面上要显示"已领"，不能让人反复点）
    func grantedToday() -> Int {
        let s = (try? db.row("SELECT v FROM meta WHERE k=?",
                             ["reward." + dayKey()])?["v"] as? String) as? String
        return Int(s ?? "") ?? 0
    }

    private func dayKey() -> String {
        var c = Calendar.current; c.timeZone = .current
        let d = c.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d%02d%02d", d.year ?? 0, d.month ?? 0, d.day ?? 0)
    }
}
