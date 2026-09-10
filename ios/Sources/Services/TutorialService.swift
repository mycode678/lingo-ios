import Foundation

/// 教程要的两件事：**给一个词组，找一句真的例句**；**把它（或它的一小段）放出来**。
///
/// 为什么不预录教程音频：预录的是我念的，不是母语者念的，讲"母语者怎么念"就站不住；
/// 而且预录的音频跟用户在练的材料无关，听完回到精听台又是另一套声音。
/// 拿他自己装的材料举例，理论和练习是同一批声音，立刻能对上。
@MainActor
final class TutorialService: ObservableObject {
    static let shared = TutorialService(catalog: .shared, player: .shared)

    private let catalog: CatalogService
    private let player: Player
    init(catalog: CatalogService, player: Player) {
        self.catalog = catalog; self.player = player
    }

    private var cache: [String: TrainService.Item] = [:]

    /// 找一句含这个词组、而且**够简单**的例句。
    /// 难度也要过闸 —— 教程里举一句谁也听不懂的例子等于帮倒忙。
    func find(_ phrase: String) -> TrainService.Item? {
        if let c = cache[phrase] { return c }
        let want = phrase.lowercased()
        // 同上：装了包就到真材料里找例子，演示数据只兜底
        if catalog.packs().isEmpty {
            guard let i = Demo.sentences.firstIndex(where: { $0.en.lowercased().contains(want) })
            else { return nil }
            let s = Demo.sentences[i]
            let ws = Demo.words[i].map { TrainKit.Word($0.w, $0.s, $0.e) }
            let it = TrainService.Item(id: s.src, en: s.en, cn: s.cn ?? "", audio: nil,
                                       words: ws, analysis: TrainKit.analyze(ws))
            cache[phrase] = it
            return it
        }
        for p in catalog.packs() {
            for s in catalog.sentences(p.id, limit: 400)
            where s.en.lowercased().contains(want) && TrainKit.isEasyEnough(s.en) {
                let ws = catalog.words(p.id, s.id).map { TrainKit.Word($0.w, $0.s, $0.e) }
                guard ws.count >= 3 else { continue }
                let it = TrainService.Item(id: s.id, en: s.en, cn: s.cn, audio: s.audio,
                                           words: ws, analysis: TrainKit.analyze(ws))
                cache[phrase] = it
                return it
            }
        }
        return nil
    }

    func play(_ it: TrainService.Item) {
        load(it) { [weak self] in
            guard let self else { return }
            self.player.segment = nil
            self.player.play(from: it.words.first?.s ?? 0)
        }
    }

    /// 只放那个词组那几十毫秒 —— "the 只有 80 毫秒"这种话，
    /// 单独放出来听一遍比讲十句都管用。
    func playPhrase(_ it: TrainService.Item, _ phrase: String) {
        let want = TrainKit.tokenize(phrase)
        guard !want.isEmpty else { return play(it) }
        let words = it.words.map { TrainKit.norm($0.text) }
        var at: Int?
        for i in 0...(max(0, words.count - want.count)) where i + want.count <= words.count {
            if Array(words[i..<(i + want.count)]) == want { at = i; break }
        }
        guard let k = at else { return play(it) }
        let a = max(0, it.words[k].s - 0.05)
        let b = it.words[k + want.count - 1].e + 0.05
        load(it) { [weak self] in
            guard let self else { return }
            // 慢一点放：几十毫秒的东西按原速放完了人还没反应过来
            self.player.rate = 0.7
            self.player.segment = a...max(a + 0.05, b)
            self.player.play(from: a)
        }
    }

    func stop() {
        player.pause()
        player.rate = 1.0
        player.segment = nil
    }

    private func load(_ it: TrainService.Item, then go: @escaping () -> Void) {
        player.claim()
        player.rate = 1.0
        Task { @MainActor in
            if let u = it.audio {
                try? player.load(local: u)          // 真包：本机文件
            } else {
                try? await player.load(src: it.id)  // 演示数据兜底
            }
            go()
        }
    }
}
