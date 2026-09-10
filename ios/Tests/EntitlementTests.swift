import XCTest
@testable import Lingo

/// 会员、额度、奖励的逻辑测试。**不开模拟器**，每条都用一个临时库，互不干扰。
///
/// 为什么值得单独测：额度这套东西错了用户直接骂街 ——
/// 该给的没给（练不了），或者不该扣的扣了（复习一遍还要花今天的额度）。
/// 这两种错都不会崩，只会静悄悄地伤人，光靠点界面根本发现不了。
@MainActor
final class EntitlementTests: XCTestCase {

    private func freshDB() throws -> DB {
        let p = NSTemporaryDirectory() + "ent-\(UUID().uuidString).sqlite"
        let db = DB(testPath: p)
        try db.migrate()
        return db
    }

    private func svc() throws -> EntitlementService {
        EntitlementService(db: try freshDB())
    }

    // MARK: 身份

    func testDefaultsToFreeAndSurvivesReload() throws {
        let e = try svc()
        e.reload()
        XCTAssertEqual(e.tier, .free)
        e.setTier(.yearly)
        e.reload()
        XCTAssertEqual(e.tier, .yearly)
        XCTAssertTrue(e.tier.paid)
    }

    func testFreeLimitsAreTheOnesTheUserNamed() throws {
        let e = try svc()
        e.reload()
        // 用户点名定死的两个数，不许被顺手改掉
        XCTAssertEqual(e.limits.dailySentences, 10, "免费每日 10 句是用户定的")
        XCTAssertEqual(e.limits.weeklySentences, 50, "免费每周 50 句是用户定的")
    }

    func testLifetimeHasNoCaps() throws {
        let e = try svc()
        e.setTier(.lifetime)
        XCTAssertNil(e.remaining(.sentenceDaily))
        XCTAssertNil(e.remaining(.ai))
        XCTAssertTrue(e.allowed(.sentenceDaily, 99999))
        XCTAssertNil(e.unlockableNow())
    }

    // MARK: 额度

    func testConsumeCountsDown() throws {
        let e = try svc()
        e.reload()
        XCTAssertEqual(e.remaining(.sentenceDaily), 10)
        e.consume(.sentenceDaily, 3)
        XCTAssertEqual(e.remaining(.sentenceDaily), 7)
        XCTAssertEqual(e.used(.sentenceDaily), 3)
    }

    /// 跨期归零：额度是按"周期"记的，别的周期用掉的不该算在今天头上
    func testQuotaIsPerPeriod() throws {
        let db = try freshDB()
        let e = EntitlementService(db: db)
        e.reload()
        // 手工塞一条"很久以前那天"的记录
        try db.run("INSERT INTO quota(kind, period, used) VALUES('sent.d','1999-01-01',999)")
        XCTAssertEqual(e.used(.sentenceDaily), 0, "上个周期用掉的不该算进这个周期")
        XCTAssertEqual(e.remaining(.sentenceDaily), 10)
    }

    func testUnlockIsOneTimeAndRepeatIsFree() throws {
        let e = try svc()
        e.reload()
        XCTAssertTrue(e.unlock("p1", "s1"))
        XCTAssertEqual(e.remaining(.sentenceDaily), 9)
        // 同一句再解一次不能再扣 —— 否则复习旧句子也要花今天的额度，是在罚用户复习
        XCTAssertTrue(e.unlock("p1", "s1"))
        XCTAssertEqual(e.remaining(.sentenceDaily), 9)
        XCTAssertTrue(e.isUnlocked("p1", "s1"))
    }

    func testUnlockStopsWhenDailyRunsOut() throws {
        let e = try svc()
        e.reload()
        for i in 0..<10 { XCTAssertTrue(e.unlock("p1", "s\(i)"), "第 \(i) 句就不给解了") }
        XCTAssertFalse(e.unlock("p1", "s99"), "超过每日 10 句还能解锁")
        XCTAssertNotNil(e.blockedReason(.sentenceDaily))
        // 提示语里不能只有"买会员"，得先说明天还能接着练
        XCTAssertTrue(e.blockedReason(.sentenceDaily)!.contains("明天"))
    }

