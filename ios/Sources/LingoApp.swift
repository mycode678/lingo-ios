import SwiftUI
import AVFoundation

/// 谁在最上面。复习里点"拿去精听"要真的跳到精听台，光换句子不换页等于没反应。
@MainActor
final class Nav: ObservableObject {
    static let shared = Nav()
    @Published var tab = 0          // 0 查词 1 精听 2 复习 3 我的库
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
    }

    var body: some Scene {
        WindowGroup {
            TabView(selection: $nav.tab) {
                DictScreen().tabItem { Label("查词", systemImage: "magnifyingglass") }.tag(0)
                DrillScreen().tabItem { Label("精听", systemImage: "waveform") }.tag(1)
                ReviewScreen().tabItem { Label("复习", systemImage: "arrow.triangle.2.circlepath") }
                    .badge(store.dueCount).tag(2)
                LibScreen().tabItem { Label("我的库", systemImage: "books.vertical") }.tag(3)
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
                    case "drill":  nav.tab = 1
                    case "review": nav.tab = 2
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
}

/// 全站通用的一点小组件
struct Pill: View {
    var text: String
    var on: Bool = false
    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .padding(.horizontal, 12).padding(.vertical, 7)
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
    func card() -> some View {
        self.padding(14)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}
