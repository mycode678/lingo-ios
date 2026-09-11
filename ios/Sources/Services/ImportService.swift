import Foundation
import AVFoundation

/// 用户自己的材料：**从一个音频/视频文件，变成一个能练的材料包**。
///
/// 用户原话（`PLAN.md` 5.2）：
/// > 用户导入不限于iOS手机/ipad、icloud、电脑浏览器上传，还包括百度网盘\google 云盘
/// > 等网盘、iphone/ipad播客等。
///
/// **整条流水线全在手机上跑**，服务器一次都不碰：
/// ```
/// 文件 → 抽音轨 → 切成块 → 本机听写(SFSpeechRecognizer) → 分句
///      → 本机强制对齐(Aligner，词级时间戳) → 切出每句的音频 → 生成 pack.sqlite
/// ```
/// 出来的包跟 CDN 上下的包**格式一模一样**，所以精听、七个练法、复习排期
/// 全都直接能用，不用为"用户导入的材料"再写一套。
@MainActor
final class ImportService: ObservableObject {
    static let shared = ImportService()

    struct Step: Equatable {
        var text: String
        var fraction: Double        // 0~1
    }
    @Published private(set) var step: Step?
    @Published private(set) var running = false

    enum Err: LocalizedError {
        case noAudio, tooShort, transcribeFailed, quota(String), busy
        var errorDescription: String? {
            switch self {
            case .noAudio:          return "这个文件里没有能用的音轨"
            case .tooShort:         return "太短了，至少要 3 秒"
            case .transcribeFailed: return "没听出内容 —— 换一段人声清楚点的试试"
            case .quota(let m):     return m
            case .busy:             return "上一份还在处理，等它完了再来"
            }
        }
    }

    /// 一次听写多长。SFSpeechRecognizer 对单次时长有限制，切块最稳。
    /// 原来写 45 秒，真机考卷上量出来**一块只认出前面一小截**（107 秒 225 个词
    /// 只出来 70 多个）。20 秒是"认得全"和"别太碎"之间的折中。
    private let chunkSeconds = 20.0
    /// 下刀点允许在目标位置前后这么多秒里找最安静的地方 —— 免得切在词中间。
    private let cutSearch = 2.5
    /// 一段听写多长：攒够这么多秒就在下一处静音下刀
    private let batchTarget = 8.0
    /// 单段上限（有人一口气说很久时也得切）
    private let batchMax = 14.0
    /// 对齐引擎吃 16k 单声道
    private let sr = 16000.0

    // MARK: 入口

    /// 把一个本地文件导成材料包。`title` 是用户给的名字。
    @discardableResult
    func importMedia(from src: URL, title: String,
                     ent: EntitlementService = .shared,
                     catalog: CatalogService = .shared) async throws -> CatalogService.Pack {
        guard !running else { throw Err.busy }
        if let why = ent.blockedReason(.importFile) { throw Err.quota(why) }
        running = true
        defer { running = false; step = nil }

        // 从文件 App / 网盘拿到的 URL 是"沙盒外"的，必须开一次访问权限再读
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }

        step = Step(text: "读文件", fraction: 0.02)
        let pcm = try await decode16k(src)
        guard pcm.count > Int(sr * 3) else { throw Err.tooShort }

        let sentences = try await analyze(pcm: pcm) { [weak self] text, frac in
            self?.step = Step(text: text, fraction: frac)
        }
        guard !sentences.isEmpty else { throw Err.transcribeFailed }

