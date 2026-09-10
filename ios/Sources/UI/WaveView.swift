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
    /// 算好的包络存着 —— 拖选区时视窗根本没变，包络是同一份，
    /// 每帧重算 24 万次采样纯属白干（真机上就卡在这儿）。只有换句、缩放、改宽度才重算。
    private var envCache: [(Float, Float)] = []
    private var envKey: (Int, Double, Double, Int) = (0, .nan, .nan, 0)
    private var envStamp = 0                     // 换了句子就 +1，缓存作废
    private func envelopeCached(_ n: Int) -> [(Float, Float)] {
        let key = (n, view0, view1, envStamp)
        if key == envKey, envCache.count == n { return envCache }
        envCache = onNeedEnvelope?(n, view0, view1) ?? envelope
        envKey = key
        return envCache
    }
    /// 自己的录音那条轨同理
    private var meCache: [(Float, Float)] = []
    private var meKey: (Int, Double, Double, Int) = (0, .nan, .nan, 0)
    var onSelectionChanged: ((Double?, Double?, Bool) -> Void)?   // a, b, 是否要立刻播
    var onHeadChanged: ((Double) -> Void)?
    var onViewChanged: ((Double, Double) -> Void)?

    private enum Mode { case none, pan, edgeA, edgeB, newSel }
    private var mode: Mode = .none
    private var startX: CGFloat = 0
    private var startView: (Double, Double) = (0, 1)
    private var anchorT: Double = 0
    private var moved = false
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
        // 单指按下就准备画选区，不用等 180 毫秒 ——
        // 等待期是"划不动、要等好久"的一半原因，PC 上鼠标按下就开始划，这里也一样。
        // 平移让给双指拖（缩放本来就是双指，一套手势不打架）。
        mode = .pan
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let p = touches.first?.location(in: self), event?.allTouches?.count == 1 else { return }
        let raw = min(max(t(p.x), 0), duration)
        switch mode {
        case .pan:
            // 手指一动就是在画选区（超过 4 点算"动了"，避免点一下被当成画）
            guard abs(p.x - startX) > 4 else { return }
            moved = true
            mode = .newSel
            let s0 = snap(anchorT)
            selA = s0; selB = s0
            haptic.impactOccurred()
            let s = snap(raw)
            selA = min(anchorT, s); selB = max(anchorT, s)
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
        // 第二根手指落下时会走到这里（单指那套被取消）。把选区记住，
        // 免得"本来圈好的选区，一捏缩放就没了"。
        pinchSelA = selA; pinchSelB = selB
        mode = .none; setNeedsDisplay()
    }

    /// 双指：捏＝缩放，拖＝平移。
    /// 单指现在专门用来画选区（那是这块最常做的事），平移就归到双指这儿来。
    @objc private func onPinch(_ g: UIPinchGestureRecognizer) {
        guard g.numberOfTouches >= 2 else { return }
        let p = g.location(in: self)
        if g.state == .began {
            mode = .none                      // 双指一落下就取消单指那套，别串
            selA = pinchSelA; selB = pinchSelB
            startView = (view0, view1)
            pinchStartX = p.x
        }
        let anchor = t(p.x)
        let w = min(max((startView.1 - startView.0) / Double(g.scale), 0.05), duration)
        let frac = Double(p.x / max(1, bounds.width))
        var v0 = anchor - w * frac
        let dx = Double((p.x - pinchStartX) / max(1, bounds.width)) * w   // 双指整体挪了多少
        v0 -= dx
        view0 = min(max(v0, 0), max(0, duration - w))
        view1 = view0 + w
        onViewChanged?(view0, view1)
        setNeedsDisplay()
    }
    private var pinchStartX: CGFloat = 0
    private var pinchSelA: Double?, pinchSelB: Double?

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
                // 画词。**宽度不够不能就不画** —— 原来是 `if b - a > 字宽+6` 才画，
                // 于是短词（the / went 这些）整片是空白，真机截图上前半句一个字都没有，
                // 只剩一排竖线，看着像没加载出来。
                // 改成：先缩字号，还放不下就截断成"首字母＋点"，总之每个词都留个记号。
                let wide = min(W, b) - max(0, a)
                let bold: UIFont.Weight = (inSel || isNow) ? .semibold : .regular
                let ink = (inSel || isNow) ? C.chipSelInk : C.chipInk
                var drawn: NSAttributedString?
                for size in [10.5, 9.0, 8.0] as [CGFloat] {
                    let t = NSAttributedString(string: w.w, attributes: [
                        .font: UIFont.systemFont(ofSize: size, weight: bold),
                        .foregroundColor: ink])
                    if t.size().width + 3 <= wide { drawn = t; break }
                }
                if drawn == nil, let first = w.w.first {
                    // 实在放不下：只画首字母，至少知道这儿有个词
                    let t = NSAttributedString(string: String(first), attributes: [
                        .font: UIFont.systemFont(ofSize: 8, weight: bold),
                        .foregroundColor: ink])
                    if t.size().width + 1 <= wide { drawn = t }
                }
                if let t = drawn {
                    let sz = t.size()
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
        let env = envelopeCached(n)
        let mid = laneTop + laneH / 2
        // 攒成两批一次画完（选区内一批、选区外一批）。
        // 原来是一根竖线一次 ctx.fill，800 根就是 800 次绘制调用，
        // 拖动时每秒 4.8 万次 —— 真机直接卡住（他反馈"划不动、要等好久"）。
        var outside: [CGRect] = [], inside: [CGRect] = []
        outside.reserveCapacity(n); inside.reserveCapacity(64)
        let selX0 = hasSel ? x(selA!) : 0, selX1 = hasSel ? x(selB!) : 0
        for i in 0..<min(n, env.count) {
            let (lo, hi) = env[i]
            let y1 = mid - CGFloat(hi) * (laneH / 2 - 4)
            let y2 = mid - CGFloat(lo) * (laneH / 2 - 4)
            let r = CGRect(x: CGFloat(i), y: y1, width: 1, height: max(1, y2 - y1))
            if hasSel && CGFloat(i) >= selX0 && CGFloat(i) < selX1 { inside.append(r) }
            else { outside.append(r) }
        }
        if !outside.isEmpty { ctx.setFillColor(C.wave.cgColor); ctx.fill(outside) }
        if !inside.isEmpty { ctx.setFillColor(C.selWave.cgColor); ctx.fill(inside) }

        // 我的录音：跟原声共用一条秒数轴，念得慢尾巴就伸出去，一眼看得见
        if hasMe {
            ctx.setFillColor(C.bgMe.cgColor)
            ctx.fill(CGRect(x: 0, y: meTop, width: W, height: meH))
            ctx.setStrokeColor(C.rulerTick.cgColor); ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: 0, y: meTop + 0.5)); ctx.addLine(to: CGPoint(x: W, y: meTop + 0.5))
            ctx.strokePath()
            let mid = meTop + meH / 2
            let sr = 16000.0
            let mkey = (Int(W), view0, view1, mePcm.count)
            if mkey != meKey || meCache.count != Int(W) {          // 同样只在视窗变了才重算
                var c: [(Float, Float)] = []; c.reserveCapacity(Int(W))
                for px in 0..<Int(W) {
                    let t0 = t(CGFloat(px)) - meStart, t1 = t(CGFloat(px + 1)) - meStart
                    var i0 = Int(t0 * sr), i1 = Int(t1 * sr)
                    if i1 <= 0 || i0 >= mePcm.count { c.append((0, 0)); continue }
                    i0 = max(0, i0); i1 = min(mePcm.count, max(i0 + 1, i1))
                    var lo: Float = 0, hi: Float = 0
                    var i = i0
                    let step = max(1, (i1 - i0) / 200)
                    while i < i1 { let v = mePcm[i]; if v < lo { lo = v }; if v > hi { hi = v }; i += step }
                    c.append((lo, hi))
                }
                meCache = c; meKey = mkey
            }
            var meRects: [CGRect] = []; meRects.reserveCapacity(Int(W))
            for px in 0..<min(Int(W), meCache.count) {
                let (lo, hi) = meCache[px]
                if lo == 0 && hi == 0 { continue }
                let y1 = mid - CGFloat(hi) * (meH / 2 - 3), y2 = mid - CGFloat(lo) * (meH / 2 - 3)
                meRects.append(CGRect(x: CGFloat(px), y: y1, width: 1, height: max(1, y2 - y1)))
            }
            if !meRects.isEmpty { ctx.setFillColor(C.waveMe.cgColor); ctx.fill(meRects) }
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
            // 居中画会让最左最右那个数字被卡片边缘切掉半截（"0s" 看着像 ")s"）。
            // 但硬钳到边上又会跟自己那根刻度线错开半个字，读数会指错 ——
            // 所以放不下时改成**贴着刻度线**画（左边贴右、右边贴左），
            // 数字和它的刻度线始终挨着，不会张冠李戴。
            let lw = s.size().width
            var lx = xx - lw / 2
            if lx < 2 { lx = xx + 3 }
            if lx + lw > W - 2 { lx = xx - lw - 3 }
            lx = min(max(lx, 2), max(2, W - lw - 2))
            s.draw(at: CGPoint(x: lx, y: laneBot + 5))
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
