import Foundation
import SwiftUI

/// 全局状态：当前查的词、它的例句清单、当前练哪一句、学习进度。
/// 跟网页版一个思路 —— 一切以音频地址 src 为准，换设备也对得上。
@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var word = ""
    @Published var items: [Api.Sentence] = []
    @Published var prog: [String: Api.Prog] = [:]
    @Published var index = 0
    @Published var entryHTML = ""
    @Published var inLib = false
    @Published var loading = false
    @Published var error: String?
    @Published var hist: [Api.HistWord] = []
    @Published var dueCount = 0
    @Published var related: [String] = []          // 含这个词的其它词条

    var current: Api.Sentence? { items.indices.contains(index) ? items[index] : nil }

    /// 把一个**材料包**装进精听台。
    ///
    /// 这是之前漏掉的一环：包做好了、训练那七个练法也用上了，
    /// 可精听台还只认"查词 → 例句"那条老路 —— 用户下完包发现没地方练，
    /// 界面上一个入口都没有。
    @MainActor
    func loadPack(_ packId: String, name: String, catalog: CatalogService = .shared) {
        let list = catalog.sentences(packId, limit: 400)
        guard !list.isEmpty else { return }
        word = name
        items = list.map {
            Api.Sentence(src: $0.id, en: $0.en, cn: $0.cn,
                         grp: name, gnum: nil, dfe: nil, dcn: nil,
                         tag: nil, kind: "pack", bold: nil, packId: packId)
        }
        index = 0
        prog = [:]
        inLib = true
    }

    func look(_ w: String) async {
        let w = w.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !w.isEmpty else { return }
        if Demo.on {
            word = Demo.word; items = Demo.sentences; prog = [:]; inLib = true
            related = ["excuse me", "excuse yourself", "a poor excuse for something",
                       "make your excuses", "pardon/excuse my French"]
            entryHTML = "<div class=\"entry\"><span class=\"pos\">verb</span> "
                      + "<span class=\"sensenum\">1</span> "
                      + "<span class=\"def\">used when you want to get someone's attention politely</span>"
                      + "<span class=\"defcn\">劳驾</span></div>"
            index = 0
            return
        }
        loading = true; error = nil
        defer { loading = false }
        do {
            async let e = Api.lookup(w)
            async let s = Api.sentences(w)
            let (entry, sent) = try await (e, s)
            word = entry.word ?? w
            entryHTML = entry.html ?? ""
            items = sent.items
            prog = sent.prog
            inLib = sent.inlib ?? false
            index = items.firstIndex { $0.kind == "sent" } ?? 0
            await Api.histAdd(word)
            Task { related = (try? await Api.related(word)) ?? [] }
            Task { hist = (try? await Api.hist()) ?? hist }
            // 出门前用得上：把这个词的音频悄悄下到本地
            Task.detached { await Cache.shared.prefetch(sent.items.map(\.src)) }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func refreshProgress() async {
        guard !word.isEmpty else { return }
        if let s = try? await Api.sentences(word) { prog = s.prog; inLib = s.inlib ?? false }
        if let c = try? await Api.counts() { dueCount = c.due }
    }

    func addWord() async {
        guard !word.isEmpty else { return }
        try? await Api.addWord(word)
        inLib = true
        await refreshProgress()
    }

    func loadDueCount() async {
        // 本机的数说了算：没网也要有数。服务器那份只在本机一条都没有时兜底
        // （比如刚装上、还没搬过家）。
        await PracticeService.shared.seedFromServerIfNeeded()
        let local = PracticeService.shared.dueCount()
        if local > 0 { dueCount = local; return }
        if let c = try? await Api.counts() { dueCount = c.due }
    }
    func loadHist() async {
        hist = (try? await Api.hist()) ?? []
    }

    /// 当前这句的元信息，打分/收藏时一起发给服务端
    func meta(_ s: Api.Sentence?) -> [String: Any] {
        guard let s else { return [:] }
        return ["word": word, "en": s.en, "cn": s.cn ?? "", "grp": s.grp ?? "",
                "tag": s.tag ?? "", "kind": s.kind ?? "sent"]
    }
}

/// 精练台的状态机：装载音频、词边界、难点、选区、小句切分。
@MainActor
final class DrillModel: ObservableObject {
    @Published var words: [Api.Word] = []
    @Published var marks: [Api.Mark] = []
    @Published var chunks: [(Int, Int)] = []          // 小句 = 词的下标区间
    @Published var selection: ClosedRange<Double>?
    @Published var view: (Double, Double) = (0, 1)    // 波形视窗
    @Published var snap = true
    @Published var loading = false
    @Published var note = ""
    /// 记住每句自己圈过的那一小段：切走再回来还是练它，而不是从整句重来
    @Published var rememberSelection = true
    private var src = ""

    func load(_ s: Api.Sentence) async {
        guard src != s.src else { return }
        src = s.src
        let saved = rememberSelection ? Self.savedSelection(s.src) : nil
        loading = true; note = ""
        selection = nil; words = []; marks = []; chunks = []
        // **真包优先于演示数据**。这一句排在 Demo 前面是有代价换来的：
        // 原来 Demo 分支在前，只要带 -demo 就全是假句子假波形，
        // "装好的包能不能在精听台练起来"这条路一条测试都覆盖不到 ——
        // 结果我这边闸门全绿，用户下完包却发现没地方练。
        if let pid = s.packId {
            await loadFromPack(s, pid, saved: saved)
            return
        }
        if Demo.on {
            try? await Player.shared.load(src: s.src)
            view = (0, Player.shared.duration)
            let i = Int(s.src.split(separator: "/").last?.split(separator: ".").first ?? "1") ?? 1
            words = Self.padOnsets(Demo.words[min(max(0, i - 1), Demo.words.count - 1)],
                                   duration: Player.shared.duration)
            chunks = Self.cutChunks(words)
            marks = []
            if Demo.preselect, chunks.count > 1 {
                let c = chunks[1]
                selection = words[c.0].s...words[c.1].e
                Player.shared.setSegment(selection, playNow: false)
            }
            loading = false
            return
        }
        do {
            try await Player.shared.load(src: s.src)
            view = (0, Player.shared.duration)
            // 难点从本机读。本机没有才去服务器要一次并落地（老账号搬家）。
            let local = PracticeService.shared.marks(s.src)
            if !local.isEmpty {
                marks = local.map { .init(id: nil, s: $0.0, e: $0.1) }
            } else {
                marks = (try? await Api.marks(s.src)) ?? []
                if !marks.isEmpty {
                    PracticeService.shared.setMarks(s.src, marks.map { ($0.s, $0.e) })
                }
            }
            do {
                words = Self.padOnsets(try await Api.align(s.src),
                                       duration: Player.shared.duration)
                chunks = Self.cutChunks(words)
                if words.isEmpty { note = "服务器还没切好这句的词" }
            if let sv = saved, sv.upperBound <= Player.shared.duration + 0.01 {
                selection = sv
                Player.shared.setSegment(sv, playNow: false)
                // 不用写"沿用上次圈的那一段"：选区就画在波形上，一眼看得见，
                // 多这一行字反而占地方（横屏尤其）
            }
            } catch {
                // 出了问题要说清是哪一步，不然只能靠猜（第一版就吃了这个亏）
                note = "取词边界失败：\(error.localizedDescription)"
            }
        } catch {
            note = "音频载入失败：\(error.localizedDescription)"
        }
        loading = false
    }

    func setSelection(a: Double?, b: Double?, play: Bool) {
        if let a, let b, b - a > 0.02 {
            selection = a...b
            Player.shared.setSegment(a...b, playNow: play)
        } else {
            selection = nil
            Player.shared.setSegment(nil, playNow: false)
        }
        Self.saveSelection(src, selection)
    }

    // 选区记在本地（按音频地址存），重开 App 也还在
    private static func key(_ src: String) -> String { "sel." + src }
    static func savedSelection(_ src: String) -> ClosedRange<Double>? {
        guard let a = UserDefaults.standard.array(forKey: key(src)) as? [Double],
              a.count == 2, a[1] > a[0] else { return nil }
        return a[0]...a[1]
    }
    static func saveSelection(_ src: String, _ r: ClosedRange<Double>?) {
        guard !src.isEmpty else { return }
        if let r { UserDefaults.standard.set([r.lowerBound, r.upperBound], forKey: key(src)) }
        else { UserDefaults.standard.removeObject(forKey: key(src)) }
    }
    func selectChunk(_ i: Int) {
        guard chunks.indices.contains(i), !words.isEmpty else { return }
        let (a, b) = chunks[i]
        setSelection(a: words[a].s, b: words[b].e, play: true)
    }
    func selectWord(_ i: Int) {
        guard words.indices.contains(i) else { return }
        setSelection(a: words[i].s, b: words[i].e, play: true)
    }
    func selectWords(_ i: Int, _ j: Int) {
        guard words.indices.contains(i), words.indices.contains(j) else { return }
        setSelection(a: words[min(i,j)].s, b: words[max(i,j)].e, play: true)
    }
    func nudge(_ which: Character, _ dt: Double) {
        guard let s = selection else { return }
        let dur = Player.shared.duration
        let a = which == "a" ? min(max(0, s.lowerBound + dt), s.upperBound - 0.05) : s.lowerBound
        let b = which == "b" ? max(min(dur, s.upperBound + dt), s.lowerBound + 0.05) : s.upperBound
        setSelection(a: a, b: b, play: true)
    }
    func setEdgeAtHead(_ which: Character) {
        let t = Player.shared.position, dur = Player.shared.duration
        var a = selection?.lowerBound ?? max(0, t - 0.5)
        var b = selection?.upperBound ?? min(dur, t + 0.5)
        if which == "a" { a = min(t, b - 0.05) } else { b = max(t, a + 0.05) }
        setSelection(a: a, b: b, play: true)
    }
    func zoomToSelection() {
        guard let s = selection else { return }
        let pad = (s.upperBound - s.lowerBound) * 0.08
        view = (max(0, s.lowerBound - pad), min(Player.shared.duration, s.upperBound + pad))
    }
    func zoomAll() { view = (0, Player.shared.duration) }

    /// 标难点：把当前选区（没选区就是播放头前后 0.2 秒）记一笔
    func toggleMark() async {
        let dur = Player.shared.duration
        let a = selection?.lowerBound ?? max(0, Player.shared.position - 0.2)
        let b = selection?.upperBound ?? min(dur, Player.shared.position + 0.2)
        if let hit = marks.firstIndex(where: { min($0.e, b) - max($0.s, a) > (b - a) * 0.4 }) {
            marks.remove(at: hit)
        } else {
            marks.append(.init(id: nil, s: a, e: b))
            marks.sort { $0.s < $1.s }
        }
        // 本机说了算，服务器只是顺手备份
        PracticeService.shared.setMarks(src, marks.map { ($0.s, $0.e) })
        try? await Api.setMarks(src, marks)
    }
    func nextMark() {
        guard !marks.isEmpty else { return }
        let t = Player.shared.position
        let m = marks.first { $0.s > t + 0.02 } ?? marks[0]
        setSelection(a: m.s, b: m.e, play: true)
    }

    /// 按停顿把句子切成小句：词间空隙 ≥180ms 断一刀，标点算半个停顿；
    /// 太短的并给邻居，太长的从最大的停顿处再切。听不懂整句时先抠一个小句最有效。
    /// 把对齐给的词边界往前挪一点，补回被吃掉的起音。
    ///
    /// **为什么要补**：CTC 对齐天生把词的起点标晚 —— 模型要"听清楚了"才认定
    /// 这个词开始，而 the / a / to / of 这些虚词的起音又轻又短（the 的 /ð/），
    /// 模型要等到元音才敢确认。照它给的时间播就缺一小截，听起来像"没读 the"。
    ///
    /// 补多少：往前借前一个词留下的那段间隙（那本来就是这个词的起音，
    /// 借了不会吃到上一个词），最多 90 毫秒、且不超过间隙的八成。
    /// 在这儿一次改掉，后面波形高亮、小句、吸附、播放就全都一致了。
    /// 包里的句子怎么装：本机音频 + 包里预先算好的词边界
    @MainActor
    private func loadFromPack(_ s: Api.Sentence, _ packId: String,
                              saved: ClosedRange<Double>?) async {
        defer { loading = false }
        let cat = CatalogService.shared
        guard let sent = cat.sentences(packId, limit: 400).first(where: { $0.id == s.src }) else {
            note = "这一句在包里找不到了 —— 包可能被删了，去材料库重新装一下"
            return
        }
        do {
            try Player.shared.load(local: cat.audioURL(packId, s.src) ?? sent.audio)
        } catch {
            note = "音频读不出来：\(error.localizedDescription)"
            return
        }
        view = (0, Player.shared.duration)
        // 测试要能自己判"装进播放器的是不是这一句" —— 光靠我看截图不算数。
        // 差 0.25 秒以上就是装错了音频（这次翻车就是装成了上一句的 2.8 秒）。
        if Demo.on {
            let ok = abs(Player.shared.duration - sent.dur) < 0.25
            note = ok ? "AUDIO-OK" : String(format: "AUDIO-BAD 该 %.2fs 实际 %.2fs",
                                            sent.dur, Player.shared.duration)
        }
        words = Self.padOnsets(cat.words(packId, s.src).map { Api.Word(w: $0.w, s: $0.s, e: $0.e) },
                               duration: Player.shared.duration)
        chunks = Self.cutChunks(words)
        marks = PracticeService.shared.marks(s.src).map { .init(id: nil, s: $0.0, e: $0.1) }
        if let sv = saved, sv.upperBound <= Player.shared.duration + 0.01 {
            selection = sv
            Player.shared.setSegment(sv, playNow: false)
        }
        if words.isEmpty { note = "这一句包里没带词边界" }
    }

    static func padOnsets(_ ws: [Api.Word], duration: Double) -> [Api.Word] {
        guard ws.count > 1 else { return ws }
        var out = ws
        for i in out.indices {
            let gapBefore = i > 0 ? max(0, out[i].s - ws[i - 1].e) : out[i].s
            let lead = min(0.09, gapBefore * 0.8)
            out[i].s = max(0, out[i].s - lead)
            let gapAfter = i < ws.count - 1 ? max(0, ws[i + 1].s - out[i].e)
                                            : max(0, duration - out[i].e)
            out[i].e = min(duration > 0 ? duration : out[i].e + 1,
                           out[i].e + min(0.04, gapAfter * 0.5))
        }
        return out
    }

    static func cutChunks(_ words: [Api.Word]) -> [(Int, Int)] {
        guard words.count >= 3 else { return words.isEmpty ? [] : [(0, words.count - 1)] }
        var gap: [Double] = []
        for i in 0..<(words.count - 1) {
            let punct = words[i].w.range(of: "[,.;:!?—]$", options: .regularExpression) != nil
            gap.append(words[i+1].s - words[i].e + (punct ? 0.12 : 0))
        }
        var out: [(Int, Int)] = []
        var last = 0
        for (i, g) in gap.enumerated() where g >= 0.18 { out.append((last, i)); last = i + 1 }
        out.append((last, words.count - 1))
        var k = 0
        while k < out.count {                       // 单词成句的并进邻居
            if out[k].1 - out[k].0 + 1 >= 2 || out.count == 1 { k += 1; continue }
            if k > 0 { out[k-1].1 = out[k].1; out.remove(at: k); k -= 1 }
            else { out[1].0 = out[0].0; out.remove(at: 0) }
        }
        k = 0
        while k < out.count {                       // 太长的再切一刀
            let (i, j) = out[k]
            if j - i + 1 <= 7 { k += 1; continue }
            var bi = -1, bg = -1.0
            for x in (i+1)..<max(i+2, j-1) where x < gap.count && gap[x] > bg { bg = gap[x]; bi = x }
            if bi < 0 { k += 1; continue }
            out.replaceSubrange(k...k, with: [(i, bi), (bi + 1, j)])
        }
        return out
    }
}
