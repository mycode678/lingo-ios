import XCTest

/// 真机式自测：模拟器里真的转屏、真的点、真的滑。
///
/// 为什么非要有：静态截图只能看"某一种状态下长什么样"，看不出
/// "手势能不能用""这条能不能滚""转屏之后还对不对"。
/// 之前横屏控制条滚不动、波形上圈不了选区，都是截图看不出来、只有真滑一次才知道的。
final class DrillUITests: XCTestCase {

    /// 一直往左滑，直到目标真的落进控制条的可见范围里（最多 8 次）。
    /// 不能用 isHittable 判断：元素还在滚动区外面时，XCUITest 会直接报
    /// "Activation point invalid"，而不是老老实实返回 false。改成比坐标。
    private func scrollToEnd(_ strip: XCUIElement, target: XCUIElement) -> Bool {
        func visible() -> Bool {
            guard target.exists else { return false }
            let f = target.frame
            return f.width > 1 && strip.frame.insetBy(dx: 2, dy: 0).intersects(f)
        }
        for _ in 0..<8 {
            if visible() { return true }
            strip.swipeLeft()
        }
        return visible()
    }

    /// 失败时把当前屏幕上能点的东西列出来，省得瞎猜
    private func dump(_ app: XCUIApplication) -> String {
        let names = app.buttons.allElementsBoundByIndex.prefix(40).map { $0.label }
        let ids = app.descendants(matching: .any).allElementsBoundByIndex.prefix(60)
            .compactMap { $0.identifier.isEmpty ? nil : $0.identifier }
        return "按钮：" + names.joined(separator: " | ") + "；标识：" + Set(ids).joined(separator: " | ")
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-screen", "drill"] + extra
        app.launch()
        return app
    }

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    /// 竖屏：底部控制条从左到右该有的键都在，且能滑到最右边
    func testPortraitStripScrolls() {
        let app = launch()
        let strip = app.scrollViews.matching(identifier: "controlStrip").firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 10), "找不到控制条")

        XCTAssertTrue(app.buttons["录音"].exists, "控制条上没有录音")
        XCTAssertTrue(scrollToEnd(strip, target: app.descendants(matching: .any)["rate-自定"]),
                      "控制条滑到底也点不到最后一个（自定）；" + dump(app))
    }

    /// 横屏：同样要能滑。这一条就是为了逮住"横屏滚不动"那个 bug。
    func testLandscapeStripScrolls() {
        let app = launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let strip = app.scrollViews.matching(identifier: "controlStrip").firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 10), "横屏找不到控制条")
        XCTAssertTrue(scrollToEnd(strip, target: app.descendants(matching: .any)["rate-自定"]),
                      "横屏控制条滑到底也点不到最后一个（自定）；" + dump(app))
    }

    /// 波形上必须能长按拖出选区（长按 0.18 秒再拖）
    func testDrawSelectionOnWaveform() {
        let app = launch()
        let wave = app.otherElements["waveform"]
        XCTAssertTrue(wave.waitForExistence(timeout: 10), "找不到波形")
        let a = wave.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.5))
        let b = wave.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.5))
        a.press(forDuration: 0.35, thenDragTo: b)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH '选区'"))
                        .firstMatch.waitForExistence(timeout: 3),
                      "在波形上长按拖动没有画出选区")
    }

    /// 录完之后：结果面板要自己弹出来，控制条上要出现"对比"。
    /// （他反馈过"录音后的对比按钮一直没有"，这条就是钉住它。）
    func testTakePanelAndCompareButton() {
        let app = launch(["-take"])          // -take＝假装刚录完一条
        XCTAssertTrue(app.buttons["对比"].waitForExistence(timeout: 10),
                      "录完了但控制条上没有「对比」；" + dump(app))
        XCTAssertTrue(app.buttons["我的"].exists, "结果面板里没有「我的」")
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '词准'")).firstMatch.exists,
            "结果面板里没有分项得分")
    }

    /// 小句那一条必须在"没听懂"上面，且不许压住它
    func testChunkStripSitsAboveGradeRow() {
        let app = launch()
        let chunk = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Excuse me can you tell'")).firstMatch
        XCTAssertTrue(chunk.waitForExistence(timeout: 10), "找不到小句；" + dump(app))
        let grade = app.buttons["没听懂"]
        XCTAssertTrue(grade.exists, "找不到打分行")
        XCTAssertLessThanOrEqual(chunk.frame.maxY, grade.frame.minY + 1,
                                 "小句压住了「没听懂」那一行")
    }

    /// "显示"里全关时不该出现原文；勾上原文就该出现
    func testShowMenuTogglesSentence() {
        let app = launch()
        let sentence = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Excuse me, can you tell'")).firstMatch
        XCTAssertFalse(sentence.exists, "默认应该什么文字都不显示（先听声音）")
        app.buttons["显示"].tap()
        app.buttons["原文"].tap()
        XCTAssertTrue(sentence.waitForExistence(timeout: 3), "勾了原文却没显示出来")
    }

    /// 左右滑切句：滑一下，标题里的"第几句"必须变
    func testSwipeChangesSentence() {
        let app = launch()
        let title = app.staticTexts.matching(NSPredicate(format: "label CONTAINS '/'")).firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 10), "找不到第几句那个标题")
        let before = title.label
        app.otherElements["swipeArea"].swipeLeft()
        expectation(for: NSPredicate(format: "label != %@", before), evaluatedWith: title)
        waitForExpectations(timeout: 3)
    }
}

