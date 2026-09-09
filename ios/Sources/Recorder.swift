import Foundation
import AVFoundation
import SwiftUI

/// 跟读：录音 → 机器听写逐词比对 → 语调/节奏相似度 → 存到服务器。
/// 打分算法跟电脑版是同一套（音量+音高特征、DTW 对齐、相关系数），这里用 Swift 重写。
@MainActor
final class Recorder: NSObject, ObservableObject {
    static let shared = Recorder()

    struct Score { var words: Int?; var tone: Int; var rhythm: Int
                   var overall: Int { (( words ?? ((tone + rhythm) / 2) ) + tone + rhythm) / 3 } }

    @Published private(set) var isRecording = false
    @Published private(set) var hasTake = false
    @Published private(set) var heard: String?
    @Published private(set) var heardAttributed = AttributedString("")
    @Published private(set) var wrongWords: [String] = []
    @Published private(set) var score: Score?
    @Published private(set) var message: String?
    /// 语调曲线：原声和你的，按 DTW 对齐到同一条时间轴上（单位是半音，相对各自的中位数）
    @Published private(set) var curve: (nat: [Double], mine: [Double?], rms: [Double])?
    /// 刚录的那一条（16k 单声道），画在波形下面跟原声对齐着看
    @Published private(set) var takePCM: [Float] = []
    /// 逐词比对的结果（哪个词不准、重音在哪、该连读的连没连、一句话诊断）。
    /// 手机上现算，不联网。
    @Published private(set) var diff: Compare?

