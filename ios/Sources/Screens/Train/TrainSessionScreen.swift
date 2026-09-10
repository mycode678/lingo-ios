import SwiftUI

/// 一轮训练：出题 → 答 → 判 → 下一题。七个练法共用这一个壳子，
/// 只有中间那块题面各不相同。
///
/// 壳子负责的事（各练法不用各写一遍）：装音频、播放、计分、记账、进度条、收尾。
@MainActor
final class TrainSessionModel: ObservableObject {
    let mode: TrainMode
    private let svc: TrainService
    private let player: Player

    @Published var items: [TrainService.Item] = []
    @Published var idx = 0
    @Published var revealed = false          // 这道题是不是已经对过答案
    @Published var right = 0                 // 这一轮答对几题
    @Published var loading = true
    /// 没题可出时的那句人话（额度用完 / 还没装材料）
    @Published var blockedNote: String?

    // 各练法的作答状态
    @Published var blanks: [Int: String] = [:]
    @Published var cuts: Set<Int> = []       // 意群断句：用户断在哪几个词后面
    @Published var typed = ""                // 整句听写
    @Published var pickedOption: String?     // 听音辨词
    @Published var ladderLevel = 0

    private var startedAt = Date()

    init(mode: TrainMode, svc: TrainService = .shared, player: Player = .shared) {
        self.mode = mode; self.svc = svc; self.player = player
    }

    var item: TrainService.Item? { idx < items.count ? items[idx] : nil }
    var finished: Bool { !loading && (items.isEmpty || idx >= items.count) }
    var progress: String { items.isEmpty ? "" : "\(min(idx + 1, items.count))/\(items.count)" }

    func load() {
        items = svc.items(for: mode)
        blockedNote = svc.blocked
        loading = false
        // 播放器是全局的：进来先申明自己要什么，免得把精听台的循环和选区带进来
        player.claim()
        prepare()
    }

    /// 装当前这句的音频。装不上不拦着答题 —— 没声音也还能看文本对答案，
    /// 总比整屏卡死强。
    func prepare() {
        guard let it = item else { return }
        startedAt = Date()
        // 档位要**先读出来再定倍速**：反过来的话这一句放的是上一句的档位
        if mode == .ladder { ladderLevel = svc.ladderLevel(it.id) }
        Task { @MainActor in
            // 真包的句子带本机音频文件；没有才退回演示数据那条路。
            // 原来先判 Demo.on，于是 -demo 下永远放合成波形 ——
            // 练法界面看着有题，放出来的却不是这句话。
            if let u = it.audio {
                try? player.load(local: u)
            } else {
                try? await player.load(src: it.id)
            }
            player.rate = mode == .ladder ? SpeedLadder.rates[ladderLevel] : 1.0
            player.segment = nil
        }
    }

    // MARK: 放音

    func playAll() {
        guard let it = item else { return }
        player.segment = nil
        if mode == .stress && !revealed {
            player.playDimmed(StressQuiz.plan(it.analysis).map { ($0.range, $0.volume) })
        } else {
            player.play(from: it.words.first?.s ?? 0)
        }
    }

    func playWord(_ i: Int) {
        guard let it = item, i < it.words.count else { return }
        let w = it.words[i]
        player.segment = max(0, w.s - 0.04)...(w.e + 0.06)
        player.play(from: max(0, w.s - 0.04))
    }

    func stop() { player.pause() }

    // MARK: 判卷

    /// 这道题的得分（对几个 / 共几个）
    func grade() -> (right: Int, total: Int) {
        guard let it = item else { return (0, 0) }
        switch mode {
        case .blank:
            return BlankQuiz.make(it.analysis).score(blanks)
        case .group:
            let r = GroupQuiz.make(it.analysis).grade(cuts)
            // 多断的也算错，否则全点满就是满分
            return (max(0, r.right - r.extra.count), max(1, r.total))
        case .dictation:
            let r = DictationQuiz.make(it.analysis).grade(typed)
            return (r.right, max(1, r.total))
        case .wordId:
            let q = wordQuiz()
            return (pickedOption != nil && pickedOption == q?.answer ? 1 : 0, 1)
        case .stress, .ladder, .shadow:
            return (1, 1)          // 这三个由用户自评（听懂了 / 没听懂）
        }
    }

