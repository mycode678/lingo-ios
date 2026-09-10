import SwiftUI
import AVFoundation

/// 谁在最上面。复习里点"拿去精听"要真的跳到精听台，光换句子不换页等于没反应。
@MainActor
final class Nav: ObservableObject {
    static let shared = Nav()
    // 0 今日 1 材料 2 精听 3 训练 4 我的
    // 「今日」是首页：一进来就知道今天练什么，不用自己想。
    // 「材料」把查词、材料库、导入、视频、教程收在一起——它们都是"找东西练"。
    @Published var tab = 0
}

@main
struct LingoApp: App {
    @StateObject private var store = Store.shared
    @StateObject private var player = Player.shared
    @StateObject private var nav = Nav.shared
    @StateObject private var env = AppEnv.shared
    @AppStorage("ui.accent") private var accent = "#2f6fd0"
    @AppStorage("ui.scheme") private var scheme = "system"

    init() {
        NowPlaying.shared.wire()
        // -demo 下**每次都把这几个偏好写死**，不管上一次跑剩下什么。
        //
        // 为什么必须这样：同一台模拟器上先跑截图（-audit 会把四样文字全打开、
        // 字号拉到 30）、再跑交互测试，UserDefaults 是留在应用容器里的 ——
        // 于是"默认什么文字都不显示"那条测试拿到的是上一轮留下的 true，直接红。
        // 以前横屏的 onAppear 会顺手把它们清成 false，把这个污染盖住了；
        // 那行代码是错的（它会抹掉用户的真实偏好），删掉之后污染就露出来了。
        //
        // 测试和截图必须是可重复的：同样的启动参数，永远同样的起始状态。
        if Demo.on {
            let d = UserDefaults.standard
            let full = Demo.audit          // 体检要的是"内容最多"的那种情况
            for k in ["show2.en", "show2.cn", "show2.dfe", "show2.dcn"] { d.set(full, forKey: k) }
            d.set(full ? 30.0 : 21.0, forKey: "ui.sentFont")
            d.set(full ? 22.0 : 16.0, forKey: "ui.cnFont")
            d.set(Demo.bigFont ? 26.0 : 17.0, forKey: "ui.resultFont")
        }
    }

    var body: some Scene {
        WindowGroup {
            rootView
        }
    }

    @ViewBuilder private var rootView: some View {
        if ProcessInfo.processInfo.arguments.contains("-dbtest") {
            DBSelfTest()
        } else if Demo.alignBench {
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
                // 「材料」现在是材料库（按身份挑、按难度挑、可预览）。
                // 查词挪到右上角 —— 它是朗文的内容，受版权限制，不该当门面。
                PackStoreScreen().tabItem { Label("材料", systemImage: "books.vertical") }.tag(1)
                DrillScreen().tabItem { Label("精听", systemImage: "waveform") }.tag(2)
                // 「训练」是这个 App 的核心竞争力（分级听力练习系统，别家没有），
                // 所以给它一个一级入口，不藏在「今天」下面。
                TrainHomeScreen().tabItem { Label("训练", systemImage: "figure.run") }.tag(3)
                LibScreen().tabItem { Label("我的", systemImage: "person") }.tag(4)
            }
            .environmentObject(store)
            .environmentObject(player)
            .environmentObject(nav)
            .environmentObject(env)
            .tint(Color(hex: accent))
            .preferredColorScheme(scheme == "light" ? .light : (scheme == "dark" ? .dark : nil))
            .task {
                if Demo.on {
                    // 测试要走"装了包 → 在精听台练起来"这条真实路。
                    // **必须在 look(Demo.word) 之前、return 之前** ——
                    // 第一版我把它写在 return 后面，-demo 下根本执行不到，
                    // 等于测试钩子是死的，还以为跑的是真包。
                    if Demo.useTestPack {
                        if CatalogService.shared.packs().isEmpty,
                           let z = Bundle.main.url(forResource: "testpack", withExtension: "zip") {
                            UserDefaults.standard.set("test", forKey: "owner.key")
                            _ = try? CatalogService.shared.install(zip: z)
                        }
                        if let p = CatalogService.shared.packs().first {
                            store.loadPack(p.id, name: p.name)
                            switch Demo.screen {
                            case "drill": nav.tab = 2
                            case "train": nav.tab = 3
                            case "lib":   nav.tab = 4
                            case "dict":  nav.tab = 1
                            default:      nav.tab = 0
                            }
                            return              // 真包已经装好，别再去载演示数据把它盖掉
                        }
                    }
                    await store.look(Demo.word)
                    switch Demo.screen {
                    case "drill":  nav.tab = 2
                    case "dict":   nav.tab = 1
                    case "train":  nav.tab = 3
                    case "lib":    nav.tab = 4
                    default:       nav.tab = 0
                    }
                    return
                }
                EntitlementService.shared.markFirstRun()
                EntitlementService.shared.reload()
                Purchases.shared.start()
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
