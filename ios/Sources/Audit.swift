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
    static var on: Bool { Demo.on && ProcessInfo.processInfo.arguments.contains("-audit") }
    private static var lastReport = ""

    static func check(_ blocks: [BlockFrame], screen: CGSize) {
        guard on, blocks.count > 1 else { return }
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
    }
}
