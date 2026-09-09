import Foundation
import CoreML
import AVFoundation

/// 手机端强制对齐 —— 这块是"完全离线"的地基。
///
/// 服务器上给整本词典切词用的是 torchaudio 的 WAV2VEC2_ASR_BASE_960H；
/// 这里用的是**同一套权重**转成的 CoreML 模型，所以结果应该一致
/// （验证脚本会拿 fa.db 的结果逐词比对）。
///
/// 分两步：
///   1. 模型算出每一帧属于哪个字母的概率（CTC 输出，29 个符号）
///   2. 动态规划在这些概率里找一条"最像目标文本"的路径 → 每个词几点几秒
/// 第 2 步是纯算法，跟 Python 版一模一样，没有精度损失。
///
/// 顺带得到的每个词的路径得分，就是发音准确度（GOP，业界给发音打分的标准做法）。
@available(iOS 17.0, *)
final class Aligner {
    static let shared = Aligner()

    /// 一个词对齐出来的结果
    struct Word {
        var text: String
        var start: Double          // 秒
        var end: Double
        var score: Double          // 0~1，越高说明念得越像
    }

    private var model: MLModel?
    private var labels: [String] = []
    private var labelIndex: [Character: Int] = [:]
    private let sampleRate: Double = 16000
    /// 模型输入固定 8 秒 —— 固定形状才能用上神经引擎，比可变长度快好几倍
    private let inputLen = 16000 * 8

    private init() {}

    /// 这个包里带没带对齐模型。没带就退回服务器算（云端 CI 出的包就没带）。
    var isAvailable: Bool {
        Bundle.main.url(forResource: "Wav2Vec2CTC", withExtension: "mlmodelc") != nil
            || Bundle.main.url(forResource: "Wav2Vec2CTC", withExtension: "mlpackage") != nil
    }

    /// 第一次用的时候才加载（约 181M，加载 1 秒左右），之后常驻
    private func ensureLoaded() throws {
        guard model == nil else { return }
        guard let url = Bundle.main.url(forResource: "Wav2Vec2CTC", withExtension: "mlmodelc")
                ?? Bundle.main.url(forResource: "Wav2Vec2CTC", withExtension: "mlpackage") else {
            throw Err.noModel
        }
        let cfg = MLModelConfiguration()
        cfg.computeUnits = .all                      // 让系统自己挑神经引擎/GPU/CPU
        model = try MLModel(contentsOf: url, configuration: cfg)

        guard let lurl = Bundle.main.url(forResource: "ctc_labels", withExtension: "json"),
              let arr = try? JSONDecoder().decode([String].self, from: Data(contentsOf: lurl)) else {
            throw Err.noLabels
        }
        labels = arr
        for (i, s) in arr.enumerated() where s.count == 1 {
            labelIndex[Character(s)] = i
        }
    }

    enum Err: LocalizedError {
        case noModel, noLabels, tooShort, noAlignableWord
        var errorDescription: String? {
            switch self {
            case .noModel:  return "找不到对齐模型"
            case .noLabels: return "找不到字母表"
            case .tooShort: return "音频太短"
            case .noAlignableWord: return "这句里没有能对齐的词"
            }
        }
    }

    // MARK: - 对外接口

    /// 把一段 16k 单声道音频和它的文本对齐，返回每个词的起止时间和得分。
    /// 超过 8 秒会分段处理再拼起来。
    func align(pcm: [Float], text: String) async throws -> [Word] {
        try ensureLoaded()
        guard pcm.count > 800 else { throw Err.tooShort }

        let words = text.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !words.isEmpty else { throw Err.noAlignableWord }

        // 短句（≤8 秒）一次算完；长的按 8 秒切段，段间留 0.5 秒重叠避免切在词中间
        if pcm.count <= inputLen {
            let logits = try infer(pcm)
            return try dp(logits: logits, frames: logits.count / labels.count,
                          words: words, audioLen: pcm.count, offset: 0)
        }
        return try await alignLong(pcm: pcm, words: words)
    }

    // MARK: - 跑模型

    /// 返回一维数组，按 [帧0的29个概率, 帧1的29个概率, …] 排列
    private func infer(_ pcm: [Float]) throws -> [Float] {
        guard let model else { throw Err.noModel }
        let arr = try MLMultiArray(shape: [1, NSNumber(value: inputLen)], dataType: .float32)
        let p = arr.dataPointer.bindMemory(to: Float.self, capacity: inputLen)
        // 不足 8 秒就补零；补的那段模型会输出静音，不影响前面的对齐
        pcm.withUnsafeBufferPointer { src in
            p.update(from: src.baseAddress!, count: min(pcm.count, inputLen))
        }
        if pcm.count < inputLen {
            p.advanced(by: pcm.count).update(repeating: 0, count: inputLen - pcm.count)
        }
        let input = try MLDictionaryFeatureProvider(dictionary: ["wav": MLFeatureValue(multiArray: arr)])
        let out = try model.prediction(from: input)
        guard let logits = out.featureValue(for: "logits")?.multiArrayValue else { throw Err.noModel }

        let n = logits.count
        var buf = [Float](repeating: 0, count: n)
        let lp = logits.dataPointer.bindMemory(to: Float.self, capacity: n)
        buf.withUnsafeMutableBufferPointer { dst in
            dst.baseAddress!.update(from: lp, count: n)
        }
        return buf
    }

