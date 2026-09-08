import XCTest

/// 真机式自测：模拟器里真的转屏、真的点、真的滑。
///
/// 为什么非要有：静态截图只能看"某一种状态下长什么样"，看不出
/// "手势能不能用""这条能不能滚""转屏之后还对不对"。
/// 之前横屏控制条滚不动、波形上圈不了选区，都是截图看不出来、只有真滑一次才知道的。
final class DrillUITests: XCTestCase {

    /// 一直往左滑，直到目标能点为止（最多 6 次）。一次 swipeLeft 不一定滑得到底。
    private func scrollToEnd(_ strip: XCUIElement, target: XCUIElement) -> Bool {
        for _ in 0..<6 {
            if target.exists && target.isHittable { return true }
            strip.swipeLeft()
        }
        return target.exists && target.isHittable
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