        step = Step(text: "切音频", fraction: 0.7)
        let pack = try build(title: title, pcm: pcm, sentences: sentences, catalog: catalog)
        ent.consume(.importFile)
        step = Step(text: "完成", fraction: 1)
        return pack
    }

    // MARK: 听写 + 对齐（导入和精度基准共用这一段）

    /// 一块一块地听写＋对齐：长音频一次性喂进去，内存和时间都吃不消，
    /// 而且中间失败一次就全白干。
    ///
    /// **基准测试（-importbench）走的就是这个函数**，不是另写一份"差不多的"实现 ——
    /// 量出来的准确率才代表用户真导入时的准确率。
    func analyze(pcm: [Float],
                 progress: ((String, Double) -> Void)? = nil)
        async throws -> [(en: String, words: [Aligner.Word])] {
        var sentences: [(en: String, words: [Aligner.Word])] = []
        let total = Double(pcm.count) / sr
        // 先按"人什么时候在说话"把音频切成一段一段，再一段一段听写。
        //
        // 以前是按固定秒数硬切（45 秒、后来 20 秒），有两个毛病：
        // 1. iOS 的听写器碰到块里有长停顿就**到那儿收工**，后面的话一个字都不给，
        //    而且是确定性的 —— 同一块重来三次，三次都只认出前面那 7 个词；
        // 2. 块一长，对齐就得走多窗拼接那条路，误差也跟着上来。
        // 按停顿切成 8 秒上下的小段，两个毛病一起没了：每段就一两句话，
        // 听写器不会中途收工，对齐也正好落在单窗（模型输入就是 8 秒）里。
        let parts = speechBatches(pcm, total: total)
        var nth = 0
        for (t, end) in parts {
            nth += 1
            let chunk = Array(pcm[Int(t * sr)..<min(pcm.count, Int(end * sr))])
            progress?("听写第 \(nth)/\(parts.count) 段", 0.05 + 0.6 * (t / total))

            if nth > 1 { try? await Task.sleep(nanoseconds: 300_000_000) }
            var heard: (text: String, enough: Bool) = (try? await transcribe(chunk)) ?? ("", true)
            // 重来三次还是认不全，就把这一段**从中间最长的静音处劈成两半**分别听。
            // 实测有的段落是"确定性地"只认出开头几个词（同一段重来三次，三次都一样），
            // 换个切法它就肯认了 —— 剩下那 13 个漏词全是这么来的。
            if !heard.enough, let mid = bestSilence(pcm, from: t, to: end) {
                print("IMPORT 第 \(nth) 段认不全，从 \(String(format: "%.1f", mid)) 秒劈开重听")
                var textA = "", textB = ""
                let a = Array(pcm[Int(t * sr)..<min(pcm.count, Int(mid * sr))])
                let b = Array(pcm[Int(mid * sr)..<min(pcm.count, Int(end * sr))])
                if let ra = try? await transcribe(a) { textA = ra.text }
                try? await Task.sleep(nanoseconds: 300_000_000)
                if let rb = try? await transcribe(b) { textB = rb.text }
                let joined = (textA + " " + textB).trimmingCharacters(in: .whitespaces)
                if joined.split(separator: " ").count > heard.text.split(separator: " ").count {
                    heard = (joined, true)
                }
            }
            let text = heard.text
            if !text.isEmpty {
                // 每段认出多少词要打出来：掉词的时候一眼看得出是听写掉的还是对齐掉的
                print("IMPORT 第 \(nth) 段 \(String(format: "%.1f", end - t)) 秒 → 听写 "
                      + "\(text.split(separator: " ").count) 词")
                progress?("对齐第 \(nth) 段", 0.05 + 0.6 * (end / total))
                // **整块只对齐一次**，再按句子把词切开。
                // 曾经是每句拿整块去对一次 —— 那一句会被摊到整整 45 秒上，
                // 时间戳全错，切出来的音频跟文字对不上，整个导入就废了。
                if let all = try? await Aligner.shared.align(pcm: chunk, text: text), !all.isEmpty {
                    // 块内时间轴 → 整段时间轴
                    let words = all.map {
                        Aligner.Word(text: $0.text, start: $0.start + t,
                                     end: $0.end + t, score: $0.score)
                    }
                    print("IMPORT 第 \(nth) 段 → 对齐 \(words.count) 词，分成 \(group(words).count) 句")
                    sentences.append(contentsOf: group(words))
                }
            }
        }
        // ---- 精修：每句拿**自己那一小段**音频重对一次 ----
        //
        // 上面那一遍是按 45 秒一块对的，长段里只要跨过一处静音，后面就整体漂。
        // 实测（网页端同一个毛病，新概念 2 第一句）：整段对齐把 First 放在 4.12–4.77，
        // 而这个词真实位置是 4.70–5.00 —— 差半秒，点"First"播出来是前面那段静音。
        // 拿这一句单独重对一次，结果跟按能量量出来的真实边界差几十毫秒。
        //
        // 代价很小：一句两三秒，对齐模型输入本来就是 8 秒一窗。
        var fixed: [(en: String, words: [Aligner.Word])] = []
        for sent in sentences {
            guard let first = sent.words.first, let last = sent.words.last else { continue }
            let a = max(0, first.start - 0.15), b = min(Double(pcm.count) / sr, last.end + 0.20)
            let i0 = Int(a * sr), i1 = min(pcm.count, Int(b * sr))
            guard i1 - i0 > Int(sr * 0.3) else { fixed.append(sent); continue }
            let clip = Array(pcm[i0..<i1])
            if let re = try? await Aligner.shared.align(pcm: clip, text: sent.en),
               re.count >= max(1, sent.en.split(separator: " ").count * 2 / 3) {
                fixed.append((sent.en, re.map {
                    Aligner.Word(text: $0.text, start: $0.start + a, end: $0.end + a, score: $0.score)
                }))
            } else {
                fixed.append(sent)      // 重对失败就保留粗对的，总比没有强
            }
        }
        return fixed
    }

    /// 这一段里最长的那处静音在第几秒（两头各留 1.5 秒，别劈出个没用的碎片）。
    /// 认不全的时候拿它当劈开的刀口。
    private func bestSilence(_ pcm: [Float], from: Double, to: Double) -> Double? {
        guard to - from > 3.5 else { return nil }
        let segs = voicedSegments(Array(pcm[Int(from * sr)..<min(pcm.count, Int(to * sr))]))
        guard segs.count >= 2 else { return nil }
        var best: Double? = nil
        var bestGap = 0.0
        for i in 1..<segs.count {
            let gap = segs[i].0 - segs[i - 1].1
            let mid = from + (segs[i].0 + segs[i - 1].1) / 2
            guard mid - from > 1.5, to - mid > 1.5 else { continue }
            if gap > bestGap { bestGap = gap; best = mid }
        }
        return best
    }

    /// 把整条音频切成"一段一段能一口气听写完"的小段，**刀口一律落在静音里**。
    ///
    /// 做法：先找出有人说话的那些片段（20 毫秒一帧看能量），再从头往下攒，
    /// 攒够 `batchTarget` 秒就在下一处静音的正中间下刀；单段最长 `batchMax` 秒
    /// （碰上一口气说很久的，也得切，否则听写器又要中途收工）。
    private func speechBatches(_ pcm: [Float], total: Double) -> [(Double, Double)] {
        let segs = voicedSegments(pcm)
        guard !segs.isEmpty else { return [(0, total)] }
        var out: [(Double, Double)] = []
        var start = 0.0
        var i = 0
        while i < segs.count {
            var j = i
            // 至少收一段，之后看攒够没有
            while j + 1 < segs.count, segs[j + 1].1 - start <= batchTarget { j += 1 }
            // 一口气说太久：在 batchMax 处硬切（下面还会挑最安静的点）
            var cut: Double
            if j + 1 < segs.count {
                cut = (segs[j].1 + segs[j + 1].0) / 2          // 静音正中间
            } else {
                cut = total
            }
            if cut - start > batchMax {
                cut = quietCut(pcm, target: start + batchMax, total: total)
            }
            out.append((start, min(cut, total)))
            start = min(cut, total)
            // 下一段从刀口之后的第一个说话片段开始
            while i < segs.count, segs[i].1 <= start { i += 1 }
            if start >= total - 0.05 { break }
        }
        if let last = out.last, last.1 < total - 0.3 { out.append((last.1, total)) }
        return out.filter { $0.1 - $0.0 > 0.3 }
    }

    /// 有人说话的片段（起止秒）。静音短于 `minSil` 不算断，太碎的片段丢掉。
    private func voicedSegments(_ pcm: [Float], minSil: Double = 0.3,
                                minSpeech: Double = 0.15) -> [(Double, Double)] {
        let win = Int(0.02 * sr)
        guard pcm.count > win * 5 else { return [] }
        var e: [Double] = []
        var i = 0
        while i + win <= pcm.count {
            var v = 0.0
            for k in i..<(i + win) { v += Double(pcm[k] * pcm[k]) }
            e.append((v / Double(win)).squareRoot())
            i += win
        }
        guard let peak = e.max(), peak > 0 else { return [] }
        let th = peak * 0.06
        var segs: [(Double, Double)] = []
        var st: Int? = nil
        var silence = 0
        for (k, v) in e.enumerated() {
            if v > th {
                if st == nil { st = k }
                silence = 0
            } else if let s0 = st {
                silence += 1
                if Double(silence) * 0.02 >= minSil {
                    let a = Double(s0) * 0.02, b = Double(k - silence + 1) * 0.02
                    if b - a >= minSpeech { segs.append((a, b)) }
                    st = nil; silence = 0
                }
            }
        }
        if let s0 = st {
            let a = Double(s0) * 0.02, b = Double(e.count) * 0.02
            if b - a >= minSpeech { segs.append((a, b)) }
        }
        return segs
    }

    /// 这段音频里有多少秒是"真的有人在说话"（20 毫秒一帧，按能量卡门槛）。
    /// 用来判断听写有没有认全：认出来的词数明显配不上说话的时长，就是漏了。
    private func voicedSeconds(_ pcm: [Float]) -> Double {
        let win = Int(0.02 * sr)
        guard pcm.count > win * 5 else { return 0 }
        var e: [Double] = []
        var i = 0
        while i + win <= pcm.count {
            var v = 0.0
            for k in i..<(i + win) { v += Double(pcm[k] * pcm[k]) }
            e.append((v / Double(win)).squareRoot())
            i += win
        }
        let peak = e.max() ?? 0
        guard peak > 0 else { return 0 }
        let th = peak * 0.06
        return Double(e.filter { $0 > th }.count) * 0.02
    }

    /// 在 target 附近找一处最安静的地方下刀。
    /// 一刀切在词中间，那个词两边各剩半截，听写认不出、对齐也没法认领。
    private func quietCut(_ pcm: [Float], target: Double, total: Double) -> Double {
        guard target < total - 0.2 else { return total }
        let lo = max(0.5, target - cutSearch), hi = min(total - 0.2, target + cutSearch)
        guard hi > lo else { return target }
        let win = Int(0.1 * sr)
        var best = target, bestE = Double.greatestFiniteMagnitude
        var x = lo
        while x < hi {
            let i = Int(x * sr)
            guard i + win <= pcm.count else { break }
            var e = 0.0
            for k in i..<(i + win) { e += Double(pcm[k] * pcm[k]) }
            if e < bestE { bestE = e; best = x + 0.05 }
            x += 0.05
        }
        return best
    }

    // MARK: 解码

    /// 任何格式（mp3/m4a/wav/mp4/mov…）都先统一成 16k 单声道浮点。
    /// 视频也走这条路 —— `AVAssetReader` 只挑音轨，不碰画面。
    func decode16k(_ url: URL) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw Err.noAudio
        }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: sr,
            AVNumberOfChannelsKey: 1
        ])
        reader.add(out)
        reader.startReading()
        var pcm: [Float] = []
        while let buf = out.copyNextSampleBuffer() {
            guard let bb = CMSampleBufferGetDataBuffer(buf) else { continue }
            // 不能用 CMBlockBufferGetDataPointer 拿到的指针配 totalLength 去读：
            // block buffer 允许由多段不连续内存拼成，那个指针只保证第一段有效，
            // 按全长读就越界了。CopyDataBytes 由系统负责拼。
            let len = CMBlockBufferGetDataLength(bb)
            guard len >= 4 else { CMSampleBufferInvalidate(buf); continue }
            var bytes = [UInt8](repeating: 0, count: len)
            let ok = bytes.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len,
                                           destination: $0.baseAddress!)
            }
            if ok == noErr {
                bytes.withUnsafeBytes { raw in
                    pcm.append(contentsOf: raw.bindMemory(to: Float.self).prefix(len / 4))
                }
            }
            CMSampleBufferInvalidate(buf)
        }
        guard reader.status != .failed else { throw Err.noAudio }
        return pcm
    }

    // MARK: 听写

    /// 听写一块，并且**认不全就自己重来**。
    ///
    /// iOS 的本机识别器不稳定：同样一段十几秒的音频，隔一次就只认出开头一小截
    /// （真机考卷上是 37 词 / 7 词 / 3 词 交替）。它不报错，只是安静地少给你几十个词，
    /// 后面整段话就这么没了 —— 用户那边表现为"导进来的材料缺了一大半"。
    ///
    /// 所以这里拿"认到第几秒"跟这块的真实长度比，差得多就重来（最多三次，
    /// 中间歇 0.7 秒让上一个识别任务彻底放手）。拿不到时间戳的机器上不为难它，直接收。
    private func transcribe(_ chunk: [Float]) async throws -> (text: String, enough: Bool) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("imp-\(UUID().uuidString).wav")
        try writeWav(chunk, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        // 这块里有多少秒是真的有人在说话 —— 判"认全了没有"的尺子。
        // 不用 Apple 给的时间戳：真机上它要么是 0、要么贴着音频结尾，判不出来。
        let voiced = voicedSeconds(chunk)
        // 英语朗读大概每秒 2.5~3 个词，按 1.2 个词/秒 卡（留足余量，宁可少重来）
        let least = Int(voiced * 1.2)
        var best = ""
        var bestN = -1
        for attempt in 1...3 {
            let h = try await Speech.shared.transcribeDetailed(tmp)
            let n = h.text.split(separator: " ").count
            if n > bestN { bestN = n; best = h.text }
            if n >= least { return (h.text, true) }
            print("IMPORT 第 \(attempt) 次只认出 \(n) 词（有人说话 "
                  + "\(String(format: "%.1f", voiced)) 秒，至少该有 \(least) 词），重来")
            try? await Task.sleep(nanoseconds: 900_000_000)
        }
        return (best, false)
    }

    /// 按**说话的停顿**分句 —— 断句的依据是声音，不是标点。
    ///
    /// 为什么不按标点：本机听写默认不给标点（`addsPunctuation = false`），
    /// 原来只好"每 18 个词硬切一刀"。实测 107 秒的考卷出来只有 7 句，
    /// 句子从人家话说到一半的地方切开，而且**按词数依次分配**那一套
    /// （取不满就 break）把后一半的词整个丢了：225 个词只剩 114 个。
    ///
    /// 现在的规矩：对齐已经给了每个词几点几秒，**相邻两个词之间静了 0.38 秒**
    /// 就断一句；一句超过难度闸（18 词）就在这一句里最长的那处停顿再劈开。
    /// 太碎的（少于 3 个词）并进旁边那句 —— 单独一个 "Yeah." 没法练。
    func group(_ ws: [Aligner.Word], gap: Double = 0.38) -> [(en: String, words: [Aligner.Word])] {
        guard !ws.isEmpty else { return [] }
        var groups: [[Aligner.Word]] = [[ws[0]]]
        for w in ws.dropFirst() {
            if let last = groups[groups.count - 1].last, w.start - last.end >= gap {
                groups.append([w])
            } else {
                groups[groups.count - 1].append(w)
            }
        }
        // 太长的再劈：在最长的那处停顿下刀，递归到都不超上限
        func chop(_ g: [Aligner.Word]) -> [[Aligner.Word]] {
            guard g.count > TrainKit.maxWords else { return [g] }
            var bi = g.count / 2, best = -1.0
            for i in 1..<g.count {
                let d = g[i].start - g[i - 1].end
                if d > best { best = d; bi = i }
            }
            return chop(Array(g[0..<bi])) + chop(Array(g[bi...]))
        }
        groups = groups.flatMap(chop)
        // 碎片并进旁边（先并前一句，前面没有就并后一句）
        var merged: [[Aligner.Word]] = []
        for g in groups {
            if g.count < 3, let last = merged.last,
               last.count + g.count <= TrainKit.maxWords {
                merged[merged.count - 1] = last + g
            } else {
                merged.append(g)
            }
        }
        if merged.count >= 2, merged[0].count < 3 {
            merged[1] = merged[0] + merged[1]; merged.removeFirst()
        }
        return merged.filter { $0.count >= 2 }
            .map { (en: $0.map { $0.text }.joined(separator: " "), words: $0) }
    }

    /// 分句（按标点，字幕/课文那条路还用得上）。**上限跟难度闸对齐（18 词）** —— 分出来的句子太长，
    /// 七个练法直接用不了，等于导进来白导。
    func split(_ text: String) -> [String] {
        var out: [String] = []
        var cur: [String] = []
        for w in text.split(separator: " ").map(String.init) {
            cur.append(w)
            let endsSentence = w.hasSuffix(".") || w.hasSuffix("?") || w.hasSuffix("!")
            if endsSentence || cur.count >= TrainKit.maxWords {
                out.append(cur.joined(separator: " ")); cur = []
            }
        }
        if !cur.isEmpty { out.append(cur.joined(separator: " ")) }
        // 太短的碎片并进前一句（"Yeah." 单独成句没法练）
        var merged: [String] = []
        for s in out {
            if let last = merged.last, s.split(separator: " ").count < 3,
               last.split(separator: " ").count + 3 <= TrainKit.maxWords {
                merged[merged.count - 1] = last + " " + s
            } else {
                merged.append(s)
            }
        }
        return merged.filter { $0.split(separator: " ").count >= 3 }
    }

    // MARK: 出包

    private func build(title: String, pcm: [Float],
                       sentences: [(en: String, words: [Aligner.Word])],
                       catalog: CatalogService) throws -> CatalogService.Pack {
        let id = "user-" + UUID().uuidString.prefix(8).lowercased()
        let dir = CatalogService.root.appendingPathComponent(id, isDirectory: true)
        let adir = dir.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: adir, withIntermediateDirectories: true)

        let db = try DB(testPath: dir.appendingPathComponent("pack.sqlite").path).open()
        try db.run("""
            CREATE TABLE sentences(id TEXT PRIMARY KEY, en TEXT, cn TEXT,
                                   level INTEGER, dur REAL, audio TEXT)
            """)
        try db.run("""
            CREATE TABLE words(sent_id TEXT, idx INTEGER, word TEXT, s REAL, e REAL)
            """)
        try db.run("CREATE INDEX ix_words ON words(sent_id, idx)")

        var n = 0
        for (i, s) in sentences.enumerated() {
            guard let first = s.words.first, let last = s.words.last else { continue }
            // 前后各留 80 毫秒，不然句首的辅音会被切掉一点
            let a = max(0, first.start - 0.08), b = min(Double(pcm.count) / sr, last.end + 0.08)
            guard b > a + 0.2 else { continue }
            let name = String(format: "%04d.wav", i)
            try writeWav(Array(pcm[Int(a * sr)..<Int(b * sr)]),
                         to: adir.appendingPathComponent(name))
            let sid = "\(id)/\(i)"
            try db.run("INSERT INTO sentences(id,en,cn,level,dur,audio) VALUES(?,?,?,?,?,?)",
                       [sid, s.en, "", level(s.en), b - a, name])
            for (k, w) in s.words.enumerated() {
                // 每句的时间轴从 0 开始（音频是单独切出来的）
                try db.run("INSERT INTO words(sent_id,idx,word,s,e) VALUES(?,?,?,?,?)",
                           [sid, k, w.text, w.start - a, w.end - a])
            }
            n += 1
        }
        db.close()

        try catalog.registerLocal(id: id, name: title, sentences: n)
        return CatalogService.Pack(id: id, name: title, version: 1,
                                   sentences: n, restricted: false,
                                   installedAt: Date().timeIntervalSince1970)
    }

    /// 难度分级：句子越长、生词越多，级别越高。跟难度闸用的是同一套判据。
    private func level(_ en: String) -> Int {
        let ws = TrainKit.tokenize(en)
        guard !ws.isEmpty else { return 1 }
        let rare = Double(ws.filter { !Vocab.isCommon($0) }.count) / Double(ws.count)
        switch (ws.count, rare) {
        case (..<8, ..<0.05):   return 1
        case (..<12, ..<0.10):  return 2
        case (..<16, ..<0.15):  return 3
        case (..<20, ..<0.25):  return 4
        default:                return 5
        }
    }

    // MARK: WAV（16k 单声道 16bit）
    //
    // 自己写头，不用 AVAudioFile：就 44 个字节的事，省一层格式转换和一堆可失败点。

    func writeWav(_ pcm: [Float], to url: URL) throws {
        var d = Data()
        let n = pcm.count
        let byteRate = Int(sr) * 2
        func le32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func le16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); le32(36 + n * 2)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); le32(16); le16(1); le16(1)
        le32(Int(sr)); le32(byteRate); le16(2); le16(16)
        d.append(contentsOf: Array("data".utf8)); le32(n * 2)
        var body = Data(capacity: n * 2)
        for x in pcm {
            let v = Int16(max(-1, min(1, x)) * 32767)
            withUnsafeBytes(of: v.littleEndian) { body.append(contentsOf: $0) }
        }
        d.append(body)
        try d.write(to: url)
    }
}
