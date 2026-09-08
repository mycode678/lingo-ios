import UIKit
import SwiftUI

/// 波形。精听的主战场，所以是自己画、自己收手势的 UIView，不是 SwiftUI Canvas ——
/// 手势要的是"一根手指按下去的瞬间就知道它想干什么"，UIKit 的 touches 才给得了这种控制。
///
/// 手势（照复读机类 App 的习惯）：
///   单指拖 ＝ 整体平移（放大之后最常用）
///   双指捏 ＝ 缩放
///   点一下 ＝ 把最近的那条选区边界挪到这儿（没有选区时是挪播放头）
///   长按后拖 ＝ 从这儿画一个新选区
///   拖两端的大手柄 ＝ 改边界，自动吸到词边和停顿上
final class WaveUIView: UIView {

    // 数据
    var envelope: [(Float, Float)] = []          // 由 Player 按当前视窗算好
    var duration: Double = 1
    var view0: Double = 0                        // 视窗左边界（秒）
    var view1: Double = 1
    var selA: Double?
    var selB: Double?
    var head: Double = 0
    var words: [Api.Word] = []
    var marks: [Api.Mark] = []
    var snapEnabled = true
    /// 我的录音（16k），有就在原声下面画一条，起点对齐选区开头
    var mePcm: [Float] = []
    var meStart: Double = 0

    // 回调
    var onNeedEnvelope: ((Int, Double, Double) -> [(Float, Float)])?
    var onSelectionChanged: ((Double?, Double?, Bool) -> Void)?   // a, b, 是否要立刻播
    var onHeadChanged: ((Double) -> Void)?
    var onViewChanged: ((Double, Double) -> Void)?

    private enum Mode { case none, pan, edgeA, edgeB, newSel }
    private var mode: Mode = .none
    private var startX: CGFloat = 0
    private var startView: (Double, Double) = (0, 1)
    private var anchorT: Double = 0
    private var moved = false
    private var longPress: DispatchWorkItem?
    private let haptic = UIImpactFeedbackGenerator(style: .light)

