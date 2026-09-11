import XCTest

/// 找底部（iPhone）/ 顶部（iPad）标签栏上的某一个标签。
///
/// 三层坑，都是真机和云端各踩一次换来的，别再改回去：
/// 1. **iPad 没有 TabBar 容器**（iPadOS 26 把标签栏做成顶部那条浮动胶囊），
///    `app.tabBars.buttons[...]` 永远空手而归；
/// 2. 退回"按名字找按钮"，iPad 上会匹配到好几个（屏幕里还有同名按钮），
///    报 Multiple matching elements；
/// 3. 于是给每个标签挂了 `tab.<名字>` 的 identifier —— 但这样一来
///    **iPhone 上按名字找又不灵了**（identifier 变成了 tab.材料），云端整片红。
///
/// 所以老老实实按四种查法依次试，每一批里挑**真正能点的那个**。
enum Tabs {
    static func find(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        let byLabel = NSPredicate(format: "label == %@", name)
        let queries = [app.tabBars.buttons.matching(identifier: "tab.\(name)"),
                       app.buttons.matching(identifier: "tab.\(name)"),
                       app.tabBars.buttons.matching(byLabel),
                       app.buttons.matching(byLabel)]
        for q in queries {
            _ = q.firstMatch.waitForExistence(timeout: 5)
            let n = q.count
            guard n > 0 else { continue }
            for i in 0..<n {
                let e = q.element(boundBy: i)
                if e.exists && e.isHittable { return e }
            }
            print("【找标签】\(name)：\(n) 个候选，但一个都点不着")
        }
        return app.buttons["tab.\(name)"]      // 让调用方的断言去报错
    }
}
