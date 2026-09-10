import XCTest

/// 断言失败时把屏幕上有什么打出来。
/// 写成自由函数是有原因的：原来那个 `dump` 是某个测试类的私有方法，
/// 别的类里写 `dump(app)` 会静默解析成标准库的 `Swift.dump`，
/// 编译报 "'NSObject' is not convertible to 'String'"，很难一眼看出。
func describe(_ app: XCUIApplication) -> String {
    let names = app.buttons.allElementsBoundByIndex.prefix(40).map { $0.label }
    let ids = app.descendants(matching: .any).allElementsBoundByIndex.prefix(60)
        .compactMap { $0.identifier.isEmpty ? nil : $0.identifier }
    return "按钮：" + names.joined(separator: " | ") + "；标识：" + Set(ids).joined(separator: " | ")
}

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
        // 按他给的高频顺序排完，最右边那个是 ⋯（更多），不再是「自定」倍速。
        // 这一条要保证的是"整条真的能滑到底"，所以盯最后一个元素。
        // 盯最后一个元素才测得出"整条真的能滑到底"。
        // 用自己起的标识，不用 SF Symbol 的英文无障碍名 —— 那个换个系统语言就找不到了。
        XCTAssertTrue(scrollToEnd(strip, target: app.descendants(matching: .any)["moreMenu"].firstMatch),
                      "控制条滑到底也点不到最后一个（⋯）；" + dump(app))
    }

    /// 横屏：同样要能滑。这一条就是为了逮住"横屏滚不动"那个 bug。
    func testLandscapeStripScrolls() {
        let app = launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let strip = app.scrollViews.matching(identifier: "controlStrip").firstMatch
        XCTAssertTrue(strip.waitForExistence(timeout: 10), "横屏找不到控制条")
        XCTAssertTrue(scrollToEnd(strip, target: app.descendants(matching: .any)["moreMenu"].firstMatch),
                      "横屏控制条滑到底也点不到最后一个（⋯）；" + dump(app))
    }

    /// 波形上必须能长按拖出选区（长按 0.18 秒再拖）
    func testDrawSelectionOnWaveform() {
        let app = launch()
        let wave = app.otherElements["waveform"]
        XCTAssertTrue(wave.waitForExistence(timeout: 10), "找不到波形")
        // 波形这个元素在音频还没装好时就已经在了。这时候拖，时间轴还是 0 长度，
        // 拖了也画不出选区。等小句出来再拖 —— 小句是切完词才有的，
        // 它出来就说明音频和词边界都到位了。
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Excuse me can you tell'")).firstMatch
            .waitForExistence(timeout: 15), "等不到小句，音频/词边界没装好")
        let a = wave.coordinate(withNormalizedOffset: CGVector(dx: 0.30, dy: 0.5))
        let b = wave.coordinate(withNormalizedOffset: CGVector(dx: 0.62, dy: 0.5))
        // 现在单指按下一动就画选区（不用等长按），跟 PC 上鼠标一个手感
        a.press(forDuration: 0.05, thenDragTo: b)
        // 画出来之后波形右上角会浮出 "1.43–1.89s" 的角标
        let badge = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '–' AND label CONTAINS 's'")).firstMatch
        XCTAssertTrue(badge.waitForExistence(timeout: 3),
                      "在波形上拖动没有画出选区；" + dump(app))
    }

    /// 录完之后：结果面板要自己弹出来，控制条上要出现"对比"。
    /// （他反馈过"录音后的对比按钮一直没有"，这条就是钉住它。）
    func testTakePanelAndCompareButton() {
        let app = launch(["-take"])          // -take＝假装刚录完一条
        XCTAssertTrue(app.buttons["对比"].waitForExistence(timeout: 10),
                      "录完了但控制条上没有「对比」；" + dump(app))
        XCTAssertTrue(app.buttons["我的"].exists, "结果面板里没有「我的」")
        // 分项现在叫 音准/节奏/连读（原来叫词准/语调/节奏）
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '音准'")).firstMatch.waitForExistence(timeout: 5),
            "结果面板里没有分项得分；" + dump(app))
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
        // 「显示」排在几档倍速后面，一进来在屏幕外，得先把控制条滑过去。
        let strip = app.scrollViews.matching(identifier: "controlStrip").firstMatch
        XCTAssertTrue(scrollToEnd(strip, target: app.buttons["显示"]),
                      "滑到底也点不到「显示」；" + dump(app))
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
    /// 把体检报告（每块的真实 y 坐标和高度）打进测试日志。
    /// 眼睛在截图上估"波形是不是长高了"估不准，这里给的是真数。
    private func audit(_ app: XCUIApplication, _ when: String) {
        let p = app.otherElements["auditReport"]
        XCTAssertTrue(p.waitForExistence(timeout: 8), "【体检 \(when)】拿不到体检探针")
        XCTAssertFalse(p.label.isEmpty, "【体检 \(when)】体检没出结果")
        print("【体检 \(when)】" + p.label)
        // 有重叠/超屏就让测试红 —— 光打印不断言，这套体检在 CI 里等于摆设
        XCTAssertFalse(p.label.contains("LAYOUT-FAIL"),
                       "【体检 \(when)】布局有重叠或超出屏幕：" + p.label)
        let att = XCTAttachment(string: p.label)
        att.name = "体检 " + when; att.lifetime = .keepAlways
        add(att)
    }

    func testCaptureScreens() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-screen", "drill", "-audit"]
        app.launch()
        XCUIDevice.shared.orientation = .portrait
        sleep(3); shot(app, "竖屏"); audit(app, "竖屏")

        // 跟读结果是最容易排版翻车的一屏（诊断折行、分项对齐、字号），
        // 每轮都要截，而且要截字号调大之后的样子。
        let big = XCUIApplication()
        big.launchArguments = ["-demo", "-screen", "drill", "-take", "-bigfont"]
        big.launch()
        sleep(4); shot(big, "跟读结果")
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(3); shot(big, "跟读结果横屏")
        XCUIDevice.shared.orientation = .portrait
        big.terminate()
        app.activate()
        sleep(2)
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(3); shot(app, "横屏")
        // 文字全开：最容易把波形挤没的情况
        app.buttons["显示"].tap()
        for t in ["原文", "译文", "中文释义", "英文释义"] where app.buttons[t].exists {
            app.buttons[t].tap(); app.buttons["显示"].tap()
        }
        // 循环最后一轮把菜单又打开了，不关掉的话这两张最该看清版式的截图
        // 有大半被弹出的菜单盖住
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.06)).tap()
        sleep(2); shot(app, "横屏-文字全开"); audit(app, "横屏-文字全开")
        XCUIDevice.shared.orientation = .portrait
        sleep(3); shot(app, "竖屏-文字全开"); audit(app, "竖屏-文字全开")
    }
}

