import XCTest

/// 找底部（iPhone）/ 顶部（iPad）标签栏上的某一个标签。
///
/// 为什么要单开一个：**iPad 上没有 TabBar 这个容器**（iPadOS 26 把标签栏做成
/// 顶部那条浮动胶囊），`app.tabBars.buttons["材料"]` 永远空手而归；
/// 退回 `app.buttons["材料"]` 又会撞上屏幕里同名的按钮 ——
/// 真机上就报 "Multiple matching elements found"。
/// 所以 App 给每个标签挂了 `tab.<名字>` 的 identifier，这里优先认它。
enum Tabs {
    static func find(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let byTabBar = app.tabBars.buttons[name]
        if byTabBar.waitForExistence(timeout: 5) { return byTabBar }
        let byId = app.buttons["tab.\(name)"]
        if byId.waitForExistence(timeout: 5) { return byId }
        // 再退一步：identifier 没传下来时，按名字取第一个（并把候选个数打出来，
        // 下次看日志就知道是撞名还是真没有）
        let q = app.buttons.matching(NSPredicate(format: "label == %@", name))
        print("【找标签】\(name) tabBar:无 id:无 同名按钮 \(q.count) 个")
        return q.element(boundBy: 0)
    }
}