    private let ROW: CGFloat = 22                // 词条那一行
    private let RULER: CGFloat = 20
    private let GRAB: CGFloat = 30               // 手柄触摸半径

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(onPinch(_:)))
        addGestureRecognizer(pinch)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - 坐标换算
    private var span: Double { max(0.01, view1 - view0) }
    private func x(_ t: Double) -> CGFloat { CGFloat((t - view0) / span) * bounds.width }
    private func t(_ x: CGFloat) -> Double { view0 + Double(x / max(1, bounds.width)) * span }
    private func snap(_ time: Double) -> Double {
        guard snapEnabled, !words.isEmpty else { return time }
        let tol = max(0.02, span / Double(max(1, bounds.width)) * 10)
        var best = time, bd = tol
        for w in words {
            for e in [w.s, w.e] where abs(e - time) < bd { bd = abs(e - time); best = e }
        }
        return best
    }
    private var hasSel: Bool { selA != nil && selB != nil && (selB! - selA!) > 0.02 }

    // MARK: - 触摸
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let p = touches.first?.location(in: self), event?.allTouches?.count == 1 else { return }
        startX = p.x
        startView = (view0, view1)
        anchorT = min(max(t(p.x), 0), duration)
        moved = false
        if hasSel {
            if abs(p.x - x(selA!)) < GRAB { mode = .edgeA; haptic.impactOccurred(); return }
            if abs(p.x - x(selB!)) < GRAB { mode = .edgeB; haptic.impactOccurred(); return }
        }
        mode = .pan
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.mode == .pan, !self.moved else { return }
            self.mode = .newSel
            let s = self.snap(self.anchorT)
            self.selA = s; self.selB = s
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            self.setNeedsDisplay()
        }
        longPress = work
        // 180ms：比系统长按短一半。再短容易跟"拖着平移"打架，再长手指会等得难受。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let p = touches.first?.location(in: self), event?.allTouches?.count == 1 else { return }
        let raw = min(max(t(p.x), 0), duration)
        switch mode {
        case .pan:
            if abs(p.x - startX) > 5 { moved = true; longPress?.cancel() }
            let dt = Double((p.x - startX) / max(1, bounds.width)) * (startView.1 - startView.0)
            let w = startView.1 - startView.0
            view0 = min(max(startView.0 - dt, 0), max(0, duration - w))
            view1 = view0 + w
            onViewChanged?(view0, view1)
        case .newSel:
            let s = snap(raw)
            selA = min(anchorT, s); selB = max(anchorT, s)
        case .edgeA:
            selA = min(snap(raw), (selB ?? duration) - 0.03)
        case .edgeB:
            selB = max(snap(raw), (selA ?? 0) + 0.03)
        case .none: break
        }
        setNeedsDisplay()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        longPress?.cancel()
        defer { mode = .none; setNeedsDisplay() }
        switch mode {
        case .pan:
            if moved { return }
            if hasSel {                                  // 点一下：最近那条边过来
                let s = snap(anchorT)
                if abs(s - selA!) <= abs(s - selB!) { selA = min(s, selB! - 0.03) }
                else { selB = max(s, selA! + 0.03) }
                head = selA!
                haptic.impactOccurred()
                onSelectionChanged?(selA, selB, true)
            } else {
                head = anchorT
                onHeadChanged?(head)
            }
        case .newSel, .edgeA, .edgeB:
            if let a = selA, let b = selB, b - a > 0.02 {
                head = a
                onSelectionChanged?(a, b, true)
            } else {
                selA = nil; selB = nil
                onSelectionChanged?(nil, nil, false)
            }
        case .none: break
        }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        longPress?.cancel(); mode = .none; setNeedsDisplay()
    }

    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        guard g.numberOfTouches >= 2 else { return }
        if g.state == .began { longPress?.cancel(); mode = .none; startView = (view0, view1) }
        let p = g.location(in: self)
        let anchor = t(p.x)
        let w = min(max((startView.1 - startView.0) / Double(g.scale), 0.05), duration)
        let frac = Double(p.x / max(1, bounds.width))
        view0 = min(max(anchor - w * frac, 0), max(0, duration - w))
        view1 = view0 + w
        onViewChanged?(view0, view1)
        setNeedsDisplay()
    }

    // MARK: - 画
    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), bounds.width > 1 else { return }
        let dark = traitCollection.userInterfaceStyle == .dark
        let C = dark ? Palette.night : Palette.day
        let W = bounds.width
        let rowH: CGFloat = words.isEmpty ? 0 : ROW
        let laneTop = rowH
        let laneBot = bounds.height - RULER
        let hasMe = mePcm.count > 800
        let laneH = (laneBot - laneTop) * (hasMe ? 0.62 : 1)
        let meTop = laneTop + laneH
        let meH = laneBot - meTop

        // 词条行：底色跟波形一致，只有"正在播的词"和"选区里的词"才上色 ——
        // 每个词都涂一块的话，词一多就是一排脏色块（截图里看着很糙）
        if !words.isEmpty {
            ctx.setFillColor(C.bg.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: rowH))
            for (i, w) in words.enumerated() {
                let a = x(w.s), b = x(w.e)
                if b < 0 || a > W { continue }
                let inSel = hasSel && w.s >= selA! - 0.005 && w.e <= selB! + 0.005
                let isNow = head >= w.s - 0.005 && head < w.e + 0.005
                if inSel || isNow {
                    ctx.setFillColor((isNow ? C.markLine.withAlphaComponent(0.85)
                                            : C.chipSel).cgColor)
                    ctx.fill(CGRect(x: max(0, a), y: 1, width: min(W, b) - max(0, a) - 1,
                                    height: rowH - 4))
                }
                // 词与词之间一条极淡的分隔线，够看出边界就行
                ctx.setStrokeColor(C.rulerTick.cgColor); ctx.setLineWidth(1)
                ctx.move(to: CGPoint(x: a + 0.5, y: 2)); ctx.addLine(to: CGPoint(x: a + 0.5, y: laneBot))
                ctx.strokePath()
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.systemFont(ofSize: 10.5, weight: (inSel || isNow) ? .semibold : .regular),
                    .foregroundColor: (inSel || isNow) ? C.chipSelInk : C.chipInk]
                let t = NSAttributedString(string: w.w, attributes: attrs)
                let sz = t.size()
                if b - a > sz.width + 6 {
                    t.draw(at: CGPoint(x: (max(0, a) + min(W, b)) / 2 - sz.width / 2, y: 3))
                }
            }
        }

        // 波形
        ctx.setFillColor(C.bg.cgColor)
        ctx.fill(CGRect(x: 0, y: laneTop, width: W, height: laneH))
        if hasSel {
            ctx.setFillColor(C.selBg.cgColor)
            ctx.fill(CGRect(x: x(selA!), y: laneTop, width: x(selB!) - x(selA!), height: laneH))
        }
        let n = Int(W)
        let env = onNeedEnvelope?(n, view0, view1) ?? envelope
        let mid = laneTop + laneH / 2
        for i in 0..<min(n, env.count) {
            let (lo, hi) = env[i]
            let inSel = hasSel && Double(i) >= Double(x(selA!)) && Double(i) < Double(x(selB!))
            ctx.setFillColor((inSel ? C.selWave : C.wave).cgColor)
            let y1 = mid - CGFloat(hi) * (laneH / 2 - 4)
            let y2 = mid - CGFloat(lo) * (laneH / 2 - 4)
            ctx.fill(CGRect(x: CGFloat(i), y: y1, width: 1, height: max(1, y2 - y1)))
        }

        // 我的录音：跟原声共用一条秒数轴，念得慢尾巴就伸出去，一眼看得见
        if hasMe {
            ctx.setFillColor(C.bgMe.cgColor)
            ctx.fill(CGRect(x: 0, y: meTop, width: W, height: meH))
            ctx.setStrokeColor(C.rulerTick.cgColor); ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: 0, y: meTop + 0.5)); ctx.addLine(to: CGPoint(x: W, y: meTop + 0.5))
            ctx.strokePath()
            let mid = meTop + meH / 2
            let sr = 16000.0
            ctx.setFillColor(C.waveMe.cgColor)
            for px in 0..<Int(W) {
                let t0 = t(CGFloat(px)) - meStart, t1 = t(CGFloat(px + 1)) - meStart
                var i0 = Int(t0 * sr), i1 = Int(t1 * sr)
                if i1 <= 0 || i0 >= mePcm.count { continue }
                i0 = max(0, i0); i1 = min(mePcm.count, max(i0 + 1, i1))
                var lo: Float = 0, hi: Float = 0
                var i = i0
                let step = max(1, (i1 - i0) / 200)
                while i < i1 { let v = mePcm[i]; if v < lo { lo = v }; if v > hi { hi = v }; i += step }
                let y1 = mid - CGFloat(hi) * (meH / 2 - 3), y2 = mid - CGFloat(lo) * (meH / 2 - 3)
                ctx.fill(CGRect(x: CGFloat(px), y: y1, width: 1, height: max(1, y2 - y1)))
            }
            let lab = NSAttributedString(string: "我的", attributes: [
                .font: UIFont.systemFont(ofSize: 9), .foregroundColor: C.rulerInk])
            lab.draw(at: CGPoint(x: 4, y: meTop + 3))
        }

        // 难点
        for m in marks {
            let a = x(m.s), b = x(m.e)
            ctx.setFillColor(C.mark.cgColor)
            ctx.fill(CGRect(x: a, y: laneTop, width: max(2, b - a), height: laneH))
            ctx.setFillColor(C.markLine.cgColor)
            ctx.fill(CGRect(x: a, y: laneTop, width: max(2, b - a), height: 3))
        }

        // 选区两端的大手柄
        if hasSel {
            ctx.setStrokeColor(C.edge.cgColor); ctx.setLineWidth(2.5)
            for xx in [x(selA!), x(selB!)] {
                ctx.move(to: CGPoint(x: xx, y: laneTop)); ctx.addLine(to: CGPoint(x: xx, y: laneBot))
            }
            ctx.strokePath()
            ctx.setFillColor(C.edge.cgColor)
            for xx in [x(selA!), x(selB!)] {
                for cy in [laneTop + 11, laneBot - 11] {
                    ctx.fillEllipse(in: CGRect(x: xx - 11, y: cy - 11, width: 22, height: 22))
                }
            }
            ctx.setStrokeColor(UIColor.white.cgColor); ctx.setLineWidth(1.6)
            for xx in [x(selA!), x(selB!)] {
                for cy in [laneTop + 11, laneBot - 11] {
                    ctx.move(to: CGPoint(x: xx - 3, y: cy - 4)); ctx.addLine(to: CGPoint(x: xx - 3, y: cy + 4))
                    ctx.move(to: CGPoint(x: xx + 3, y: cy - 4)); ctx.addLine(to: CGPoint(x: xx + 3, y: cy + 4))
                }
            }
            ctx.strokePath()
        }

        // 时间尺
        ctx.setFillColor(C.ruler.cgColor)
        ctx.fill(CGRect(x: 0, y: laneBot, width: W, height: RULER))
        let steps: [Double] = [0.05, 0.1, 0.2, 0.5, 1, 2, 5]
        let step = steps.first { span / $0 <= 10 } ?? 10
        var tt = (view0 / step).rounded(.up) * step
        while tt <= view1 {
            let xx = x(tt)
            ctx.setStrokeColor(C.rulerTick.cgColor); ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: xx, y: laneBot)); ctx.addLine(to: CGPoint(x: xx, y: laneBot + 4))
            ctx.strokePath()
            let s = NSAttributedString(string: String(format: step < 1 ? "%.1fs" : "%.0fs", tt),
                attributes: [.font: UIFont.systemFont(ofSize: 10), .foregroundColor: C.rulerInk])
            s.draw(at: CGPoint(x: xx - s.size().width / 2, y: laneBot + 5))
            tt += step
        }

        // 播放头
        let hx = x(head)
        if hx >= -2 && hx <= W + 2 {
            ctx.setStrokeColor(C.markLine.cgColor); ctx.setLineWidth(2)
            ctx.move(to: CGPoint(x: hx, y: laneTop)); ctx.addLine(to: CGPoint(x: hx, y: laneBot))
            ctx.strokePath()
            ctx.setFillColor(C.markLine.cgColor)
            ctx.move(to: CGPoint(x: hx - 5, y: laneTop))
            ctx.addLine(to: CGPoint(x: hx + 5, y: laneTop))
            ctx.addLine(to: CGPoint(x: hx, y: laneTop + 7))
            ctx.fillPath()
        }
    }

    struct Palette {
        var bg: UIColor; var wave: UIColor; var selBg: UIColor; var selWave: UIColor
        var bgMe: UIColor; var waveMe: UIColor
        var mark: UIColor; var markLine: UIColor; var rowBg: UIColor
        var chip: [UIColor]; var chipInk: UIColor; var chipSel: UIColor; var chipSelInk: UIColor
        var edge: UIColor; var ruler: UIColor; var rulerTick: UIColor; var rulerInk: UIColor

        // 配色照 Transcribe! 那套琥珀色，白天夜间各一份
        static let day = Palette(
            bg: UIColor(hex: 0xf6d093), wave: UIColor(hex: 0x7a5510),
            selBg: UIColor(hex: 0x173a86), selWave: UIColor(hex: 0x9cc4f2),
            bgMe: UIColor(hex: 0xfbe6c4), waveMe: UIColor(hex: 0xa35c12),
            mark: UIColor(hex: 0xd5433d, a: 0.14), markLine: UIColor(hex: 0xd5433d),
            rowBg: UIColor(hex: 0xefe2cb), chip: [UIColor(hex: 0xe8dcc4), UIColor(hex: 0xdfd0b2)],
            chipInk: UIColor(hex: 0x6b5230), chipSel: UIColor(hex: 0x173a86),
            chipSelInk: UIColor(hex: 0xdceaff), edge: UIColor(hex: 0x0e2a63),
            ruler: UIColor(hex: 0xfaf6ee), rulerTick: UIColor(hex: 0xded2bb), rulerInk: UIColor(hex: 0x9a8a70))
        static let night = Palette(
            bg: UIColor(hex: 0x3a3021), wave: UIColor(hex: 0xe0aa4e),
            selBg: UIColor(hex: 0x1b3f7f), selWave: UIColor(hex: 0xa9cbf5),
            bgMe: UIColor(hex: 0x33291c), waveMe: UIColor(hex: 0xcf7f2c),
            mark: UIColor(hex: 0xef6a63, a: 0.18), markLine: UIColor(hex: 0xef6a63),
            rowBg: UIColor(hex: 0x2b2519), chip: [UIColor(hex: 0x3b3223), UIColor(hex: 0x453b29)],
            chipInk: UIColor(hex: 0xc3b191), chipSel: UIColor(hex: 0x1b3f7f),
            chipSelInk: UIColor(hex: 0xcfe2ff), edge: UIColor(hex: 0x7fb0f0),
            ruler: UIColor(hex: 0x20252b), rulerTick: UIColor(hex: 0x3a444f), rulerInk: UIColor(hex: 0x8b9aab))
    }
}

