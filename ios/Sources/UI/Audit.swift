import SwiftUI

/// 布局体检（只在 -demo -audit 下工作）。
///
/// 为什么要有这东西：精听台上下有六七块，任何一块高度算多了，SwiftUI **不会**
/// 自动收缩别的块，而是让它们互相重叠 —— 屏幕上就是"译文压住控制条""选区条压住波形"。
/// 靠人眼看截图只能发现当时那一种情况（字号多大、显示几行、有没有小句），
/// 组合一多必然漏。所以让 App 自己把每块的真实坐标报出来，CI 里跑一遍组合，
/// 有重叠或者超出屏幕就 LAYOUT-FAIL，我这边先卡住，不再让用户当测试员。
struct BlockFrame: Equatable {
    var name: String
    var rect: CGRect
}

struct BlockKey: PreferenceKey {
    static var defaultValue: [BlockFrame] = []
    static func reduce(value: inout [BlockFrame], nextValue: () -> [BlockFrame]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    /// 给一块命名，体检时报它的实际位置。
    /// 坐标一定要相对"精听台这一屏"（.named("drill")）来算，不能用 .global ——
    /// 截横屏时整个界面是转了 90 度画出来的，global 坐标跟着转，报出来全是假重叠。
    func auditBlock(_ name: String) -> some View {
        background(
            GeometryReader { g in
                Color.clear.preference(key: BlockKey.self,
                                       value: [BlockFrame(name: name,
                                                          rect: g.frame(in: .named("drill")))])
            }
        )
    }
}

enum Audit {
    /// 最新一份体检结果。也挂到界面上一个看不见的元素上（见 auditProbe），
    /// 这样真机跑 UI 测试时我在测试日志里就能直接读到每块的真实坐标 ——
    /// 光看截图只能靠眼估，估不准就会像"波形没长高"这种改了等于没改的事。
    @MainActor static let report = Report()
    @MainActor final class Report: ObservableObject { @Published var text = "" }

    static var on: Bool { Demo.on && ProcessInfo.processInfo.arguments.contains("-audit") }
    private static var lastReport = ""
    private static var pending: DispatchWorkItem?

    /// 布局过程中会来很多次中间状态（屏高还是 0、坐标是负的），报它们全是噪声。
    /// 所以只记下最新一份，等 1 秒不再变化了才真正判定。
    static func check(_ blocks: [BlockFrame], screen: CGSize) {
        guard on, blocks.count > 1, screen.height > 100 else { return }
        pending?.cancel()
        let job = DispatchWorkItem { judge(blocks, screen: screen) }
        pending = job
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: job)
    }

    private static func judge(_ blocks: [BlockFrame], screen: CGSize) {
        var lines: [String] = []
        var fails: [String] = []
        for b in blocks.sorted(by: { $0.rect.minY < $1.rect.minY }) {
            lines.append(String(format: "AUDIT %@ y=%.0f..%.0f h=%.0f",
                                b.name, b.rect.minY, b.rect.maxY, b.rect.height))
            if b.rect.maxY > screen.height + 1 || b.rect.minY < -1 {
                fails.append(String(format: "LAYOUT-FAIL %@ 超出屏幕 (y=%.0f..%.0f, 屏高 %.0f)",
                                    b.name, b.rect.minY, b.rect.maxY, screen.height))
            }
        }
        for i in blocks.indices {
            for j in blocks.indices where j > i {
                let a = blocks[i], b = blocks[j]
                let overlap = min(a.rect.maxY, b.rect.maxY) - max(a.rect.minY, b.rect.minY)
                if overlap > 2 {          // 2 点以内当成描边误差
                    fails.append(String(format: "LAYOUT-FAIL %@ 和 %@ 重叠 %.0f 点",
                                        a.name, b.name, overlap))
                }
            }
        }
        let report = (lines + fails).joined(separator: "\n")
        guard report != lastReport else { return }     // 每帧都会调，只在变化时打
        lastReport = report
        print(report)
        print(fails.isEmpty ? "LAYOUT-OK" : "LAYOUT-FAIL 共 \(fails.count) 处")
        fflush(stdout)
        // fails 也得进去。原来只拼 lines，真出现重叠时测试日志里看到的
        // 只是一串正常坐标，这套体检在 CI 里等于摆设。
        let one = (lines.map { $0.replacingOccurrences(of: "AUDIT ", with: "") }
                   + fails).joined(separator: " | ")
        DispatchQueue.main.async { Audit.report.text = one }
    }
}

/// 体检结果的出口：一个 1×1 的透明点，它的辅助功能标签就是整份报告。
/// UI 测试读它，比让人去数截图上的像素靠谱。
struct AuditProbe: View {
    @ObservedObject private var r = Audit.report
    var body: some View {
        Color.clear.frame(width: 1, height: 1)
            .accessibilityIdentifier("auditReport")
            .accessibilityLabel(r.text)
    }
}

/// 断网演练的出口。`-nonet` 时挂在精听台上，UI 测试读它就知道
/// 这一段操作里到底有谁想联网、被挡了几次。
struct NetProbe: View {
    @State private var text = "0"
    var body: some View {
        Color.clear.frame(width: 1, height: 1)
            .accessibilityIdentifier("netBlocked")
            .accessibilityLabel(text)
            .task {
                // 轮询就够了：这只是测试用的探针，不值得为它上发布订阅
                while !Task.isCancelled {
                    let c = Api.blockedCalls
                    let t = "\(c.count)|" + Set(c).sorted().joined(separator: ",")
                    if t != text { text = t }
                    try? await Task.sleep(nanoseconds: 300_000_000)
                }
            }
    }
}
