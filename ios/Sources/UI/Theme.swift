import SwiftUI

/// 全站的视觉规范。**任何新界面都从这里取值，不许随手写数字**——
/// 之前圆角有 8/9/10/12/14 五种、字号从 9 到 28 随便写，新功能一多就各长各的。
///
/// 定调：这是个"盯着屏幕抠发音"的工具，眼睛要盯很久。
/// 所以克制——一个主色只表示"正在生效"，语义色只用在打分上，其余一律中性。
enum T {

    // MARK: 间距（只用 4 的倍数）
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s6: CGFloat = 24

    static let gap: CGFloat = 8          // 控件之间
    static let pad: CGFloat = 12         // 卡片内边距
    static let side: CGFloat = 12        // 屏幕左右留白

    // MARK: 圆角（只有三档）
    static let ctl: CGFloat = 10         // 按钮、输入框
    static let card: CGFloat = 14        // 卡片
    static let sheet: CGFloat = 16       // 浮层、弹窗

    // MARK: 字号（只有六档，别再随手写）
    static let f1: CGFloat = 11          // 角标、秒数
    static let f2: CGFloat = 13          // 次要说明
    static let f3: CGFloat = 15          // 正文、按钮
    static let f4: CGFloat = 17          // 重点（打分按钮、小标题）
    static let f5: CGFloat = 22          // 大标题
    static let f6: CGFloat = 28          // 分数、今日句数

    // MARK: 控件高度
    // 44 是 HIG 的触摸目标下限。之前控制条里 32/34/38 三种高度混着用，
    // 一是都够不着 44，二是同一行的胶囊上下沿参差不齐。
    static let hCtl: CGFloat = 44        // 控制条上所有按钮，一律这个高
    static let hBig: CGFloat = 48        // 主按钮、打分
    static let hStrip: CGFloat = 56      // 底部控制条

    // MARK: 动效（只在三处用：浮层滑入、切句、分数出现）
    static let anim: Animation = .easeOut(duration: 0.18)
    static let animIn: Animation = .easeIn(duration: 0.22)

    // MARK: 波形——这是这个 App 的视觉符号，值得单独调
    enum Wave {
        /// 白天：暖砂色底 + 深琥珀波形。比原来那个橙黄沉稳，长时间看不累
        static let bgDay = Color(red: 0.97, green: 0.94, blue: 0.87)
        static let inkDay = Color(red: 0.42, green: 0.30, blue: 0.10)
        /// 夜间：深墨底 + 暖金波形，不刺眼
        static let bgNight = Color(red: 0.13, green: 0.12, blue: 0.11)
        static let inkNight = Color(red: 0.85, green: 0.65, blue: 0.32)
    }

    // MARK: 语义色（只用在打分和发音诊断上）
    //
    // 这几个颜色是**当正文色**用的（16pt semibold，够不上 WCAG 的"大字"门槛），
    // 所以要 4.5:1。系统的 .orange/.green 在浅色底上只有 1.86:1，
    // 之前打分那四个键全不合格，橙和绿在截图上明显发虚。
    // 下面白天这组是照着 4.5:1 往回压出来的（都留了余量）：
    //   会了 5.0:1   勉强 5.3:1   没听懂 4.5:1   脱口而出 5.7:1
    // 深色底要反过来提亮，否则同样看不清 —— 所以做成随主题变的动态色。
    enum Score {
        private static func dyn(_ day: (Double, Double, Double),
                               _ night: (Double, Double, Double)) -> Color {
            Color(UIColor { t in
                let c = t.userInterfaceStyle == .dark ? night : day
                return UIColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
            })
        }
        static let good  = dyn((0.08, 0.50, 0.24), (0.40, 0.85, 0.55))   // 会了
        static let ok    = dyn((0.62, 0.36, 0.02), (0.98, 0.75, 0.35))   // 勉强
        static let bad   = dyn((0.78, 0.16, 0.14), (1.00, 0.50, 0.45))   // 没听懂
        static let great = dyn((0.07, 0.40, 0.75), (0.45, 0.72, 1.00))   // 脱口而出
        /// 0~100 分对应的颜色，跟读逐词标色用同一套
        static func of(_ v: Int) -> Color { v >= 80 ? good : (v >= 60 ? ok : bad) }
    }
}

/// 次要控件：不抢眼，选中了才用主色
struct QuietButton: ButtonStyle {
    var on = false
    var wide = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: T.f2))
            .foregroundStyle(on ? Color.white : Color.primary.opacity(0.75))
            .frame(maxWidth: wide ? .infinity : nil, minHeight: T.hCtl)
            .padding(.horizontal, wide ? 0 : 11)
            .background(on ? Color.accentColor : Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: T.ctl, style: .continuous))
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// 图标按钮：靠留白撑开点击区，不靠底色
struct IconButton: ButtonStyle {
    var on = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: T.f3))
            .foregroundStyle(on ? Color.accentColor : Color.primary.opacity(0.55))
            .frame(width: 44, height: T.hCtl)
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
            .font(.system(size: T.f2))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(on ? Color.accentColor : Color.primary.opacity(0.7))
            .padding(.horizontal, 9).frame(height: T.hCtl)
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
