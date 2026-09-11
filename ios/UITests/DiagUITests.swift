import XCTest

/// 真机诊断：**只看不改**。
///
/// 起因：他在手机上点材料库下载，一直提示"拿不到材料目录"。
/// 我在 cd1 上用 curl 试是 401（服务器一律要账号密码），但改完提示他说还是一样 ——
/// 那就不能再猜了，直接上他的手机把**那行小字到底写的什么**抓回来。
///
/// 这个测试不打字、不点保存、不碰他的账号密码，只做三件事：
/// 切到材料页 → 把屏幕上所有文字抄下来 → 截图。
final class DiagUITests: XCTestCase {

    override func setUp() {
        continueAfterFailure = true          // 诊断用，中间断言失败也要把后面的信息抓全
        XCUIDevice.shared.orientation = .portrait
    }

    /// 屏幕上所有看得见的文字，一行一条
    private func texts(_ app: XCUIApplication) -> String {
        app.staticTexts.allElementsBoundByIndex
            .prefix(60)
            .map { $0.label }
            .filter { !$0.isEmpty }
            .joined(separator: "\n  · ")
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testWhatTheCatalogErrorActuallySays() {
        let app = XCUIApplication()
        app.launch()                          // 真环境，不加 -demo

        // 「材料」是第 2 个标签。iPad 上标签栏是顶部浮动条、不是 TabBar 容器，
        // 按 tabBars 找会空手而归 —— 找不到就退回整屏找同名按钮。
        let tab = Tabs.find(app, "材料")
        XCTAssertTrue(tab.waitForExistence(timeout: 20), "连标签栏都没出来")
        tab.tap()

        // 目录是网络请求，给足时间
        sleep(12)
        shot(app, "材料页")
        print("【材料页上的文字】\n  · " + texts(app))

        // 有那个按钮就说明确实进了报错分支
        let go = app.buttons["去填账号密码"]
        print("【有没有「去填账号密码」按钮】\(go.exists)")

        // 顺便看一眼设置里服务器那一段填没填 —— 只读，不输入不保存
        Tabs.find(app, "我的").tap()
        sleep(3)
        let gear = app.navigationBars.buttons.element(boundBy: app.navigationBars.buttons.count - 1)
        if gear.exists { gear.tap(); sleep(3) }
        shot(app, "设置页")
        print("【设置页上的文字】\n  · " + texts(app))
        // 账号框里有没有东西（密码框是 SecureField，读不到内容，只看存在）
        let userField = app.textFields.matching(
            NSPredicate(format: "placeholderValue CONTAINS '账号'")).firstMatch
        if userField.exists {
            print("【账号框里现在是】'\(userField.value as? String ?? "")'")
        } else {
            print("【账号框】没找到（可能没滚到那一段）")
        }
    }
}