extension UIColor {
    convenience init(hex: Int, a: CGFloat = 1) {
        self.init(red: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255, alpha: a)
    }
}

/// 包给 SwiftUI 用
struct WaveView: UIViewRepresentable {
    @ObservedObject var vm: DrillModel
    @ObservedObject var rec = Recorder.shared
    /// 必须自己盯住播放器：只有它的 position 变化触发重绘，波形上的红色播放头才会跟着走。
    /// 上一版把界面上显示时间的那行去掉后，没人再"读"这个值，SwiftUI 就不重绘了，
    /// 于是红条不动 —— 这种依赖是隐式的，最容易踩。
    @ObservedObject var player = Player.shared

    func makeUIView(context: Context) -> WaveUIView {
        // 给 UI 测试一个抓手：波形是自绘的 UIView，没名字就没法在测试里对它长按拖动
        let v = WaveUIView()
        v.onNeedEnvelope = { n, a, b in Player.shared.envelope(width: n, from: a, to: b) }
        v.onSelectionChanged = { a, b, play in
            vm.setSelection(a: a, b: b, play: play)
        }
        v.onHeadChanged = { t in Player.shared.seek(to: t) }
        v.onViewChanged = { a, b in vm.view = (a, b) }
        v.isAccessibilityElement = true
        v.accessibilityIdentifier = "waveform"
        v.accessibilityTraits = .allowsDirectInteraction   // 让测试的长按拖动直接落到这块上
        return v
    }

    func updateUIView(_ v: WaveUIView, context: Context) {
        v.duration = player.duration
        v.view0 = vm.view.0; v.view1 = vm.view.1
        v.selA = vm.selection?.lowerBound; v.selB = vm.selection?.upperBound
        v.head = player.position
        v.words = vm.words
        v.marks = vm.marks
        v.snapEnabled = vm.snap
        v.mePcm = Recorder.shared.takePCM
        v.meStart = vm.selection?.lowerBound ?? 0
        v.setNeedsDisplay()
    }
}
