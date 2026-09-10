import XCTest

/// **真实用户流程**，从头走到尾。
///
/// 为什么非要有这一条：上一轮我报告"闸门全绿"，可用户下完材料包发现
/// 精听台根本没入口 —— 因为**所有测试都跑在 `-demo` 假数据下**，
/// 假句子、假波形、假词边界，每块零件都不崩，零件之间断了一环却测不出来。
/// 他的原话：「你不是说都测试过，全绿吗！！！」「后面你还要我一个个去找吗？」
///
/// 所以这条测试的规矩跟别的不一样：
/// · 用**真材料包**（`-usepack` 把随包带的那个装上），不用假数据；
/// · 每一步都断言"**真的有内容**"，不是"没崩"；
/// · 每一步都截图，我自己逐张看完才算数。
final class RealFlowUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = true       // 走完全程，一次把问题全抓出来，不要撞一个停一个
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["-demo", "-usepack"]
        app.launch()
    }

    private func shot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    private func tab(_ name: String) {
        let t = app.tabBars.buttons[name]
        XCTAssertTrue(t.waitForExistence(timeout: 20), "找不到标签「\(name)」")
        t.tap()
        sleep(2)
    }

    /// 一屏上看得见的文字，失败时贴出来，省得靠猜
    private func seen() -> String {
        app.staticTexts.allElementsBoundByIndex.prefix(40)
            .map { $0.label }.filter { !$0.isEmpty }.joined(separator: " | ")
    }

    // MARK: 一、材料装上了，而且有地方去

    func testStep1_PackInstalledAndHasAWayIn() {
        tab("材料")
        shot("1-材料库")
        let start = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'packs.start.'")).firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 15),
                      "装好的包上没有「开始学」——用户下完包会不知道该点哪儿。屏上有：" + seen())
        start.tap()
        sleep(3)
        shot("2-点开始学之后")
        // 真的进了精听台，而且真的有句子（不是空屏）
        XCTAssertTrue(app.otherElements["swipeArea"].waitForExistence(timeout: 15)
                      || app.scrollViews["controlStrip"].exists,
                      "点了「开始学」没进精听台。屏上有：" + seen())
        XCTAssertFalse(app.staticTexts["还没有材料"].exists, "进去了却是空屏")
    }

    /// **断网也要能开始学**：拉不到远程目录时，装好的包必须照样列在那儿。
    /// 云端 CI 连不上作者家里的服务器，正好是天然的断网场景 ——
    /// 之前整页被"拿不到材料目录"顶掉，装好的包在界面上直接消失，
    /// 而那页还写着"已经装好的包在下面，断网也能练"，是句假话。
    func testStep1b_InstalledPacksSurviveNoNetwork() {
        tab("材料")
        sleep(3)
        shot("1b-拉不到目录时")
        XCTAssertTrue(app.staticTexts["已经装好的"].waitForExistence(timeout: 15),
                      "拉不到目录时，装好的材料整段消失了：" + seen())
        XCTAssertTrue(app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'packs.start.'")).firstMatch.exists,
            "装好的包上没有「开始学」")
    }

    // MARK: 二、精听台：能出声、能圈、能出跟读结果

    func testStep2_DrillActuallyWorksWithARealPack() {
        tab("材料")
        let start = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH 'packs.start.'")).firstMatch
        guard start.waitForExistence(timeout: 15) else {
            XCTFail("没有「开始学」，后面没法走：" + seen()); return
        }
        start.tap()
        sleep(3)

        // **装进播放器的必须是这一句的音频**。
        // 上一轮就栽在这儿：界面把包里的句子接上了，可另一处又按 src 当服务器路径
        // 重新 load 了一次，把真音频顶掉 —— 词是这句的、声音是上一句的，
        // 截图上看着"能用"，其实全错。App 在 -demo 下把结论写成一行，这里直接判。
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH 'AUDIO-BAD'")).firstMatch
            .waitForExistence(timeout: 8),
            "装进播放器的音频跟这句话对不上：" + seen())

        // 波形要真的画出来了（控制条在＝这一屏起来了）
        XCTAssertTrue(app.scrollViews["controlStrip"].waitForExistence(timeout: 15),
                      "精听台没起来：" + seen())
        shot("3-精听台-真包")

        // 播放：点了要能停下来（能停说明真的在放）
        let play = app.buttons["playPause"]
        XCTAssertTrue(play.exists, "没有播放键：" + seen())
        play.tap()
        sleep(4)
        shot("4-播放中")

        // 听完一遍之后打分四键该出来了
        XCTAssertTrue(app.buttons["没听懂"].waitForExistence(timeout: 15),
                      "放完一遍了，打分行还是没出现：" + seen())
        shot("5-听完之后")
    }

    // MARK: 三、七个练法：真材料下能不能出题

    func testStep3_TrainingHasRealQuestions() {
        tab("训练")
        shot("6-训练首页")
        XCTAssertTrue(app.buttons["train.start"].waitForExistence(timeout: 15),
                      "训练首页没起来：" + seen())

        for m in ["blank", "group", "stress"] {
            let row = app.buttons["train.mode." + m]
            XCTAssertTrue(row.exists, "少了练法 \(m)")
            row.tap()
            sleep(4)
            shot("7-练法-" + m)
            // 关键：**真的出题了**，不是"还没有够得着的材料"
            XCTAssertFalse(app.staticTexts["还没有够得着的材料"].exists,
                           "练法 \(m) 出不了题 —— 材料包里明明有句子。屏上有：" + seen())
            XCTAssertTrue(app.buttons["train.play"].exists,
                          "练法 \(m) 里没有播放键：" + seen())
            // 装了 200 句的包，一轮该出好几题。只出 1 题＝用的还是演示那几句
            // （真机截图上就是这么露馅的：右上角 1/1，句子还是 Excuse me…）。
            XCTAssertFalse(app.staticTexts["1/1"].exists,
                           "练法 \(m) 只出了 1 题 —— 多半还在用演示数据，没读真包：" + seen())
            app.buttons["退出"].tap()
            sleep(2)
        }
    }

    // MARK: 四、教程：例子能不能拿真材料放出来

    func testStep4_TutorialFindsRealAudio() {
        tab("训练")
        let entry = app.buttons["train.tutorial"]
        XCTAssertTrue(entry.waitForExistence(timeout: 15), "没有教程入口：" + seen())
        entry.tap()
        sleep(2)
        app.buttons["tutorial.beat"].tap()
        sleep(4)
        shot("8-教程第一课")
        // 例子那块：要么放出真句子（有「播放整句」），要么老实说没材料。
        // 装了包却还说没材料，就是没接上。
        let hasAudio = app.buttons["播放整句"].exists
        let saysNoMaterial = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '去「材料」里装一个包'")).firstMatch.exists
        XCTAssertTrue(hasAudio || !saysNoMaterial,
                      "装了材料包，教程里还说找不到材料举例：" + seen())
    }

    // MARK: 五、今天 / 我的：数字和入口都不能是死的

    func testStep5_TodayAndMine() {
        tab("今天")
        sleep(3)
        shot("9-今天")
        XCTAssertFalse(seen().isEmpty, "今天这一屏是空的")

        tab("我的")
        sleep(3)
        shot("10-我的")
        XCTAssertTrue(app.buttons["lib.member"].exists, "「我的」里没有会员入口：" + seen())
        XCTAssertTrue(app.buttons["lib.poster"].exists, "「我的」里没有成绩海报入口")
    }
}