    /// 只给截图用：假装刚录完一条，好把"跟读结果"那块渲染出来自查。
    /// 真机上永远走不到（Demo.on 只有 -demo 启动才是 true）。
    func demoTake() {
        guard Demo.on else { return }
        heard = "Excuse me can you tell me the way to the museum please"
        heardAttributed = AttributedString(heard!)
        wrongWords = ["museum"]
        score = Score(words: 88, tone: 76, rhythm: 81)
        message = "听写来自本机识别，只作参考"
        // 1.5 秒的假波形，好看"我的录音"那条轨。
        // 写成一行 map 会让 Swift 类型检查器超时（编译报 unable to type-check），拆开写。
        var pcm = [Float](); pcm.reserveCapacity(24000)
        for i in 0..<24000 {
            let carrier: Double = sin(Double(i) / 40.0)
            let envelope: Double = abs(sin(Double(i) / 3000.0))
            pcm.append(Float(carrier * 0.35 * envelope))
        }
        takePCM = pcm
        let n = 60
        var nat = [Double](), mine = [Double?](), rms = [Double]()
        for i in 0..<n {
            let x = Double(i)
            nat.append(120.0 + 40.0 * sin(x / 6.0))
            mine.append(118.0 + 46.0 * sin(x / 5.4))
            rms.append(abs(sin(x / 4.0)))
        }
        curve = (nat: nat, mine: mine, rms: rms)
        // 逐词比对也造一份假的，好在模拟器上验界面（真机上是现算的）
        diff = Demo.fakeCompare()
        hasTake = true
    }

    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var fileURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("take.wav")
    }

    func reset() {
        stopPlayback()
        hasTake = false; heard = nil; wrongWords = []; score = nil; message = nil; diff = nil
        heardAttributed = AttributedString("")
        curve = nil
        takePCM = []
    }

    // MARK: - 录

    func start() {
        Task {
            guard await requestMic() else { message = "没有麦克风权限，去设置里打开"; return }
            Player.shared.pause()
            let s = AVAudioSession.sharedInstance()
            // 录的时候要切到能录能放的类别，录完再切回纯播放
            try? s.setCategory(.playAndRecord, mode: .default,
                               options: [.defaultToSpeaker, .allowBluetooth])
            try? s.setActive(true)
            // 直接录成 16k 单声道 wav：既能拿去分析，也能直接喂给服务器的 whisper
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVSampleRateKey: 16000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
            ]
            do {
                try? FileManager.default.removeItem(at: fileURL)
                let r = try AVAudioRecorder(url: fileURL, settings: settings)
                r.record()
                recorder = r
                isRecording = true
                message = "录音中… 念完再按一次停"
            } catch {
                message = "开不了录音：\(error.localizedDescription)"
            }
        }
    }

    func stop(sentence: Api.Sentence?, natWords: [Api.Word] = [],
              autoAB: Bool, range: ClosedRange<Double>?) {
        guard isRecording else { return }
        recorder?.stop(); recorder = nil
        isRecording = false
        hasTake = true
        message = "处理中…"
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .spokenAudio, options: [.allowBluetoothA2DP, .allowAirPlay])
        try? s.setActive(true)
        Task { await analyse(sentence: sentence, natWords: natWords, autoAB: autoAB, range: range) }
    }

    private func requestMic() async -> Bool {
        await withCheckedContinuation { c in
            AVAudioApplication.requestRecordPermission { ok in c.resume(returning: ok) }
        }
    }

    // MARK: - 分析

    private func analyse(sentence: Api.Sentence?, natWords: [Api.Word],
                         autoAB: Bool, range: ClosedRange<Double>?) async {
        guard let mine = try? loadPCM16k(fileURL) else { message = "读不到刚才的录音"; return }
        takePCM = mine
        guard mine.count > 16000 / 8 else { message = "没录到声音，再来一次"; return }
        let nat = Player.shared.pcm16k(range: range)
        guard nat.count > 1000 else { message = "原声还没载入"; return }

        let A = analyze(nat), B = analyze(mine)
        let g = grade(A, B)
        curve = buildCurve(A, B, g.path)
        score = Score(words: nil, tone: g.tone, rhythm: g.rhythm)
        message = nil
        if autoAB { playAB(range: range) }

        // 逐词比对：把你的录音也对齐一遍，跟原声逐词比。
        // 全在手机上算（模型已验证和服务器一致，误差 6 毫秒），不联网、录音不出手机。
        //
        // 这里的每个"跑不了"都要说清原因 —— 上一版是静默跳过，
        // 界面上只能看到老的分数，根本不知道哪一步没走通。
        if #available(iOS 17.0, *) {
            if !Aligner.shared.isAvailable {
                message = "这个安装包里没带对齐模型，逐词比对用不了"
            } else if natWords.isEmpty {
                message = "这句还没切好词，逐词比对要等切词完成"
            } else if (sentence?.en ?? "").isEmpty {
                message = "没有原文，没法逐词比对"
            } else {
                message = "正在逐词比对…"
                do {
                    // 先剪掉首尾静音再对齐。
                    // 人按下录音键到真正开口，中间总有半秒到一秒；这段静音不剪掉，
                    // 整条时间轴都被推后，每个词的时长占比全算错（节奏分会莫名其妙很低）。
                    let (trimmed, lead) = Self.trimSilence(mine)
                    let myWords = try await Aligner.shared.align(pcm: trimmed, text: sentence!.en)
                        .map { w in
                            // 时间轴换回原录音的坐标，不然点词回放会对不上
                            var v = w; v.start += lead; v.end += lead; return v
                        }
                    let d = Compare.make(nat: natWords, mine: myWords, natPCM: nat, myPCM: mine)
                    if d.words.isEmpty {
                        message = "对不上词：原声 \(natWords.count) 个，你的 \(myWords.count) 个"
                    } else {
                        diff = d
                        score = Score(words: d.soundScore, tone: g.tone, rhythm: d.rhythmScore)
                        message = nil
                    }
                } catch {
                    message = "逐词比对没跑成：\(error.localizedDescription)"
                }
            }
        } else {
            message = "逐词比对需要 iOS 17 以上"
        }

        // 机器听写：本机 whisper，录音只在自己家里流转
        if let wav = try? Data(contentsOf: fileURL), let en = sentence?.en {
            do {
                let text = try await Api.recognize(wav: wav)
                heard = text
                let (attr, wrong, acc) = compare(ref: en, hyp: text)
                heardAttributed = attr; wrongWords = wrong
                score = Score(words: acc, tone: g.tone, rhythm: g.rhythm)
                if let src = sentence?.src {
                    await Api.uploadRec(src, data: wav, ext: "wav",
                                        score: Double(score?.overall ?? 0), heard: text,
                                        dur: Double(mine.count) / 16000)
                }
            } catch {
                message = "听写服务没连上（曲线对比不受影响）"
            }
        }
    }

    // MARK: - 放

    func playMine(range: ClosedRange<Double>?) {
        Player.shared.pause()
        stopPlayback()
        guard let p = try? AVAudioPlayer(contentsOf: fileURL) else { return }
        player = p
        p.play()
    }
    /// 先原声、再自己的，隔 0.35 秒 —— 差别最听得出来
    func playAB(range: ClosedRange<Double>?) {
        stopPlayback()
        Player.shared.loop = false
        Player.shared.play(from: range?.lowerBound ?? 0)
        let wait = ((range?.upperBound ?? Player.shared.duration)
                    - (range?.lowerBound ?? 0)) / Double(Player.shared.rate) + 0.35
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            self?.playMine(range: range)
        }
    }
    func stopPlayback() { player?.stop(); player = nil }

    /// 单独听一个词：先原声那半秒，再你念的那半秒。
    /// 这是"听出差别"最直接的办法 —— 整句里听不出来的毛病，
    /// 单个词一前一后放两遍，一耳朵就知道差在哪。
    func playWordAB(nat: ClosedRange<Double>, mine: ClosedRange<Double>,
                    done: (() -> Void)? = nil) {
        stopPlayback()
        Player.shared.loop = false
        Player.shared.claim(loop: false, segment: nat)
        Player.shared.play(from: nat.lowerBound)
        let natLen = (nat.upperBound - nat.lowerBound) / Double(Player.shared.rate)
        DispatchQueue.main.asyncAfter(deadline: .now() + natLen + 0.28) { [weak self] in
            guard let self else { return }
            Player.shared.pause()
            self.playMineSegment(mine)
            DispatchQueue.main.asyncAfter(deadline: .now() + (mine.upperBound - mine.lowerBound) + 0.2) {
                done?()
            }
        }
    }

    /// 只放自己录音里的某一段
    private func playMineSegment(_ r: ClosedRange<Double>) {
        guard let p = try? AVAudioPlayer(contentsOf: fileURL) else { return }
        player = p
        p.currentTime = max(0, r.lowerBound)
        p.play()
        let len = r.upperBound - r.lowerBound
        DispatchQueue.main.asyncAfter(deadline: .now() + len) { [weak p] in p?.stop() }
    }

    // MARK: - 特征与打分（跟电脑版同一套）

    /// 剪掉首尾静音，返回剪完的波形和"前面剪掉了多少秒"。
    /// 判据是短时能量：连续 100 毫秒超过阈值才算开口，避免被一次呼吸声骗到。
    static func trimSilence(_ pcm: [Float], sr: Double = 16000) -> ([Float], Double) {
        guard pcm.count > 1600 else { return (pcm, 0) }
        let win = Int(sr * 0.02)                       // 20 毫秒一格
        var energy: [Float] = []
        energy.reserveCapacity(pcm.count / win + 1)
        var i = 0
        while i < pcm.count {
            let j = min(pcm.count, i + win)
            var sum: Float = 0
            for k in i..<j { sum += pcm[k] * pcm[k] }
            energy.append((sum / Float(j - i)).squareRoot())
            i = j
        }
        guard let peak = energy.max(), peak > 0.001 else { return (pcm, 0) }
        let th = peak * 0.06                           // 峰值的 6%
        let need = 5                                   // 连着 5 格＝100 毫秒才算数
        var first = 0, last = energy.count - 1
        var run = 0
        for (k, e) in energy.enumerated() where e > th {
            run += 1
            if run >= need { first = max(0, k - run + 1); break }
        }
        run = 0
        for k in stride(from: energy.count - 1, through: 0, by: -1) where energy[k] > th {
            run += 1
            if run >= need { last = min(energy.count - 1, k + run - 1); break }
        }
        guard last > first else { return (pcm, 0) }
        // 前后各留 60 毫秒余量，别把起音和余音剪掉（虚词的起音很轻，剪狠了就没了）
        let pad = Int(sr * 0.06)
        let a = max(0, first * win - pad)
        let b = min(pcm.count, (last + 1) * win + pad)
        return (Array(pcm[a..<b]), Double(a) / sr)
    }

    private func loadPCM16k(_ url: URL) throws -> [Float] {
        let f = try AVAudioFile(forReading: url)
        let fmt = f.processingFormat
        guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(f.length)),
              let ch = buf.floatChannelData else { return [] }
        try f.read(into: buf)
        let n = Int(buf.frameLength)
        var out = [Float](repeating: 0, count: n)
        for i in 0..<n { out[i] = ch[0][i] }
        if abs(fmt.sampleRate - 16000) < 1 { return out }
        return Player.resample(out, from: fmt.sampleRate, to: 16000)
    }

    private struct Feat { var rms: [Float]; var rel: [Float]; var dur: Double }

    /// 每 10 毫秒一帧：算音量，再用归一化自相关估音高，转成相对半音
    private func analyze(_ pcm: [Float]) -> Feat {
        let sr = 16000.0, hop = 160, frame = 1024
        let nf = max(1, (pcm.count - frame) / hop)
        var rms = [Float](repeating: 0, count: nf)
        for i in 0..<nf {
            var e: Float = 0
            let o = i * hop
            for j in 0..<frame { e += pcm[o + j] * pcm[o + j] }
            rms[i] = sqrt(e / Float(frame))
        }
        let peak = rms.max() ?? 0
        let th = max(peak * 0.06, 0.004)
        var a = 0, b = nf - 1
        while a < nf && rms[a] < th { a += 1 }
        while b > a && rms[b] < th { b -= 1 }
        a = max(0, a - 5); b = min(nf - 1, b + 5)
        guard b > a else { return Feat(rms: [], rel: [], dur: 0) }

        var R: [Float] = [], F: [Float] = []
        let lo = Int(sr / 400), hi = min(Int(sr / 60), frame - 1)
        for i in a...b {
            R.append(rms[i] / (peak + 1e-9))
            if rms[i] <= th { F.append(0); continue }
            let o = i * hop
            var e0: Float = 0
            for j in 0..<frame { e0 += pcm[o + j] * pcm[o + j] }
            if e0 < 1e-5 { F.append(0); continue }
            var best = 0, bestV: Float = 0
            var lag = lo
            while lag <= hi {
                var s: Float = 0, e1: Float = 0
                var j = 0
                while j + lag < frame { s += pcm[o + j] * pcm[o + j + lag]
                                       e1 += pcm[o + j + lag] * pcm[o + j + lag]; j += 2 }
                let v = s / (sqrt(e0 * e1) + 1e-9)
                if v > bestV { bestV = v; best = lag }
                lag += 1
            }
            F.append(bestV > 0.5 && best > 0 ? Float(sr) / Float(best) : 0)
        }
        // 中值平滑去倍频跳点 → 半音 → 减中位数得到"相对音高走势"
        var S = F
        for i in 1..<max(1, F.count - 1) {
            let t = [F[i-1], F[i], F[i+1]].filter { $0 > 0 }.sorted()
            S[i] = t.isEmpty ? 0 : t[t.count / 2]
        }
        let semi = S.map { $0 > 0 ? 12 * log2($0 / 100) : Float.nan }
        let voiced = semi.filter { !$0.isNaN }.sorted()
        let med = voiced.isEmpty ? 0 : voiced[voiced.count / 2]
        return Feat(rms: R, rel: semi.map { $0.isNaN ? Float.nan : $0 - med },
                    dur: Double(R.count) * 0.01)
    }

    /// 把 DTW 路径上的对应关系摊平成"每一帧：原声多少半音、你的多少半音"
    private func buildCurve(_ A: Feat, _ B: Feat, _ path: [(Int, Int)]) -> (nat: [Double], mine: [Double?], rms: [Double])? {
        guard !A.rel.isEmpty else { return nil }
        var mine = [Double?](repeating: nil, count: A.rel.count)
        for (i, j) in path where mine[i] == nil {
            mine[i] = B.rel[j].isNaN ? nil : Double(B.rel[j])
        }
        return (A.rel.map { $0.isNaN ? Double.nan : Double($0) },
                mine, A.rms.map { Double($0) })
    }

    private func grade(_ A: Feat, _ B: Feat) -> (tone: Int, rhythm: Int, path: [(Int, Int)]) {
        guard !A.rms.isEmpty, !B.rms.isEmpty else { return (0, 0, []) }
        let n = A.rms.count, m = B.rms.count
        var D = [[Double]](repeating: [Double](repeating: .infinity, count: m + 1), count: n + 1)
        D[0][0] = 0
        func cost(_ i: Int, _ j: Int) -> Double {
            var c = Double(abs(A.rms[i] - B.rms[j])) * 2.2
            let x = A.rel[i], y = B.rel[j]
            if !x.isNaN && !y.isNaN { c += Double(min(abs(x - y), 12)) * 0.13 }
            else if x.isNaN != y.isNaN { c += 0.30 }
            return c
        }
        for i in 1...n { for j in 1...m {
            D[i][j] = cost(i-1, j-1) + min(D[i-1][j-1], min(D[i-1][j], D[i][j-1]))
        } }
        var path: [(Int, Int)] = []
        var i = n, j = m
        while i > 0 && j > 0 {
            path.append((i-1, j-1))
            let c = [D[i-1][j-1], D[i-1][j], D[i][j-1]]
            let k = c.firstIndex(of: c.min()!)!
            if k == 0 { i -= 1; j -= 1 } else if k == 1 { i -= 1 } else { j -= 1 }
        }
        let d = D[n][m] / Double(max(1, path.count))
        var xs: [Double] = [], ys: [Double] = []
        for (i, j) in path where !A.rel[i].isNaN && !B.rel[j].isNaN {
            xs.append(Double(A.rel[i])); ys.append(Double(B.rel[j]))
        }
        var corr = 0.0
        if xs.count > 8 {
            let mx = xs.reduce(0, +) / Double(xs.count), my = ys.reduce(0, +) / Double(ys.count)
            var sxy = 0.0, sxx = 0.0, syy = 0.0
            for k in 0..<xs.count {
                let a = xs[k] - mx, b = ys[k] - my
                sxy += a * b; sxx += a * a; syy += b * b
            }
            corr = sxy / (sqrt(sxx * syy) + 1e-9)
        }
        let ratio = B.dur / max(0.01, A.dur)
        let pen = min(1, abs(log(ratio)) / 0.55)
        let rhythm = max(0, Int(100 * (1 - min(1, d / 0.85)) * (1 - pen * 0.45)))
        return (max(0, Int(corr * 100)), rhythm, path)
    }

    /// 机器听写的结果跟原句逐词比：对的正常显示，错的标红，漏的补出来
    private func compare(ref: String, hyp: String) -> (AttributedString, [String], Int) {
        func norm(_ s: String) -> [String] {
            let cleaned = String(s.lowercased().map { ch -> Character in
                (ch.isLetter || ch.isNumber || ch == "'") ? ch : " "
            })
            return cleaned.split(separator: " ").map(String.init)
        }
        let R = norm(ref), H = norm(hyp)
        let n = R.count, m = H.count
        guard n > 0 else { return (AttributedString(hyp), [], 0) }
        var D = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { D[i][0] = i }
        for j in 0...m { D[0][j] = j }
        for i in 1...n { for j in 1...m {
            D[i][j] = min(D[i-1][j-1] + (R[i-1] == H[j-1] ? 0 : 1), min(D[i-1][j] + 1, D[i][j-1] + 1))
        } }
        var out = AttributedString(""), wrong: [String] = []
        var i = n, j = m
        var ops: [(String, Int, Int)] = []
        while i > 0 || j > 0 {
            if i > 0 && j > 0 && D[i][j] == D[i-1][j-1] + (R[i-1] == H[j-1] ? 0 : 1) {
                ops.append((R[i-1] == H[j-1] ? "=" : "s", i-1, j-1)); i -= 1; j -= 1
            } else if i > 0 && D[i][j] == D[i-1][j] + 1 { ops.append(("d", i-1, -1)); i -= 1 }
            else { ops.append(("i", -1, j-1)); j -= 1 }
        }
        for (op, ri, hi) in ops.reversed() {
            var piece: AttributedString
            switch op {
            case "=": piece = AttributedString(H[hi] + " ")
            case "d": piece = AttributedString("[漏:" + R[ri] + "] ")
                      piece.foregroundColor = .red; wrong.append(R[ri])
            case "i": piece = AttributedString(H[hi] + " ")
                      piece.foregroundColor = .orange; piece.strikethroughStyle = Text.LineStyle.single
                      wrong.append(H[hi])
            default:  piece = AttributedString(H[hi] + " ")
                      piece.foregroundColor = .red; wrong.append(R[ri])
            }
            out += piece
        }
        let acc = max(0, Int(100 * (1 - Double(D[n][m]) / Double(n))))
        return (out, Array(Set(wrong)).sorted(), acc)
    }
}
