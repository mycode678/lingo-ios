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

    /// 一次听写多长。SFSpeechRecognizer 对单次时长有限制，切块最稳；
    /// 45 秒是实测下来又快又不容易被截断的长度。
    private let chunkSeconds = 45.0
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
        var t = 0.0
        while t < total {
            let end = min(total, t + chunkSeconds)
            let chunk = Array(pcm[Int(t * sr)..<Int(end * sr)])
            progress?("听写第 \(Int(t / chunkSeconds) + 1) 段", 0.05 + 0.6 * (t / total))

            if let text = try? await transcribe(chunk), !text.isEmpty {
                progress?("对齐第 \(Int(t / chunkSeconds) + 1) 段", 0.05 + 0.6 * (end / total))
                // **整块只对齐一次**，再按句子把词切开。
                // 曾经是每句拿整块去对一次 —— 那一句会被摊到整整 45 秒上，
                // 时间戳全错，切出来的音频跟文字对不上，整个导入就废了。
                let parts = split(text)
                if let all = try? await Aligner.shared.align(pcm: chunk, text: text), !all.isEmpty {
                    // 块内时间轴 → 整段时间轴
                    var words = all.map {
                        Aligner.Word(text: $0.text, start: $0.start + t,
                                     end: $0.end + t, score: $0.score)
                    }
                    for p in parts {
                        let n = p.split(separator: " ").count
                        guard words.count >= max(2, n / 2) else { break }
                        // 对齐可能少认几个词，按句子的词数依次取，取不满就把剩下的都给它
                        let take = min(n, words.count)
                        sentences.append((p, Array(words.prefix(take))))
                        words.removeFirst(take)
                    }
                }
            }
            t = end
        }
        return sentences
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

    private func transcribe(_ chunk: [Float]) async throws -> String {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("imp-\(UUID().uuidString).wav")
        try writeWav(chunk, to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        return try await Speech.shared.transcribe(tmp)
    }

    /// 分句。**上限跟难度闸对齐（18 词）** —— 分出来的句子太长，
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