/// 离线引擎验证：手机上自己算的对齐，和服务器算的（fa.db 那份）差多少？
/// 这一条决定"能不能彻底摆脱服务器"——差得多就说明模型转换有损失，路子走不通。
final class AlignerUITests: XCTestCase {
    func testOnDeviceAlignmentMatchesServer() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-alignbench"]
        app.launch()
        // App 里跑完会把结果打在屏幕上（-alignbench 专用的一屏）
        let result = app.staticTexts["alignResult"]
        XCTAssertTrue(result.waitForExistence(timeout: 120), "对齐没跑出结果")
        // 把数字写进测试报告，不然只看到"通过"看不到误差多少
        let att = XCTAttachment(string: "【对齐验证】" + result.label)
        att.name = "对齐验证结果"; att.lifetime = .keepAlways
        add(att)
        print("【对齐验证】" + result.label)
        // 屏幕上会写 "最大误差 xx 毫秒"，超过 80 毫秒就算不合格
        let ok = app.staticTexts["alignVerdict"]
        XCTAssertTrue(ok.waitForExistence(timeout: 5))
        XCTAssertTrue(ok.label.contains("通过"), "对齐质量不达标：" + ok.label)
    }
}

/// 本机库：这是"脱离服务器"的地基，必须钉死。
/// 验的是**真机上杀掉 App 再打开数据还在**，以及迁移跑两遍不出错。
final class DBUITests: XCTestCase {
    private func val(_ app: XCUIApplication, _ id: String) -> String {
        let e = app.staticTexts[id]
        return e.waitForExistence(timeout: 20) ? e.label : "（没出现：\(id)）"
    }

