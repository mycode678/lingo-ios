import Foundation

/// YouTube 的**字幕**部分。视频本身我们一个字节都不碰。
///
/// 用户原话：
/// > 不要youtube的音视频，只提供给用户一个词级跟随的界面，
/// > 播放/下载视频都在用户自己的手机和网络上
/// > 你研究一下 每日英语听力 是怎么做到的？按理说技术不是难题，他能做到，你肯定也能。
///
/// **研究结论**：它不需要音频也能做到词级跟随，靠的是
/// **YouTube 自动生成的字幕本身就带词级时间戳**。
/// 自动字幕拿 `fmt=json3` 取回来长这样：
/// ```json
/// {"events":[{"tStartMs":1200,"dDurationMs":2100,
///             "segs":[{"utf8":"Peppa","tOffsetMs":0},
///                     {"utf8":" and","tOffsetMs":320}, …]}]}
/// ```
/// 每个 `seg` 就是一个词，`tOffsetMs` 是它相对这条字幕开头的毫秒偏移 ——
/// 词级跟随要的东西已经在里面了，不用对齐、不用下载音频。
///
/// 那"AI 精校字幕要等两分钟"是怎么回事？那是**人工上传的字幕**（或者翻译轨）——
/// 那种只有整句时间，没有词级偏移。这时只能靠把整句按词的长度摊开来估，
/// 所以「跟随不是太准」。它那个「精校」多半就是拿音频重新对齐一遍，所以要等。
///
/// 我们的两种模式（用户已认可「走两种模式」）：
/// - **词级**：字幕自带词级时间戳（自动字幕）→ 秒开，准
/// - **估算**：只有整句时间 → 按词长摊开，会有偏差，界面上如实说明
///
/// 所有请求都从**用户自己的手机、用户自己的网络**发出去，服务器不参与。
enum YouTube {

    struct Word: Equatable {
        var text: String
        var start: Double
        var end: Double
    }

    struct Cue: Identifiable, Equatable {
        var id: Int
        var start: Double
        var end: Double
        var text: String
        var words: [Word]
    }

    struct Track: Equatable {
        var cues: [Cue]
        /// true = 字幕自带词级时间戳；false = 我们按词长估的
        var wordLevel: Bool
    }

    enum Err: LocalizedError {
        case badLink, noCaptions, network(String)
        var errorDescription: String? {
            switch self {
            case .badLink:      return "这不像一个 YouTube 链接"
            case .noCaptions:   return "这个视频没有英文字幕 —— 换一个带字幕的试试"
            case .network(let m): return "拿不到字幕：\(m)"
            }
        }
    }

