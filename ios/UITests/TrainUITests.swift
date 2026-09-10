import XCTest

/// 分级听力训练走一遍真实流程：进训练页 → 挑一个练法 → 答题 → 对答案 → 下一题。
///
/// 逻辑本身在 `LingoTests` 里已经测透了（不用开模拟器）。这里只管界面上
/// **点得着、点了有反应、答案出得来** —— 那是纯逻辑测试盖不到的部分。
final class TrainUITests: XCTestCase {

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-screen", "train"] + extra
        app.launch()
        return app
    }

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    /// 七个练法一个不少地摆在首页上（用户定的原则：高频功能不进二级菜单）
    func testAllSevenModesAreOnTheHomeScreen() {
        let app = launch()
        XCTAssertTrue(app.buttons["train.start"].waitForExistence(timeout: 10),
                      "训练首页没出来：" + describe(app))
        for m in ["blank", "group", "stress", "ladder", "wordId", "dictation", "shadow"] {
            XCTAssertTrue(app.buttons["train.mode." + m].exists, "少了练法 \(m)：" + describe(app))
        }
    }

    /// 盲听填空：能进去、能播、能对答案，对完答案原文要露出来
    func testBlankDrillRunsAndReveals() {
        let app = launch()
        XCTAssertTrue(app.buttons["train.mode.blank"].waitForExistence(timeout: 10))
        app.buttons["train.mode.blank"].tap()

        let play = app.buttons["train.play"]
        XCTAssertTrue(play.waitForExistence(timeout: 10), "进不去练习：" + describe(app))
        // 播放键是这一屏最高频的动作，必须在拇指够得着的下半屏
        XCTAssertGreaterThan(play.frame.midY, app.frame.height * 0.6,
                             "播放键跑到上半屏去了，走路时单手够不着")
        play.tap()

        let check = app.buttons["train.check"]
        XCTAssertTrue(check.exists, "没有「对答案」：" + describe(app))
        check.tap()
        XCTAssertTrue(app.otherElements["train.answer"].waitForExistence(timeout: 5)
                      || app.staticTexts["train.answer"].waitForExistence(timeout: 2),
                      "对完答案没把原文露出来：" + describe(app))
        XCTAssertTrue(app.buttons["train.next"].exists, "对完答案没有「下一题」")
    }

    /// 只听重读词：没有标准答案，靠自评两个键；点了要能进下一题
    func testStressDrillSelfGrade() {
        let app = launch()
        XCTAssertTrue(app.buttons["train.mode.stress"].waitForExistence(timeout: 10))
        app.buttons["train.mode.stress"].tap()
        XCTAssertTrue(app.buttons["train.pass"].waitForExistence(timeout: 10),
                      "自评键没出来：" + describe(app))
        XCTAssertTrue(app.buttons["train.fail"].exists)
        app.buttons["train.pass"].tap()
        XCTAssertTrue(app.buttons["train.next"].waitForExistence(timeout: 5),
                      "自评完没有「下一题」：" + describe(app))
    }

    /// 意群断句：竖线点得着（20×34 的点击区在真机上不能失手）
    func testGroupCutsAreTappable() {
        let app = launch()
        XCTAssertTrue(app.buttons["train.mode.group"].waitForExistence(timeout: 10))
        app.buttons["train.mode.group"].tap()
        let cut = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'train.cut.'")).firstMatch
        XCTAssertTrue(cut.waitForExistence(timeout: 10), "断句位点不出来：" + describe(app))
        cut.tap()
        app.buttons["train.check"].tap()
        XCTAssertTrue(app.buttons["train.next"].waitForExistence(timeout: 5))
    }

    /// 退出键任何时候都在，别把人关在练习里
    func testCanAlwaysLeave() {
        let app = launch()
        XCTAssertTrue(app.buttons["train.mode.dictation"].waitForExistence(timeout: 10))
        app.buttons["train.mode.dictation"].tap()
        XCTAssertTrue(app.buttons["退出"].waitForExistence(timeout: 10))
        app.buttons["退出"].tap()
        XCTAssertTrue(app.buttons["train.start"].waitForExistence(timeout: 5),
                      "退不回训练首页：" + describe(app))
    }
}

/// 教程（D5）和视频跟读（D6）的入口与基本可用性。
/// 这两块的算法部分在 LingoTests 里测；这里只管"点得进去、点得回来"。
final class LearnUITests: XCTestCase {

    private func launch(_ screen: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-screen", screen]
        app.launch()
        return app
    }

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    /// 八课一节不少，而且能点开
    func testTutorialOpensAndHasAllLessons() {
        let app = launch("train")
        let entry = app.buttons["train.tutorial"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10), "训练页没有教程入口：" + describe(app))
        entry.tap()
        for id in ["beat", "weak", "link", "stop", "group", "why", "speak", "how"] {
            let row = app.buttons["tutorial." + id]
            // 后面几课要滑下去才看得见
            if !row.exists { app.swipeUp() }
            XCTAssertTrue(row.exists, "少了第 \(id) 课：" + describe(app))
        }
    }

    /// 一课里该有的三样：正文、例子、配套练习
    func testLessonHasPracticeButton() {
        let app = launch("train")
        XCTAssertTrue(app.buttons["train.tutorial"].waitForExistence(timeout: 10))
        app.buttons["train.tutorial"].tap()
        XCTAssertTrue(app.buttons["tutorial.beat"].waitForExistence(timeout: 5))
        app.buttons["tutorial.beat"].tap()
        let practice = app.buttons["lesson.practice"]
        if !practice.exists { app.swipeUp() }
        XCTAssertTrue(practice.waitForExistence(timeout: 5),
                      "这一课末尾没有「练一下」——教程配套练习是用户点名要的：" + describe(app))
    }

    /// 材料页上「导入自己的」和「视频跟读」两个口都在，且视频那一屏能打开
    func testMaterialsHasImportAndVideoEntries() {
        let app = launch("dict")
        let video = app.buttons["packs.play.rectangle"]
        XCTAssertTrue(video.waitForExistence(timeout: 10), "材料页没有视频跟读入口：" + describe(app))
        XCTAssertTrue(app.buttons["packs.square.and.arrow.down"].exists, "没有导入入口")
        video.tap()
        XCTAssertTrue(app.textFields["yt.link"].waitForExistence(timeout: 5),
                      "视频跟读打不开：" + describe(app))
    }
}
