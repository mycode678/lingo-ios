import SwiftUI
import AVFoundation

/// 谁在最上面。复习里点"拿去精听"要真的跳到精听台，光换句子不换页等于没反应。
@MainActor
final class Nav: ObservableObject {
    static let shared = Nav()
    // 0 今日 1 材料 2 精听 3 我的
    // 「今日」是首页：一进来就知道今天练什么，不用自己想。
    // 「材料」把查词、材料库、导入、视频、教程收在一起——它们都是"找东西练"。
    @Published var tab = 0
}

@main
struct LingoApp: App {
    @StateObject private var store = Store.shared
    @StateObject private var player = Player.shared
    @StateObject private var nav = Nav.shared
    @AppStorage("ui.accent") private var accent = "#2f6fd0"
    @AppStorage("ui.scheme") private var scheme = "system"

    init() {
        NowPlaying.shared.wire()
        if Demo.audit {
            // 体检模式：把"内容最多"的情况造出来 —— 四样文字全开、字号拉大。
            // 布局要是会压，这种组合最容易压。
            let d = UserDefaults.standard
            for k in ["show2.en", "show2.cn", "show2.dfe", "show2.dcn"] { d.set(true, forKey: k) }
            d.set(30.0, forKey: "ui.sentFont")
            d.set(22.0, forKey: "ui.cnFont")
        }
    }

    var body: some Scene {
        WindowGroup {
            rootView
        }
    }

    @ViewBuilder private var rootView: some View {
        if Demo.alignBench {
            if #available(iOS 17.0, *) { AlignBenchView() } else { Text("需要 iOS 17") }
        } else if Demo.land {
            GeometryReader { g in                 // 截横屏专用：按横屏尺寸渲染再转 90 度
                root
                    .frame(width: g.size.height, height: g.size.width)
                    .rotationEffect(.degrees(90))
                    .position(x: g.size.width / 2, y: g.size.height / 2)
            }
        } else {
            root
        }
    }

    private var root: some View {
            TabView(selection: $nav.tab) {
                TodayScreen().tabItem { Label("今天", systemImage: "sun.max") }
                    .badge(store.dueCount).tag(0)
                DictScreen().tabItem { Label("材料", systemImage: "books.vertical") }.tag(1)
                DrillScreen().tabItem { Label("精听", systemImage: "waveform") }.tag(2)
                LibScreen().tabItem { Label("我的", systemImage: "person") }.tag(3)
            }
            .environmentObject(store)
            .environmentObject(player)
            .environmentObject(nav)
            .tint(Color(hex: accent))
            .preferredColorScheme(scheme == "light" ? .light : (scheme == "dark" ? .dark : nil))
            .task {
                if Demo.on {
                    await store.look(Demo.word)
                    switch Demo.screen {
                    case "drill":  nav.tab = 2
                    case "dict":   nav.tab = 1
                    case "lib":    nav.tab = 3
                    default:       nav.tab = 0
                    }
                    return
                }
                await store.loadDueCount()
                await store.loadHist()
            }
            .onOpenURL { _ in }
    }
}

/// 全站通用的一点小组件
struct Pill: View {
    var text: String
    var on: Bool = false
    var body: some View {
        Text(text)
            .font(.system(size: 16))                 // "最近查过"那些词，13 太小了
            .padding(.horizontal, 13).padding(.vertical, 8)
            .background(on ? Color.accentColor : Color(.secondarySystemBackground))
            .foregroundStyle(on ? Color.white : Color.primary)
            .clipShape(Capsule())
    }
}

struct BigButton: View {
    var title: String
    var system: String?
    var prominent = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let system { Image(systemName: system) }
                Text(title)
            }
            .font(.system(size: 16, weight: .medium))
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(prominent ? Color.accentColor : Color(.secondarySystemBackground))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

extension View {
    /// .buttonStyle(cond ? .borderedProminent : .bordered) 编不过 —— 两个是不同类型，
    /// 只能分支写。包一个修饰器省事。
    @ViewBuilder func prominent(_ on: Bool) -> some View {
        if on { self.buttonStyle(.borderedProminent) } else { self.buttonStyle(.bordered) }
    }
    func card(_ bg: Color? = nil) -> some View {
        self.padding(14)
            .background(bg ?? Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