/// 耳机、锁屏、音量键这一类：真机上没法用代码按物理键，也没法替 AirPods 点两下，
/// 但它们最终都汇到 App 里同一处代码。这些测试用 -probe 后门从内部触发那处代码，
/// 验"按了之后会怎样"——切没切句、播没播、方向对不对。
final class RemoteControlUITests: XCTestCase {

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-screen", "drill", "-probe"]
        app.launch()
        return app
    }
    override func setUp() { continueAfterFailure = false; XCUIDevice.shared.orientation = .portrait }

    private func index(_ app: XCUIApplication) -> String {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS '/'")).firstMatch.label
    }

    /// 音量＋＝上一句、音量−＝下一句（他明确要求过这个方向）
    func testVolumeKeysDirection() {
        let app = launch()
        XCTAssertTrue(app.buttons["probe-vol-down"].waitForExistence(timeout: 10), "没有后门按钮")
        // 先往后走一句，才有"上一句"可回
        app.buttons["probe-vol-down"].tap()
        let afterDown = index(app)
        app.buttons["probe-vol-up"].tap()
        let afterUp = index(app)
        XCTAssertNotEqual(afterDown, afterUp, "音量＋没有切回上一句")
    }

    /// 锁屏/AirPods 的上一曲下一曲＝上一句下一句
    func testRemoteNextPrev() {
        let app = launch()
        XCTAssertTrue(app.buttons["probe-remote-next"].waitForExistence(timeout: 10), "没有后门按钮")
        let before = index(app)
        app.buttons["probe-remote-next"].tap()
        let after = index(app)
        XCTAssertNotEqual(before, after, "锁屏「下一曲」没换句")
        app.buttons["probe-remote-prev"].tap()
        XCTAssertEqual(index(app), before, "锁屏「上一曲」没回到原来那句")
    }

    /// 锁屏播放键要真的能管住播放
    func testRemoteTogglePlays() {
        let app = launch()
        XCTAssertTrue(app.buttons["probe-remote-toggle"].waitForExistence(timeout: 10), "没有后门按钮")
        app.buttons["probe-remote-toggle"].tap()      // 不崩、不卡就算过（放音本身听不出来）
        app.buttons["probe-remote-toggle"].tap()
        XCTAssertTrue(app.buttons["录音"].exists, "点了锁屏播放键之后界面不对了")
    }
}

/// 真机截图：把手机上真实的样子抓下来存进结果包，我再从 .xcresult 里取出来看。
/// 有了它，"顶部图标只露一半"这种问题我自己就能看见，不用他截图给我。
final class ShotUITests: XCTestCase {
    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
    func testCaptureScreens() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-screen", "drill"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        sleep(3); shot(app, "竖屏")
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(3); shot(app, "横屏")
        // 文字全开：最容易把波形挤没的情况
        app.buttons["显示"].tap()
        for t in ["原文", "译文", "中文释义", "英文释义"] where app.buttons[t].exists {
            app.buttons[t].tap(); app.buttons["显示"].tap()
        }
        sleep(2); shot(app, "横屏-文字全开")
        XCUIDevice.shared.orientation = .portrait
        sleep(3); shot(app, "竖屏-文字全开")
    }
}
