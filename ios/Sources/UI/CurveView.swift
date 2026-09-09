import SwiftUI

/// 语调 · 节奏对比图：蓝＝原声，橙＝你念的（按 DTW 对齐到同一条时间轴）。
/// 看两条线的"走势"像不像 —— 重音落在哪儿、句尾是升还是降，一眼就知道。
struct CurveView: View {
    var nat: [Double]
    var mine: [Double?]
    var rms: [Double]

    var body: some View {
        Canvas { ctx, size in
            let n = nat.count
            guard n > 1 else { return }
            let pad: CGFloat = 6
            let w = size.width - pad * 2, h = size.height - pad * 2
            let vals = nat.filter { !$0.isNaN } + mine.compactMap { $0 }
            let lo = min(-7, (vals.min() ?? -7) - 1), hi = max(7, (vals.max() ?? 7) + 1)
            func X(_ i: Int) -> CGFloat { pad + w * CGFloat(i) / CGFloat(max(1, n - 1)) }
            func Y(_ v: Double) -> CGFloat { pad + h * CGFloat(1 - (v - lo) / (hi - lo)) }

            // 原声的音量柱，当背景参照
            var bars = Path()
            for i in 0..<n {
                let bh = CGFloat(rms.indices.contains(i) ? rms[i] : 0) * h * 0.30
                bars.addRect(CGRect(x: X(i), y: pad + h - bh, width: max(1, w / CGFloat(n)), height: bh))
            }
            ctx.fill(bars, with: .color(.secondary.opacity(0.18)))

            func line(_ get: (Int) -> Double?, _ color: Color) {
                var p = Path()
                var on = false, prev = 0.0
                for i in 0..<n {
                    guard let v = get(i), !v.isNaN else { on = false; continue }
                    let pt = CGPoint(x: X(i), y: Y(v))
                    if !on || abs(v - prev) > 8 { p.move(to: pt); on = true } else { p.addLine(to: pt) }
                    prev = v
                }
                ctx.stroke(p, with: .color(color), style: .init(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }
            line({ nat[$0] }, .blue)
            line({ mine[$0] }, .orange)
        }
    }
}