    func testLocalDBSurvivesRelaunch() {
        // 第一趟：建库、迁移两遍、写一条进度
        let a = XCUIApplication()
        a.launchArguments = ["-dbtest", "-dbwrite"]
        a.launch()
        // 加了表就要把这两个数改掉（v4 训练记账、v5 每天练了多少）。
        // 这条测试**就该在改库时红一次** —— 它是"你动了库结构"的提醒。
        XCTAssertEqual(val(a, "dbVersion"), "5", "库版本不对")
        XCTAssertEqual(val(a, "dbIdempotent"), "一样，OK", "迁移跑两遍结果不一样")
        XCTAssertEqual(val(a, "dbTables"), "12 张都在", "表结构不对")
        XCTAssertEqual(val(a, "dbSchedule"), "OK", "本地复习排期算错了")
        XCTAssertEqual(val(a, "dbFavMark"), "OK", "本地收藏/难点不对")
        XCTAssertEqual(val(a, "packInstall"), "OK", "材料包装不上或内容不全")
        XCTAssertEqual(val(a, "packRemove"), "OK", "删包把用户数据一起删了")
        XCTAssertEqual(val(a, "dbText"), "OK", "中文存取串了")
        XCTAssertEqual(val(a, "dbWrote"), "写好了", "没写进去")
        a.terminate()

        // 第二趟：App 是真的被杀掉之后重开的，数据必须还在
        let b = XCUIApplication()
        b.launchArguments = ["-dbtest"]
        b.launch()
        XCTAssertEqual(val(b, "dbReadBack"), "值一样，OK", "重开之后数据没了或对不上")
    }
}

/// 断网演练：服务器全挂的时候，核心功能还能不能用。
///
/// 这一条才是"脱离服务器"的真验收 —— 不是"确认 App 从不联网"
/// （顺手备份是合理的），而是**所有请求都失败时，听、划、打分、复习照常**。
final class OfflineUITests: XCTestCase {
    func testCoreLoopWorksWithServerDown() {
        let app = XCUIApplication()
        app.launchArguments = ["-demo", "-screen", "drill", "-nonet"]
        app.launch()

        // 1) 波形出得来（音频、词边界都不靠服务器）
        XCTAssertTrue(app.otherElements["waveform"].waitForExistence(timeout: 20), "断网就没波形了")
        // 2) 小句出得来（说明词边界到位）
        let chunk = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Excuse me can you tell'")).firstMatch
        XCTAssertTrue(chunk.waitForExistence(timeout: 20), "断网就切不出小句")
        chunk.tap()
        // 3) 打分要能算出下次复习时间 —— 这一步以前是发请求给服务器算的
        XCTAssertTrue(app.buttons["会了"].waitForExistence(timeout: 5), "找不到打分键")
        app.buttons["会了"].tap()
        let flash = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '下次'")).firstMatch
        XCTAssertTrue(flash.waitForExistence(timeout: 5),
                      "断网时打分没算出下次复习时间（说明还在等服务器）；" + describe(app))
        // 4) 顺手看看这一段里谁想联网、被挡了几次（不做断言，只写进日志）
        let probe = app.otherElements["netBlocked"]
        if probe.waitForExistence(timeout: 3) { print("【断网演练】被挡下的请求：" + probe.label) }
    }
}
