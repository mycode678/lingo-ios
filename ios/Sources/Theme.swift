import SwiftUI

/// 一套尺寸和颜色，全站只认这里 —— 圆角、间距、按钮样式散在各处迟早不统一。
/// 小屏上眼睛盯得久，克制比花哨重要：一个主色管"正在生效"，其余一律中性灰。
enum T {
    static let card: CGFloat = 14        // 卡片圆角
    static let ctl: CGFloat = 10         // 控件圆角
    static let gap: CGFloat = 8          // 常规间距
    static let pad: CGFloat = 12         // 卡片内边距
    static let side: CGFloat = 10        // 屏幕左右留白
}

/// 次要控件：不抢眼，选中了才用主色
struct QuietButton: ButtonStyle {
    var on = false
    var wide = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(on ? Color.white : Color.primary.opacity(0.75))
            .frame(maxWidth: wide ? .infinity : nil, minHeight: 34)
            .padding(.horizontal, wide ? 0 : 11)
            .background(on ? Color.accentColor : Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: T.ctl, style: .continuous))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// 图标按钮：顶栏用，靠留白撑开点击区，不靠底色
struct IconButton: ButtonStyle {
    var on = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .regular))
            .foregroundStyle(on ? Color.accentColor : Color.primary.opacity(0.55))
            .frame(width: 40, height: 34)
            .background(on ? Color.accentColor.opacity(0.14) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}

/// 图标＋两个字：光图标猜不出是干嘛的（"整句""铺满"这种），配上字一眼就懂
struct LabelButton: ButtonStyle {
    var on = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(on ? Color.accentColor : Color.primary.opacity(0.7))
            .padding(.horizontal, 9).frame(height: 32)
            .background(on ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}

extension View {
    /// 统一的卡片外观
    func cardStyle(_ bg: Color? = nil) -> some View {
        self.background(bg ?? Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: T.card, style: .continuous))
    }
}