    func testWeeklyCapAlsoBites() throws {
        let db = try freshDB()
        let e = EntitlementService(db: db)
        e.setTier(.free)
        // 这周已经用了 50 句（日额度还没动）
        e.consume(.sentenceWeekly, 50)
        XCTAssertEqual(e.remaining(.sentenceWeekly), 0)
        XCTAssertEqual(e.unlockableNow(), 0)
        XCTAssertFalse(e.unlock("p1", "x1"))
    }

    // MARK: 免费 AI 的七天试用

    func testFreeAITrialExpires() throws {
        let db = try freshDB()
        let e = EntitlementService(db: db)
        e.setTier(.free)
        XCTAssertEqual(e.cap(.ai), 100, "试用期内每天 100 次")
        // 把"第一次用是哪天"改成 8 天前
        let old = Int(Calendar.current.startOfDay(for: Date()).timeIntervalSince1970 / 86400) - 8
        try db.run("INSERT OR REPLACE INTO meta(k,v) VALUES('firstday',?)", [String(old)])
        XCTAssertEqual(e.cap(.ai), 0, "七天试用过了就没有了")
        XCTAssertEqual(e.freeAIDaysLeft, 0)
        XCTAssertTrue(e.blockedReason(.ai)!.contains("试用"))
        // 付费之后照样有
        e.setTier(.monthly)
        XCTAssertEqual(e.cap(.ai), 200)
    }

    // MARK: 广告与奖励

    func testAdRewardOnlyWhenAdsEnabled() throws {
        let e = try svc()
        e.reload()
        UserDefaults.standard.set(false, forKey: "ads.enabled")
        XCTAssertEqual(e.rewardForAd(), 0, "广告没开就不该有奖励")
        UserDefaults.standard.set(true, forKey: "ads.enabled")
        XCTAssertEqual(e.rewardForAd(), EntitlementService.sentencesPerAd)
        XCTAssertEqual(e.remaining(.sentenceDaily), 10 + EntitlementService.sentencesPerAd)
        // 一天最多看几条
        for _ in 0..<EntitlementService.adsPerDay { _ = e.rewardForAd() }
        XCTAssertEqual(e.rewardForAd(), 0)
        UserDefaults.standard.removeObject(forKey: "ads.enabled")
    }

    func testDailyRewardPaysOnceAndOnlyWhenGoalMet() throws {
        let db = try freshDB()
        let e = EntitlementService(db: db)
        e.reload()
        let r = RewardService(db: db)
        UserDefaults.standard.set(20, forKey: "today.goal")
        defer { UserDefaults.standard.removeObject(forKey: "today.goal") }

        XCTAssertEqual(r.settleToday(done: 19, streak: 1, ent: e), 0, "没练够不该发")
        let got = r.settleToday(done: 20, streak: 1, ent: e)
        XCTAssertEqual(got, RewardService.dailyBonus)
        XCTAssertEqual(e.remaining(.sentenceDaily), 10 + RewardService.dailyBonus)
        XCTAssertEqual(r.settleToday(done: 30, streak: 1, ent: e), 0, "一天只能发一次")
        XCTAssertEqual(r.grantedToday(), RewardService.dailyBonus)
    }

    func testSeventhDayPaysExtra() throws {
        let db = try freshDB()
        let e = EntitlementService(db: db)
        e.reload()
        let r = RewardService(db: db)
        UserDefaults.standard.set(1, forKey: "today.goal")
        defer { UserDefaults.standard.removeObject(forKey: "today.goal") }
        XCTAssertEqual(r.settleToday(done: 5, streak: 7, ent: e),
                       RewardService.dailyBonus + RewardService.streakBonus)
    }

    func testBadgesAreEarnedNotGiven() throws {
        let r = RewardService(db: try freshDB())
        let none = r.badges(streak: 0, total: 0)
        XCTAssertTrue(none.allSatisfy { !$0.got }, "一条没练就不该有徽章")
        let some = r.badges(streak: 7, total: 600)
        XCTAssertTrue(some.first { $0.id == "d7" }!.got)
        XCTAssertTrue(some.first { $0.id == "s500" }!.got)
        XCTAssertFalse(some.first { $0.id == "d30" }!.got)
    }
}
