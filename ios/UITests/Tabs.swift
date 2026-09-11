import XCTest

/// 找底部（iPhone）/ 顶部（iPad）标签栏上的某一个标签。
///
/// iPad 上踩过的两层坑，都别再踩回去：
/// 1. **没有 TabBar 这个容器**（iPadOS 26 把标签栏做成顶部那条浮动胶囊），
///    `app.tabBars.buttons["材料"]` 永远空手而归；
/// 2. 退回按名字或按 identifier 找，**又会匹配到好几个** —— iPad 会同时挂着
///    两套标签栏元素（露在外面那条 + 收起来那套），真机报
///    "Multiple matching elements found"，整条真实流程测试全红。
///
/// 所以规矩是：拿到一批候选，挑**真正能点的那一个**（isHittable），
/// 一个都点不着才报错，并把候选个数打出来。
enum Tabs {
    static func find(_ app: XCUIApplication, _ name: String) -> XCUIElement {
        for q in [app.tabBars.buttons.matching(identifier: name),
                  app.buttons.matching(identifier: "tab.\(name)"),
                  app.buttons.matching(NSPredicate(format: "label == %@", name))] {
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