    /// 听音辨词的题面：从这句里挑一个实词，干扰项从同一批材料里取
    func wordQuiz() -> WordIdQuiz? {
        guard let it = item else { return nil }
        guard let k = it.words.indices.first(where: {
            !TrainKit.isFunction(it.words[$0].text) && it.words[$0].dur > 0.12
        }) else { return nil }
        let pool = items.flatMap { $0.words.map(\.text) }
        return WordIdQuiz.make(word: it.words[k].text,
                               range: it.words[k].s...it.words[k].e,
                               pool: pool, seed: UInt64(abs(it.id.hashValue % 100000) + 1))
    }

    func reveal(selfRight: Bool? = nil) {
        guard let it = item, !revealed else { return }
        revealed = true
        let g = selfRight.map { ($0 ? 1 : 0, 1) } ?? grade()
        if g.0 == g.1 { right += 1 }
        svc.record(mode, sentId: it.id, right: g.0, total: g.1,
                   secs: Date().timeIntervalSince(startedAt))
        if mode == .ladder {
            let next = SpeedLadder.next(from: ladderLevel, passed: selfRight ?? true)
            svc.setLadderLevel(it.id, next)
            ladderLevel = next
        }
    }

    func next() {
        player.pause()
        idx += 1
        revealed = false
        blanks = [:]; cuts = []; typed = ""; pickedOption = nil
        prepare()
    }
}

// MARK: - 界面

struct TrainSessionScreen: View {
    let mode: TrainMode
    var onClose: () -> Void
    @StateObject private var m: TrainSessionModel
    @EnvironmentObject var player: Player
    @FocusState private var typing: Bool

