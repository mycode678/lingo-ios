import Foundation
import AVFoundation
import Combine

/// 播放引擎。用 AVAudioEngine 而不是 AVPlayer，因为精听要的三件事它才做得到：
///   1. 变速不变调 —— AVAudioUnitTimePitch 只改速度、音高不动（0.5 倍速听清连读）
///   2. A-B 精确循环 —— 直接按采样点截取，误差在毫秒级，不靠 timeupdate 轮询
///   3. 零延迟起播 —— 音频已经解码在内存里，点一下立刻响，反复听不卡顿
/// 锁屏继续放音靠 AVAudioSession 的 .playback 类别 + UIBackgroundModes: audio。
@MainActor
final class Player: ObservableObject {
    static let shared = Player()

    // 对外状态
    @Published private(set) var isPlaying = false
    @Published private(set) var position: Double = 0      // 当前播放到第几秒（原始时间轴）
    @Published private(set) var duration: Double = 0
    @Published var rate: Float = 1.0 { didSet { pitch.rate = max(0.35, min(2, rate)) } }
    @Published var loop = false                            // 循环当前这一段
    /// 循环几遍就停；0 = 一直循环。PC 版精练台有"每句 N 遍"，这里照搬。
    @Published var loopTimes = 0
    private var played = 0
    @Published var gapIn: Double = 0.8                     // 同一段两遍之间停多久
    @Published var gapOut: Double = 1.2                    // 换下一句之前停多久
    @Published var segment: ClosedRange<Double>?           // 只播这一段（精听）

    /// 听辅音：把 2.5kHz 以上抬 10dB，句尾的 t/s/k 会清楚很多
    @Published var boostHF = false { didSet { eq.bands[0].bypass = !boostHF } }

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let pitch = AVAudioUnitTimePitch()
    private let eq = AVAudioUnitEQ(numberOfBands: 1)
    private var buffer: AVAudioPCMBuffer?
    /// 统一的内部格式。词典音频有 22k 单声道也有 44.1k 立体声，
    /// 而 AVAudioPlayerNode 要求"喂进去的 buffer 格式必须跟连线时的格式一致"，
    /// 否则直接崩（第一版就是这么崩的）。所以载入时一律转成这个格式，连线只连一次。
    private let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    private var sampleRate: Double { fmt.sampleRate }
    private var startHostTime: Double = 0
    private var startOffset: Double = 0
    private var ticker: Timer?
    private var gen = 0
    /// 一段放完之后干什么（连播时由 Walk 负责接管）
    var onSegmentEnd: (() -> Void)?

