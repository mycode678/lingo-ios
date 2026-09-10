import Foundation
import StoreKit

/// 内购。用 StoreKit 2（`Product` / `Transaction`），不引任何第三方 SDK。
///
/// 三档，跟方案一致：**连续包月 / 连续包年 / 买断**。
/// 定价策略是"引导用户一次买断"，所以年费要接近买断价 —— 具体数字在
/// App Store Connect 里定，代码里不写死。
///
/// **服务器一行不掺和**：StoreKit 2 的交易本身带苹果签名，`Transaction.currentEntitlements`
/// 在本机就能验；再把结果落进 `user.sqlite`，断网时照样知道你是会员。
/// （这跟"完全脱离服务器"是同一个方向：多一个校验服务器，就多一个挂了就全员降级的地方。）
@MainActor
final class Purchases: ObservableObject {
    static let shared = Purchases()

    enum PID: String, CaseIterable {
        case monthly  = "com.lingo.listen.monthly"
        case yearly   = "com.lingo.listen.yearly"
        case lifetime = "com.lingo.listen.lifetime"

        var tier: EntitlementService.Tier {
            switch self {
            case .monthly:  return .monthly
            case .yearly:   return .yearly
            case .lifetime: return .lifetime
            }
        }
    }

    @Published private(set) var products: [Product] = []
    @Published private(set) var busy = false
    @Published var lastError: String?

    private var watcher: Task<Void, Never>?

    private init() {}

    /// 开机时叫一次：拉商品、补上没处理完的交易、按当前权益定身份
    func start() {
        guard !Demo.on else { return }        // 云端模拟器里没有 StoreKit 环境
        watcher?.cancel()
        watcher = Task { [weak self] in
            // 苹果可能在 App 外完成交易（比如家庭共享、审核期补发），要一直接着
            for await update in Transaction.updates {
                if case .verified(let t) = update {
                    await t.finish()
                    await self?.refreshEntitlement()
                }
            }
        }
        Task { await load(); await refreshEntitlement() }
    }

    func load() async {
        do {
            let ps = try await Product.products(for: PID.allCases.map(\.rawValue))
            // 摆放顺序固定：月 → 年 → 买断，买断放最后（最想让人选的放最下面，
            // 拇指最容易够到，且看完前两个价钱之后再看它才显得划算）
            products = PID.allCases.compactMap { pid in ps.first { $0.id == pid.rawValue } }
        } catch {
            lastError = "商品列表拉不到：\(error.localizedDescription)"
        }
    }

    func buy(_ p: Product) async {
        busy = true
        defer { busy = false }
        do {
            switch try await p.purchase() {
            case .success(let v):
                if case .verified(let t) = v {
                    await t.finish()
                    await refreshEntitlement()
                } else {
                    lastError = "这笔交易的签名验不过，没有给你开通。请联系客服。"
                }
            case .userCancelled:  break
            case .pending:        lastError = "交易在等待批准（比如需要家长同意），批准后会自动开通。"
            @unknown default:     break
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// 「恢复购买」—— 换手机、重装之后要有这个按钮，苹果审核也要求有
    func restore() async {
        busy = true
        defer { busy = false }
        try? await AppStore.sync()
        await refreshEntitlement()
    }

    /// 按当前有效权益算身份。买断优先于订阅（买过断就一直是买断）。
    func refreshEntitlement() async {
        var best: EntitlementService.Tier = .free
        for await r in Transaction.currentEntitlements {
            guard case .verified(let t) = r, let pid = PID(rawValue: t.productID) else { continue }
            if t.revocationDate != nil { continue }             // 退过款的不算
            if let exp = t.expirationDate, exp < Date() { continue }
            let tier = pid.tier
            if tier == .lifetime { best = .lifetime; break }
            if best != .lifetime, tier == .yearly { best = .yearly }
            else if best == .free { best = tier }
        }
        EntitlementService.shared.setTier(best)
    }
}
