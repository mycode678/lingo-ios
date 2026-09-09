import SwiftUI

/// 一个口子拿到所有依赖。
///
/// 为什么要有它（不是为了"优雅"）：现在到处 `Player.shared`、`Store.shared`、`Api.xxx`，
/// **这些单例在测试里换不掉**。七个练法、额度、奖励这些逻辑必须能单独测，
/// 不能每加一条规则就开一次模拟器点一遍。有了这个口子，Service 层从它拿依赖，
/// 测试时塞一份假的进去就行。
@MainActor
final class AppEnv: ObservableObject {
    static let shared = AppEnv()

    let db: DB

    /// 开库或迁移失败时记在这儿。**不崩** ——
    /// 数据库坏了顶多是进度记不住，不该让人连听都听不成。
    @Published private(set) var dbError: String?

    init(db: DB = .user) {
        self.db = db
        do {
            try db.migrate()
        } catch {
            dbError = "\(error)"
            print("【DB】\(error)")
        }
    }
}