    private init() {
        engine.attach(node)
        engine.attach(pitch)
        engine.attach(eq)
        let b = eq.bands[0]
        b.filterType = .highShelf; b.frequency = 2500; b.gain = 10; b.bypass = true
        engine.connect(node, to: pitch, format: fmt)
        engine.connect(pitch, to: eq, format: fmt)
        engine.connect(eq, to: engine.mainMixerNode, format: fmt)
        pitch.overlap = 8                                  // 慢放时的相位重叠，越大越平滑
        configureSession()
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] n in
                guard let self else { return }
                let t = (n.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
                if t == AVAudioSession.InterruptionType.began.rawValue { Task { @MainActor in self.pause() } }
            }
    }

    private func configureSession() {
        let s = AVAudioSession.sharedInstance()
        // .playback：静音键拨到静音也照样出声，锁屏继续放 —— 走路练习必须这样
        try? s.setCategory(.playback, mode: .spokenAudio, options: [.allowBluetoothA2DP, .allowAirPlay])
        try? s.setActive(true)
    }

    // MARK: - 装载

    /// 把一条音频读进内存。src 是服务器上的路径（/res/exa/...），先看本地缓存。
    func load(src: String) async throws {
        if Demo.on {                       // 云端模拟器里没有服务器，用合成的波形
            // 注意别把 "mp3" 里的 3 也算进来（第一版就是这么把第 1 句放成了第 3 句）
            let idx = Int(src.split(separator: "/").last?.split(separator: ".").first ?? "1") ?? 1
            let pcm = Demo.pcm(idx - 1, sampleRate: fmt.sampleRate)
            guard let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(pcm.count)),
                  let ch = b.floatChannelData else { return }
            b.frameLength = AVAudioFrameCount(pcm.count)
            for i in 0..<pcm.count { ch[0][i] = pcm[i] }
            buffer = b
            duration = Double(pcm.count) / sampleRate
            position = 0; segment = nil
            if !engine.isRunning { engine.prepare(); try? engine.start() }
            return
        }
        let url = try await Cache.shared.localURL(for: src)
        let f = try AVAudioFile(forReading: url)
        let src = f.processingFormat
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(f.length)) else {
            throw NSError(domain: "player", code: 1, userInfo: [NSLocalizedDescriptionKey: "分配缓冲失败"])
        }
        try f.read(into: inBuf)

        // 统一转成 44.1k 单声道浮点
        let buf: AVAudioPCMBuffer
        if src == fmt {
            buf = inBuf
        } else {
            guard let conv = AVAudioConverter(from: src, to: fmt) else {
                throw NSError(domain: "player", code: 2, userInfo: [NSLocalizedDescriptionKey: "格式转换器建不起来"])
            }
            let cap = AVAudioFrameCount(Double(inBuf.frameLength) * fmt.sampleRate / src.sampleRate) + 1024
            guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: cap) else {
                throw NSError(domain: "player", code: 3, userInfo: [NSLocalizedDescriptionKey: "分配输出缓冲失败"])
            }
            var done = false
            var err: NSError?
            conv.convert(to: out, error: &err) { _, status in
                if done { status.pointee = .noDataNow; return nil }
                done = true; status.pointee = .haveData; return inBuf
            }
            if let err { throw err }
            buf = out
        }

        buffer = buf
        duration = Double(buf.frameLength) / sampleRate
        position = 0
        segment = nil
        if !engine.isRunning {
            engine.prepare()
            do { try engine.start() } catch {
                throw NSError(domain: "player", code: 4,
                              userInfo: [NSLocalizedDescriptionKey: "音频引擎起不来：\(error.localizedDescription)"])
            }
        }
    }

    /// 波形要画的包络：每个像素一列 min/max
    func envelope(width: Int, from: Double, to: Double) -> [(Float, Float)] {
        guard let buf = buffer, let ch = buf.floatChannelData?[0], width > 0 else { return [] }
        let n = Int(buf.frameLength)
        var out: [(Float, Float)] = []
        out.reserveCapacity(width)
        for x in 0..<width {
            var i0 = Int((from + (to - from) * Double(x) / Double(width)) * sampleRate)
            var i1 = Int((from + (to - from) * Double(x + 1) / Double(width)) * sampleRate)
            i0 = max(0, min(n, i0)); i1 = max(i0 + 1, min(n, i1))
            let step = max(1, (i1 - i0) / 300)
            var lo: Float = 0, hi: Float = 0
            var i = i0
            while i < i1 { let v = ch[i]; if v < lo { lo = v }; if v > hi { hi = v }; i += step }
            out.append((lo, hi))
        }
        return out
    }

    // MARK: - 播放

    func play(from: Double? = nil, keepCount: Bool = false) {
        if !keepCount { played = 0 }
        guard let buf = buffer else { return }
        let range = segment ?? 0...max(0.01, duration)
        var start = from ?? position
        if start < range.lowerBound - 0.001 || start >= range.upperBound - 0.02 { start = range.lowerBound }
        let a = AVAudioFramePosition(start * sampleRate)
        let b = AVAudioFramePosition(range.upperBound * sampleRate)
        let frames = AVAudioFrameCount(max(0, b - a))
        guard frames > 64 else { return }

        gen += 1
        let my = gen
        node.stop()
        // 从大 buffer 里切一段出来（拷贝一次，几毫秒的事，换来精确的边界）
        guard buf.format == fmt,
              let chIn = buf.floatChannelData,
              let seg = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames),
              let chOut = seg.floatChannelData,
              Int(a) + Int(frames) <= Int(buf.frameLength) else { return }
        seg.frameLength = frames
        for c in 0..<Int(fmt.channelCount) {
            memcpy(chOut[c], chIn[c] + Int(a), Int(frames) * MemoryLayout<Float>.size)
        }
        if !engine.isRunning { try? engine.start() }
        // 必须用 .dataPlayedBack：默认那个 completionHandler 是"数据被取走"就回调
        // （dataConsumed），对短句来说几乎是立刻，于是循环间隔像没生效、还会把声音切掉。
        node.scheduleBuffer(seg, at: nil, options: [], completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in
                guard let self, my == self.gen else { return }
                self.finished(range: range)
            }
        }
        startOffset = start
        startHostTime = CACurrentMediaTime()
        node.play()
        isPlaying = true
        startTicker()
        NowPlaying.shared.update()
    }

    private func finished(range: ClosedRange<Double>) {
        isPlaying = false
        position = range.upperBound
        stopTicker()
        played += 1
        if loop && (loopTimes == 0 || played < loopTimes) {
            let my = gen
            DispatchQueue.main.asyncAfter(deadline: .now() + gapIn) { [weak self] in
                guard let self, my == self.gen, self.loop else { return }
                self.play(from: range.lowerBound, keepCount: true)
            }
        } else {
            played = 0
            onSegmentEnd?()
        }
        NowPlaying.shared.update()
    }

    func pause() {
        gen += 1
        node.stop()
        isPlaying = false
        stopTicker()
        NowPlaying.shared.update()
    }
    func toggle() { isPlaying ? pause() : play() }
    func stop() { pause(); position = (segment?.lowerBound ?? 0) }

    /// **每个界面进来先申明自己要什么**。播放器是全局单例，循环、选区、
    /// "一段播完干什么"这些状态会从一个界面漏到另一个界面 ——
    /// 精听台开了循环，切到复习就停不下来，就是这么来的（踩过两次）。
    func claim(loop: Bool = false, times: Int = 0,
               segment seg: ClosedRange<Double>? = nil, onEnd: (() -> Void)? = nil) {
        pause()
        self.loop = loop
        self.loopTimes = times
        self.segment = seg
        self.onSegmentEnd = onEnd
        self.played = 0
    }
    func seek(to t: Double) {
        position = max(0, min(duration, t))
        if isPlaying { play(from: position) }
    }
    /// 选区变了：立刻按新选区重放（老的那一遍作废，绝不会两段叠在一起）
    func setSegment(_ r: ClosedRange<Double>?, playNow: Bool = true) {
        segment = r
        position = r?.lowerBound ?? 0
        if playNow { play(from: position) } else { pause() }
    }

    /// 给跟读打分用：取出（选区内的）原声，重采样到 16k
    func pcm16k(range: ClosedRange<Double>?) -> [Float] {
        guard let buf = buffer, let ch = buf.floatChannelData else { return [] }
        let a = Int((range?.lowerBound ?? 0) * sampleRate)
        let b = Int((range?.upperBound ?? duration) * sampleRate)
        let i0 = max(0, min(Int(buf.frameLength), a)), i1 = max(i0, min(Int(buf.frameLength), b))
        var out = [Float](repeating: 0, count: i1 - i0)
        for i in i0..<i1 { out[i - i0] = ch[0][i] }
        return Player.resample(out, from: sampleRate, to: 16000)
    }

    /// 线性插值重采样。给分析用够了 —— 音高和音量包络对这点误差不敏感。
    static func resample(_ x: [Float], from: Double, to: Double) -> [Float] {
        guard !x.isEmpty, abs(from - to) > 1 else { return x }
        let ratio = from / to
        let n = Int(Double(x.count) / ratio)
        guard n > 1 else { return x }
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let p = Double(i) * ratio
            let k = Int(p), f = Float(p - Double(k))
            out[i] = k + 1 < x.count ? x[k] * (1 - f) + x[k + 1] * f : x[min(k, x.count - 1)]
        }
        return out
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                let el = (CACurrentMediaTime() - self.startHostTime) * Double(self.rate)
                let end = (self.segment ?? 0...self.duration).upperBound
                self.position = min(end, self.startOffset + el)
            }
        }
        RunLoop.main.add(ticker!, forMode: .common)
    }
    private func stopTicker() { ticker?.invalidate(); ticker = nil }
}
