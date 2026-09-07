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
    @Published var gapIn: Double = 0.8                     // 同一段两遍之间停多久
    @Published var segment: ClosedRange<Double>?           // 只播这一段（精听）

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let pitch = AVAudioUnitTimePitch()
    private var file: AVAudioFile?
    private var buffer: AVAudioPCMBuffer?
    private var sampleRate: Double = 44100
    private var startHostTime: Double = 0
    private var startOffset: Double = 0
    private var ticker: Timer?
    private var gen = 0
    /// 一段放完之后干什么（连播时由 Walk 负责接管）
    var onSegmentEnd: (() -> Void)?

    private init() {
        engine.attach(node)
        engine.attach(pitch)
        engine.connect(node, to: pitch, format: nil)
        engine.connect(pitch, to: engine.mainMixerNode, format: nil)
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
        let url = try await Cache.shared.localURL(for: src)
        let f = try AVAudioFile(forReading: url)
        let fmt = f.processingFormat
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(f.length)) else {
            throw NSError(domain: "player", code: 1)
        }
        try f.read(into: buf)
        file = f; buffer = buf
        sampleRate = fmt.sampleRate
        duration = Double(f.length) / sampleRate
        position = 0
        segment = nil
        if !engine.isRunning {
            engine.prepare()
            try? engine.start()
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

    func play(from: Double? = nil) {
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
        guard let seg = AVAudioPCMBuffer(pcmFormat: buf.format, frameCapacity: frames) else { return }
        seg.frameLength = frames
        let chIn = buf.floatChannelData!, chOut = seg.floatChannelData!
        for c in 0..<Int(buf.format.channelCount) {
            memcpy(chOut[c], chIn[c] + Int(a), Int(frames) * MemoryLayout<Float>.size)
        }
        if !engine.isRunning { try? engine.start() }
        node.scheduleBuffer(seg, at: nil, options: []) { [weak self] in
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
        if loop {
            let my = gen
            DispatchQueue.main.asyncAfter(deadline: .now() + gapIn) { [weak self] in
                guard let self, my == self.gen, self.loop else { return }
                self.play(from: range.lowerBound)
            }
        } else {
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