    init(mode: TrainMode, onClose: @escaping () -> Void) {
        self.mode = mode
        self.onClose = onClose
        _m = StateObject(wrappedValue: TrainSessionModel(mode: mode))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if m.loading {
                    Spacer(); ProgressView(); Spacer()
                } else if m.finished {
                    done
                } else {
                    // 题面垂直居中。原来钉在顶上，一道两行的填空题下面空掉四分之三屏。
                    //
                    // 第一版拿 GeometryReader 放在 .background 里测高度、再喂给 minHeight ——
                    // 值来得比首次渲染晚，用的还是初值，云端截图上题面照旧缩在顶上。
                    // 直接用 GeometryReader 包住内容区，minHeight 就是它自己的高度，
                    // 一次成型，不依赖任何"稍后才知道"的状态。
                    GeometryReader { g in
                        ScrollView {
                            question.padding(T.side)
                                .frame(maxWidth: .infinity, minHeight: g.size.height,
                                       alignment: .center)
                        }
                    }
                    controls                     // 高频动作钉在最下面（拇指区）
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("退出") { m.stop(); onClose() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if !m.items.isEmpty && !m.finished {
                        Text(m.progress).font(.system(size: T.f2)).monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onAppear { m.load() }
            .onDisappear { m.stop() }
        }
    }

    // MARK: 题面

    @ViewBuilder private var question: some View {
        if let it = m.item {
            VStack(alignment: .leading, spacing: T.s4) {
                Text(mode.cure).font(.system(size: T.f1)).foregroundStyle(.secondary)
                switch mode {
                case .blank:     blankView(it)
                case .group:     groupView(it)
                case .stress:    stressView(it)
                case .ladder:    ladderView(it)
                case .wordId:    wordView(it)
                case .dictation: dictationView(it)
                case .shadow:    shadowView(it)
                }
                if m.revealed {
                    VStack(alignment: .leading, spacing: T.s2) {
                        Text(it.en).font(.system(size: T.f3, weight: .medium))
                        if !it.cn.isEmpty {
                            Text(it.cn).font(.system(size: T.f2)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(T.s3).frame(maxWidth: .infinity, alignment: .leading).cardStyle()
                    .accessibilityIdentifier("train.answer")
                }
            }
        }
    }

    // ① 盲听填空
    @ViewBuilder private func blankView(_ it: TrainService.Item) -> some View {
        let q = BlankQuiz.make(it.analysis)
        let checked = m.revealed ? q.check(m.blanks) : [:]
        VStack(alignment: .leading, spacing: T.s3) {
            FlowRow(spacing: T.s2) {
                ForEach(it.words.indices, id: \.self) { i in
                    if q.blanks.contains(i) {
                        BlankSlot(text: Binding(
                            get: { m.blanks[i] ?? "" },
                            set: { m.blanks[i] = $0 }),
                            answer: it.words[i].text,
                            state: m.revealed ? (checked[i] == true ? .right : .wrong) : .idle)
                        .accessibilityIdentifier("train.blank.\(i)")
                    } else {
                        Text(it.words[i].text).font(.system(size: T.f4))
                    }
                }
            }
            Text("挖掉的都是母语者一带而过的词 —— 听不出来是正常的，多听几遍。")
                .font(.system(size: T.f1)).foregroundStyle(.secondary)
        }
        .padding(T.s3).frame(maxWidth: .infinity, alignment: .leading).cardStyle()
    }

    // ② 意群断句
    @ViewBuilder private func groupView(_ it: TrainService.Item) -> some View {
        let q = GroupQuiz.make(it.analysis)
        let r = m.revealed ? q.grade(m.cuts) : nil
        VStack(alignment: .leading, spacing: T.s3) {
            Text(m.revealed ? "母语者实际断在竖线处" : "点词与词之间的位置，标出你听到的停顿")
                .font(.system(size: T.f1)).foregroundStyle(.secondary)
            FlowRow(spacing: 2) {
                ForEach(it.words.indices, id: \.self) { i in
                    // 每个"词＋竖线"整体等高，且底部对齐 ——
                    // 原来词是文字高度、竖线是 34 点，两者混排时后面的词会被顶到
                    // 上一行的基线之上（真机截图上 finish 就浮起来了）。
                    HStack(alignment: .center, spacing: 2) {
                        Text(it.words[i].text).font(.system(size: T.f4))
                            .frame(height: 34)
                        if i < it.words.count - 1 {
                            let mine = m.cuts.contains(i)
                            let truth = q.answer.contains(i)
                            Button {
                                guard !m.revealed else { return }
                                if mine { m.cuts.remove(i) } else { m.cuts.insert(i) }
                            } label: {
                                Text("|")
                                    .font(.system(size: T.f4, weight: .bold))
                                    .frame(width: 20, height: 34)
                                    .foregroundStyle(cutColor(mine: mine, truth: truth))
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("train.cut.\(i)")
                        }
                    }
                }
            }
            if let r {
                Text("听出 \(r.hit.count) 处，漏 \(r.missed.count) 处"
                     + (r.extra.isEmpty ? "" : "，多断 \(r.extra.count) 处"))
                    .font(.system(size: T.f2)).monospacedDigit()
            }
        }
        .padding(T.s3).frame(maxWidth: .infinity, alignment: .leading).cardStyle()
    }

    private func cutColor(mine: Bool, truth: Bool) -> Color {
        guard m.revealed else { return mine ? Color.accentColor : Color.primary.opacity(0.12) }
        if truth && mine { return T.Score.good }
        if truth { return T.Score.ok }              // 漏掉的
        if mine { return T.Score.bad }              // 多断的
        return Color.primary.opacity(0.08)
    }

    // ③ 只听重读词
    @ViewBuilder private func stressView(_ it: TrainService.Item) -> some View {
        VStack(alignment: .leading, spacing: T.s3) {
            if m.revealed {
                Text("你听到的其实就这几个词：").font(.system(size: T.f1)).foregroundStyle(.secondary)
                Text(StressQuiz.heard(it.analysis).joined(separator: " · "))
                    .font(.system(size: T.f4, weight: .semibold))
                Text("看，不需要听清每个词也能懂 —— 母语者的耳朵抓的就是这些。")
                    .font(.system(size: T.f1)).foregroundStyle(.secondary)
            } else {
                Text("重读的词原样放，其余压到 20%。听完在心里把整句补出来。")
                    .font(.system(size: T.f2))
                Text(it.words.indices.map {
                    it.analysis.stressed.contains($0) ? it.words[$0].text : "···"
                }.joined(separator: " "))
                .font(.system(size: T.f4)).foregroundStyle(.secondary)
            }
        }
        .padding(T.s3).frame(maxWidth: .infinity, alignment: .leading).cardStyle()
    }

    // ④ 速度阶梯
    @ViewBuilder private func ladderView(_ it: TrainService.Item) -> some View {
        VStack(alignment: .leading, spacing: T.s3) {
            HStack(spacing: T.s2) {
                ForEach(SpeedLadder.rates.indices, id: \.self) { i in
                    Text(SpeedLadder.label(i))
                        .font(.system(size: T.f2, weight: i == m.ladderLevel ? .bold : .regular))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .background(i == m.ladderLevel ? Color.accentColor.opacity(0.16)
                                                       : Color.primary.opacity(0.05))
                        .foregroundStyle(i == m.ladderLevel ? Color.accentColor : .secondary)
                        .clipShape(RoundedRectangle(cornerRadius: T.ctl, style: .continuous))
                }
            }
            Text(m.revealed ? "听懂了就升一档，没听懂降一档 —— 卡在哪一档是你的听力速度上限。"
                            : "这一遍是 \(SpeedLadder.label(m.ladderLevel)) 速。听懂了吗？")
                .font(.system(size: T.f2)).foregroundStyle(.secondary)
        }
        .padding(T.s3).frame(maxWidth: .infinity, alignment: .leading).cardStyle()
    }

    // ⑤ 听音辨词
    @ViewBuilder private func wordView(_ it: TrainService.Item) -> some View {
        if let q = m.wordQuiz() {
            VStack(spacing: T.s2) {
                ForEach(q.options, id: \.self) { opt in
                    Button {
                        guard !m.revealed else { return }
                        m.pickedOption = opt
                        m.reveal()
                    } label: {
                        HStack {
                            Text(opt).font(.system(size: T.f4))
                            Spacer()
                            if m.revealed && opt == q.answer {
                                Image(systemName: "checkmark").foregroundStyle(T.Score.good)
                            } else if m.revealed && opt == m.pickedOption {
                                Image(systemName: "xmark").foregroundStyle(T.Score.bad)
                            }
                        }
                        .padding(T.s3).frame(maxWidth: .infinity, minHeight: T.hBig)
                        .cardStyle(m.revealed && opt == q.answer
                                   ? T.Score.good.opacity(0.12) : nil)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("train.option." + opt)
                }
            }
        } else {
            Text("这句里没有合适的词可考，跳过。").font(.system(size: T.f2)).foregroundStyle(.secondary)
        }
    }

    // ⑥ 整句听写
    @ViewBuilder private func dictationView(_ it: TrainService.Item) -> some View {
        VStack(alignment: .leading, spacing: T.s3) {
            if m.revealed {
                let r = DictationQuiz.make(it.analysis).grade(m.typed)
                FlowRow(spacing: T.s2) {
                    ForEach(r.tokens.indices, id: \.self) { i in
                        let t = r.tokens[i]
                        VStack(spacing: 1) {
                            Text(t.text).font(.system(size: T.f4))
                                .foregroundStyle(t.status == .ok ? Color.primary : T.Score.bad)
                            if t.status != .ok, t.atLiaison {
                                Text("连读").font(.system(size: 9)).foregroundStyle(T.Score.ok)
                            }
                        }
                    }
                }
                Text(DictationQuiz.note(r)).font(.system(size: T.f2)).foregroundStyle(.secondary)
            } else {
                TextField("听到什么打什么，拼不出来的先空着", text: $m.typed, axis: .vertical)
                    .font(.system(size: T.f3))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($typing)
                    .lineLimit(2...5)
                    .accessibilityIdentifier("train.dictation")
            }
        }
        .padding(T.s3).frame(maxWidth: .infinity, alignment: .leading).cardStyle()
    }

    // ⑦ 影子跟读 —— 精听台已经把这件事做透了，不在这儿重造一遍
    @ViewBuilder private func shadowView(_ it: TrainService.Item) -> some View {
        VStack(alignment: .leading, spacing: T.s3) {
            Text(it.en).font(.system(size: T.f4))
            Text("先听一遍，再到精听台按住录音键念一遍，逐词比对会告诉你差在哪儿。")
                .font(.system(size: T.f2)).foregroundStyle(.secondary)
        }
        .padding(T.s3).frame(maxWidth: .infinity, alignment: .leading).cardStyle()
    }

    // MARK: 底部控制条（拇指区：最左边是最高频的播放）

    private var controls: some View {
        HStack(spacing: T.s2) {
            Button {
                player.isPlaying ? m.stop() : m.playAll()
            } label: {
                Label(player.isPlaying ? "停" : "播放",
                      systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(minWidth: 96, minHeight: T.hBig)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("train.play")

            if m.revealed {
                Button {
                    m.next()
                } label: {
                    Text(m.idx + 1 >= m.items.count ? "完成" : "下一题")
                        .frame(maxWidth: .infinity, minHeight: T.hBig)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("train.next")
            } else if mode == .stress || mode == .ladder || mode == .shadow {
                // 这三个没有标准答案，用户自评
                Button { m.reveal(selfRight: false) } label: {
                    Text("没听懂").frame(maxWidth: .infinity, minHeight: T.hBig)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("train.fail")
                Button { m.reveal(selfRight: true) } label: {
                    Text("听懂了").frame(maxWidth: .infinity, minHeight: T.hBig)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("train.pass")
            } else if mode != .wordId {
                Button {
                    typing = false
                    m.reveal()
                } label: {
                    Text("对答案").frame(maxWidth: .infinity, minHeight: T.hBig)
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("train.check")
            }
        }
        .padding(.horizontal, T.side)
        .padding(.vertical, T.s2)
        .background(.bar)
    }

    // MARK: 收尾

    private var done: some View {
        VStack(spacing: T.s4) {
            Spacer()
            if m.items.isEmpty {
                Image(systemName: m.blockedNote == nil ? "tray" : "moon.zzz.fill")
                    .font(.system(size: 40)).foregroundStyle(.secondary)
                Text(m.blockedNote == nil ? "还没有够得着的材料" : "今天先到这儿")
                    .font(.system(size: T.f4, weight: .semibold))
                Text(m.blockedNote ?? ("这个练法要从「不超过 18 个词、九成是常用词」的句子里出题。\n"
                     + "先去材料库装一个包，再回来练。"))
                    .font(.system(size: T.f2)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Text("\(m.right)/\(m.items.count)")
                    .font(.system(size: T.f6, weight: .bold)).monospacedDigit()
                Text(m.right * 2 >= m.items.count ? "这一轮练得不错" : "错得多说明找对地方了，明天再来一轮")
                    .font(.system(size: T.f3)).foregroundStyle(.secondary)
            }
            Spacer()
            Button { onClose() } label: {
                Text("完成").frame(maxWidth: .infinity, minHeight: T.hBig)
            }
            .buttonStyle(.borderedProminent)
            .padding(T.side)
        }
        .accessibilityIdentifier("train.done")
    }
}

// MARK: - 两个小组件

/// 填空格：没答时是下划线，对完答案变绿/变红并把正确答案写出来
struct BlankSlot: View {
    @Binding var text: String
    var answer: String
    enum State { case idle, right, wrong }
    var state: State

    var body: some View {
        if state == .idle {
            TextField("", text: $text)
                .font(.system(size: T.f4))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .multilineTextAlignment(.center)
                .frame(minWidth: 56)
                .padding(.horizontal, 4)
                .overlay(alignment: .bottom) {
                    Rectangle().frame(height: 1.5).foregroundStyle(Color.accentColor.opacity(0.6))
                }
        } else {
            Text(answer)
                .font(.system(size: T.f4, weight: .semibold))
                .foregroundStyle(state == .right ? T.Score.good : T.Score.bad)
                .padding(.horizontal, 4)
                .overlay(alignment: .bottom) {
                    Rectangle().frame(height: 1.5)
                        .foregroundStyle((state == .right ? T.Score.good : T.Score.bad).opacity(0.5))
                }
        }
    }
}

/// 会自动折行的横向排列。
/// SwiftUI 的 `LazyVGrid` 做不到"每个词按自己的宽度排、排不下就换行"，
/// 而句子里的词长短差很多，用固定列宽会排得七零八落。
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > maxW { x = 0; y += lineH + spacing; lineH = 0 }
            x += s.width + spacing
            lineH = max(lineH, s.height)
        }
        return CGSize(width: maxW == .infinity ? x : maxW, height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + s.width > bounds.maxX {
                x = bounds.minX; y += lineH + spacing; lineH = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            lineH = max(lineH, s.height)
        }
    }
}