    // MARK: - 动态规划找最优路径（跟 Python 版同一套算法）

    private func dp(logits: [Float], frames: Int, words: [String],
                    audioLen: Int, offset: Double) throws -> [Word] {
        let V = labels.count                      // 29
        let blank = 0                             // '-' 是 CTC 的空白符
        let sep = labelIndex["|"] ?? 1            // 词之间的分隔符

        // 目标符号序列：词内是字母，词之间插一个 '|'
        var tokens: [Int] = []
        var spans: [(word: String, from: Int, count: Int)] = []
        for w in words {
            let chars = w.uppercased().compactMap { labelIndex[$0] }
            if chars.isEmpty { continue }
            if !tokens.isEmpty { tokens.append(sep) }
            spans.append((w, tokens.count, chars.count))
            tokens.append(contentsOf: chars)
        }
        guard !tokens.isEmpty else { throw Err.noAlignableWord }

        // 经典 CTC 强制对齐：状态是"目标序列走到第几个符号"，
        // 每帧要么停在原地（重复或空白），要么前进一个。
        let T = frames, S = tokens.count
        let NEG = -Float.greatestFiniteMagnitude / 4
        var prev = [Float](repeating: NEG, count: S)
        var back = [Bool](repeating: false, count: T * S)   // true＝这一帧前进了一格

        func lp(_ t: Int, _ v: Int) -> Float { logits[t * V + v] }

        prev[0] = lp(0, tokens[0])
        if S > 1 { prev[1] = lp(0, tokens[1]) }             // 允许从第二个符号起步
        var cur = [Float](repeating: NEG, count: S)

        for t in 1..<T {
            for s in 0..<S {
                let stay = prev[s]
                let move = s > 0 ? prev[s - 1] : NEG
                let advance = move > stay
                cur[s] = (advance ? move : stay) + lp(t, tokens[s])
                back[t * S + s] = advance
            }
            swap(&prev, &cur)
            for i in 0..<S { cur[i] = NEG }
        }

        // 从终点回溯，得到每个符号占了哪几帧
        var s = (S > 1 && prev[S - 2] > prev[S - 1]) ? S - 2 : S - 1
        var frameOf = [Int](repeating: 0, count: S)
        var scoreOf = [Float](repeating: 0, count: S)
        var t = T - 1
        while t >= 0 {
            frameOf[s] = t
            scoreOf[s] += lp(t, tokens[s])
            if t > 0 && back[t * S + s] { s = max(0, s - 1) }
            t -= 1
        }

        // 帧 → 秒。模型每帧覆盖多少秒，用"音频长度 ÷ 帧数"反推最准
        let secPerFrame = Double(inputLen) / Double(frames) / sampleRate
        var out: [Word] = []
        for sp in spans {
            let f0 = frameOf[sp.from]
            let f1 = frameOf[sp.from + sp.count - 1]
            var sc: Float = 0
            for i in sp.from..<(sp.from + sp.count) { sc += scoreOf[i] }
            // 得分是对数概率，转成 0~1 好理解
            let avg = Double(sc) / Double(sp.count)
            out.append(Word(text: sp.word,
                            start: offset + Double(f0) * secPerFrame,
                            end: offset + Double(f1 + 1) * secPerFrame,
                            score: min(1, max(0, exp(avg / 3)))))
        }
        return out
    }

    /// 长音频：按 8 秒切段分别对齐再拼。
    /// 词怎么分到各段：先按时长比例粗分，段与段之间留 0.5 秒重叠，
    /// 拼接时以前一段的结果为准，避免边界处重复。
    private func alignLong(pcm: [Float], words: [String]) async throws -> [Word] {
        let step = inputLen - Int(0.5 * sampleRate)
        var out: [Word] = []
        var wordIdx = 0
        var pos = 0
        while pos < pcm.count, wordIdx < words.count {
            let end = min(pos + inputLen, pcm.count)
            let chunk = Array(pcm[pos..<end])
            // 这一段大概能装多少词：按"整句词数 × 这段占总时长的比例"估，多给 30% 余量
            let frac = Double(end - pos) / Double(pcm.count)
            let take = min(words.count - wordIdx,
                           max(1, Int(Double(words.count) * frac * 1.3)))
            let sub = Array(words[wordIdx..<(wordIdx + take)])
            let logits = try infer(chunk)
            let got = try dp(logits: logits, frames: logits.count / labels.count,
                             words: sub, audioLen: chunk.count,
                             offset: Double(pos) / sampleRate)
            // 落在重叠区里的最后一两个词丢掉，交给下一段（那儿的上下文更全）
            let keep = (end >= pcm.count) ? got.count : max(1, got.count - 1)
            out.append(contentsOf: got.prefix(keep))
            wordIdx += keep
            pos += step
        }
        return out
    }
}
