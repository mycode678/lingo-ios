import SwiftUI
import StoreKit

/// 会员页。三档：连续包月 / 连续包年 / 买断。
///
/// **写这一屏的时候一直记着用户批评别家的那句话**：
/// > 上来就给一个普通用户完全听不懂的材料练习，然后不断的弹购买会员窗口，做app没有诚意。
///
/// 所以这一屏：
/// - 只在用户**主动点进来**或者**真的用完额度**时出现，不做定时弹窗
/// - 先讲免费能用什么（而且是真能用：核心的听、划、跟读打分、七个练法全免费）
/// - 再讲会员多给什么
/// - 价格从 StoreKit 现取，不在代码里写死数字
struct MemberScreen: View {
    @StateObject private var buy = Purchases.shared
    @StateObject private var ent = EntitlementService.shared
    var onClose: (() -> Void)?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: T.s3) {
                    header
                    freeCard
                    ForEach(buy.products, id: \.id) { p in productCard(p) }
                    if buy.products.isEmpty { emptyProducts }
                    restoreRow
                    terms
                }
                .padding(T.side)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("会员")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let onClose {
                    ToolbarItem(placement: .topBarLeading) { Button("关闭", action: onClose) }
                }
            }
            .task { await buy.load(); ent.reload() }
            .alert("没买成", isPresented: Binding(
                get: { buy.lastError != nil }, set: { if !$0 { buy.lastError = nil } })) {
                Button("知道了", role: .cancel) { buy.lastError = nil }
            } message: { Text(buy.lastError ?? "") }
        }
    }

    private var header: some View {
        VStack(spacing: T.s2) {
            Text(ent.tier.paid ? "你是 \(ent.tier.name) 会员" : "现在是免费用户")
                .font(.system(size: T.f5, weight: .bold))
            Text(ent.tier.paid ? "谢谢支持 —— 这个 App 没有广告轰炸，就是靠你们养着。"
                               : "核心功能免费，会员放开的是「量」。")
                .font(.system(size: T.f2)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, T.s4)
    }

    /// 先把"免费能用什么"讲清楚 —— 这是诚意，也是留住人的前提
    private var freeCard: some View {
        VStack(alignment: .leading, spacing: T.s2) {
            Text("免费一直能用").font(.system(size: T.f3, weight: .semibold))
            ForEach(["精听：波形圈选、反复听、变速不变调",
                     "跟读打分：逐词比对、节奏、连读、一句话诊断",
                     "七个练法的分级听力训练",
                     "复习排期、收藏、难点、录音（全在你自己手机上）"], id: \.self) { s in
                Label(s, systemImage: "checkmark").font(.system(size: T.f2))
                    .foregroundStyle(.secondary)
            }
            Text("每天 \(ent.limits.dailySentences ?? 0) 句、每周 \(ent.limits.weeklySentences ?? 0) 句"
                 + "预置材料；AI 拆解免费试用 \(EntitlementService.freeAIDays) 天。")
                .font(.system(size: T.f1)).foregroundStyle(.secondary).padding(.top, T.s1)
        }
        .padding(T.s4).frame(maxWidth: .infinity, alignment: .leading).cardStyle()
    }

    private func productCard(_ p: Product) -> some View {
        let pid = Purchases.PID(rawValue: p.id)
        let lim = pid.flatMap { EntitlementService.limits[$0.tier] }
        let mine = pid?.tier == ent.tier
        return VStack(alignment: .leading, spacing: T.s3) {
            HStack(alignment: .firstTextBaseline) {
                Text(pid?.tier.name ?? p.displayName)
                    .font(.system(size: T.f4, weight: .semibold))
                if pid == .lifetime {
                    Text("一次买断，不再扣费")
                        .font(.system(size: T.f1))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15))
                        .foregroundStyle(Color.accentColor)
                        .clipShape(Capsule())
                }
                Spacer()
                Text(p.displayPrice).font(.system(size: T.f4, weight: .bold)).monospacedDigit()
            }
            if let lim {
                Text(quotaLine(lim)).font(.system(size: T.f2)).foregroundStyle(.secondary)
            }
            Button {
                Task { await buy.buy(p) }
            } label: {
                Text(mine ? "当前方案" : "选它").frame(maxWidth: .infinity, minHeight: T.hBig)
            }
            .buttonStyle(.borderedProminent)
            .disabled(mine || buy.busy)
            .accessibilityIdentifier("member.buy." + p.id)
        }
        .padding(T.s4).frame(maxWidth: .infinity).cardStyle()
    }

    private func quotaLine(_ l: EntitlementService.Limits) -> String {
        func n(_ v: Int?) -> String { v.map(String.init) ?? "不限" }
        return "每天 \(n(l.dailySentences)) 句 · 每周 \(n(l.weeklySentences)) 句 · "
             + "AI 拆解每天 \(n(l.dailyAI)) 次 · 可导入 \(n(l.imports)) 份 · 材料包 \(n(l.packs)) 个"
    }

    private var emptyProducts: some View {
        VStack(spacing: T.s2) {
            Text("现在拉不到价格").font(.system(size: T.f3, weight: .medium))
            Text("可能是没联网，或者商品还没在 App Store 上架。\n免费功能不受影响，照常用。")
                .font(.system(size: T.f2)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(T.s4).frame(maxWidth: .infinity).cardStyle()
    }

    private var restoreRow: some View {
        Button {
            Task { await buy.restore() }
        } label: {
            Text("恢复购买").frame(maxWidth: .infinity, minHeight: T.hCtl)
        }
        .buttonStyle(.bordered)
        .accessibilityIdentifier("member.restore")
    }

    private var terms: some View {
        Text("订阅到期自动续费，可在「设置 → Apple ID → 订阅」里随时取消。"
             + "买断是一次性付费，不会再扣钱。")
            .font(.system(size: T.f1)).foregroundStyle(.secondary)
            .padding(.horizontal, T.s2).padding(.top, T.s2)
    }
}

/// 额度用完时弹的那一下。**一个 App 里只有这一处会主动提会员**。
struct QuotaBlockedView: View {
    var reason: String
    var onMember: () -> Void
    var onClose: () -> Void
    @StateObject private var ent = EntitlementService.shared

    var body: some View {
        VStack(spacing: T.s4) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 40)).foregroundStyle(.secondary)
            Text("今天先到这儿").font(.system(size: T.f5, weight: .semibold))
            Text(reason).font(.system(size: T.f2)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if ent.adsEnabled, ent.allowed(.adDaily) {
                Button {
                    _ = ent.rewardForAd()
                    onClose()
                } label: {
                    Label("看条广告再练 \(EntitlementService.sentencesPerAd) 句",
                          systemImage: "play.rectangle")
                        .frame(maxWidth: .infinity, minHeight: T.hBig)
                }
                .buttonStyle(.bordered)
            }
            Button { onMember() } label: {
                Text("看看会员多给多少").frame(maxWidth: .infinity, minHeight: T.hBig)
            }
            .buttonStyle(.borderedProminent)
            Button("明天再来", action: onClose)
                .font(.system(size: T.f2)).foregroundStyle(.secondary)
        }
        .padding(T.s6)
        .accessibilityIdentifier("quota.blocked")
    }
}