    /// 从各种形式的链接里抠出视频 id
    static func videoID(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count == 11, t.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) {
            return t
        }
        guard let u = URLComponents(string: t) else { return nil }
        if let v = u.queryItems?.first(where: { $0.name == "v" })?.value { return v }
        // youtu.be/XXXX、/shorts/XXXX、/embed/XXXX
        let parts = u.path.split(separator: "/").map(String.init)
        if let last = parts.last, last.count == 11 { return last }
        return nil
    }

    // MARK: 取字幕

    /// 拿这个视频的英文字幕。优先自动字幕（它才有词级时间戳）。
    static func captions(_ videoID: String) async throws -> Track {
        let list = try await trackList(videoID)
        guard !list.isEmpty else { throw Err.noCaptions }
        // 挑轨：先英文自动字幕（asr），再英文人工字幕，再任意英文
        let pick = list.first { $0.lang.hasPrefix("en") && $0.asr }
            ?? list.first { $0.lang.hasPrefix("en") }
            ?? list[0]
        return try await fetch(pick.url)
    }

    private struct TrackInfo { var lang: String; var url: String; var asr: Bool }

    /// 字幕轨的地址藏在观看页的 JSON 里。**这是会变的东西** ——
    /// YouTube 改了页面结构这里就抓不到，所以失败要给一句人话，不能白屏。
    private static func trackList(_ id: String) async throws -> [TrackInfo] {
        guard let u = URL(string: "https://www.youtube.com/watch?v=\(id)&hl=en") else {
            throw Err.badLink
        }
        var r = URLRequest(url: u)
        // 不带这个头拿回来的是精简版页面，里面没有字幕轨信息
        r.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                   + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                   forHTTPHeaderField: "User-Agent")
        r.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        let (d, _) = try await URLSession.shared.data(for: r)
        let html = String(decoding: d, as: UTF8.self)
        guard let range = html.range(of: "\"captionTracks\":") else { throw Err.noCaptions }
        // 从 [ 开始按括号配平截出那个数组
        let rest = html[range.upperBound...]
        guard let open = rest.firstIndex(of: "[") else { throw Err.noCaptions }
        var depth = 0
        var end = open
        for i in rest[open...].indices {
            if rest[i] == "[" { depth += 1 }
            if rest[i] == "]" { depth -= 1; if depth == 0 { end = i; break } }
        }
        let json = String(rest[open...end])
        guard let arr = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]]
        else { throw Err.noCaptions }
        return arr.compactMap { t in
            guard var url = t["baseUrl"] as? String else { return nil }
            url = url.replacingOccurrences(of: "\\u0026", with: "&")
            let lang = (t["languageCode"] as? String) ?? ""
            let asr = (t["kind"] as? String) == "asr"
            return TrackInfo(lang: lang, url: url, asr: asr)
        }
    }

    private static func fetch(_ base: String) async throws -> Track {
        guard let u = URL(string: base + "&fmt=json3") else { throw Err.noCaptions }
        do {
            let (d, _) = try await URLSession.shared.data(from: u)
            return try parseJSON3(d)
        } catch let e as Err {
            throw e
        } catch {
            throw Err.network(error.localizedDescription)
        }
    }

    /// 解析 json3。**这是整件事的核心**：`segs[].tOffsetMs` 就是词级时间戳。
    static func parseJSON3(_ data: Data) throws -> Track {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let events = root["events"] as? [[String: Any]] else { throw Err.noCaptions }

        var cues: [Cue] = []
        var anyWordLevel = false
        for e in events {
            guard let segs = e["segs"] as? [[String: Any]] else { continue }
            let start = ((e["tStartMs"] as? Double) ?? 0) / 1000
            let dur = ((e["dDurationMs"] as? Double) ?? 0) / 1000
            var words: [Word] = []
            for (i, s) in segs.enumerated() {
                let raw = (s["utf8"] as? String) ?? ""
                let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty, t != "\n" else { continue }
                let off = ((s["tOffsetMs"] as? Double) ?? 0) / 1000
                if off > 0 { anyWordLevel = true }
                // 结束时间用下一个词的开始；最后一个用整条的结束
                var next = start + dur
                if i + 1 < segs.count, let n = segs[i + 1]["tOffsetMs"] as? Double {
                    next = start + n / 1000
                }
                words.append(Word(text: t, start: start + off, end: max(start + off + 0.05, next)))
            }
            guard !words.isEmpty else { continue }
            let text = words.map(\.text).joined(separator: " ")
            cues.append(Cue(id: cues.count, start: start,
                            end: max(start + dur, words.last!.end), text: text, words: words))
        }
        guard !cues.isEmpty else { throw Err.noCaptions }
        if !anyWordLevel { cues = spread(cues) }
        return Track(cues: cues, wordLevel: anyWordLevel)
    }

    /// 没有词级时间戳时的兜底：按**词的字母数**把整条摊开。
    /// 长的词占的时间本来就长，比平均分要准一点，但仍然是估的 ——
    /// 界面上必须如实说「这是估的」，不能让用户以为对不上是他自己的问题。
    static func spread(_ cues: [Cue]) -> [Cue] {
        cues.map { c in
            let total = max(0.2, c.end - c.start)
            let weights = c.words.map { Double(max(1, $0.text.count)) }
            let sum = weights.reduce(0, +)
            var t = c.start
            var out: [Word] = []
            for (i, w) in c.words.enumerated() {
                let d = total * weights[i] / sum
                out.append(Word(text: w.text, start: t, end: t + d))
                t += d
            }
            var x = c
            x.words = out
            return x
        }
    }

    /// 当前时间落在哪个词上（二分，字幕几千个词也不卡）
    static func wordIndex(_ words: [Word], at t: Double) -> Int? {
        guard !words.isEmpty else { return nil }
        var lo = 0, hi = words.count - 1, found: Int?
        while lo <= hi {
            let m = (lo + hi) / 2
            if words[m].start > t { hi = m - 1 }
            else { found = m; lo = m + 1 }
        }
        guard let f = found, t <= words[f].end + 0.35 else { return nil }
        return f
    }
}
