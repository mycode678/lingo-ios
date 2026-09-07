import SwiftUI

/// 随身模式：走路、通勤、口袋里练。
/// 屏幕多半是黑的，所以这一屏的设计目标是"不看也能用"：
/// 大按钮、音量键切句、锁屏控制、耳机线控，界面只是给你偶尔瞄一眼确认。
struct WalkScreen: View {
    var startSegment: ClosedRange<Double>?
    @EnvironmentObject var store: Store
    @EnvironmentObject var player: Player
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vk = VolumeKeys.shared

    @AppStorage("walk.rep") private var rep = 2
    @AppStorage("walk.gapIn") private var gapIn = 0.8
    @AppStorage("walk.gapOut") private var gapOut = 1.2
    @AppStorage("walk.blind") private var blind = false
    @AppStorage("walk.loopAll") private var loopAll = true
    @AppStorage("walk.scope") private var scope = "word"

    @State private var list: [Api.Sentence] = []
    @State private var i = 0
    @State private var round = 0
    @State private var segOnly = false

    private var cur: Api.Sentence? { list.indices.contains(i) ? list[i] : nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Text(scopeTitle).font(.caption).foregroundStyle(.secondary)

                VStack(spacing: 12) {
                    Text(cur?.en ?? "")
                        .font(.system(size: 24, weight: .regular))
                        .multilineTextAlignment(.center)
                        .blur(radius: blind ? 10 : 0)
                        .animation(.easeInOut(duration: 0.2), value: blind)
                    if let cn = cur?.cn, !cn.isEmpty {
                        Text(cn).font(.system(size: 15)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .blur(radius: blind ? 10 : 0)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { blind.toggle(); NowPlaying.shared.blind = blind; NowPlaying.shared.update() }

                ProgressView(value: progress).tint(.accentColor)
                Text("第 \(i + 1) / \(max(1, list.count)) 句　第 \(round + 1) / \(rep) 遍")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()

                HStack(spacing: 30) {
                    Button { prev() } label: { Image(systemName: "backward.end.fill").font(.title2) }
                    Button { player.toggle() } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 30))
                            .frame(width: 84, height: 84)
                            .background(Color.accentColor).foregroundStyle(.white)
                            .clipShape(Circle())
                    }
                    Button { next() } label: { Image(systemName: "forward.end.fill").font(.title2) }
                }
                .buttonStyle(.plain)

                // 走路时最有用的两个开关
                HStack(spacing: 10) {
                    Toggle(isOn: Binding(get: { vk.enabled }, set: { vk.enable($0) })) {
                        Label("音量键切句", systemImage: "volume.2")
                    }
                    .toggleStyle(.button)
                    Toggle(isOn: $blind) { Label("盲听", systemImage: "eye.slash") }
                        .toggleStyle(.button)
                        .onChange(of: blind) { _, v in NowPlaying.shared.blind = v; NowPlaying.shared.update() }
                }
                .font(.system(size: 13))

                if startSegment != nil {
                    Toggle(isOn: $segOnly) { Label("只循环刚圈的那一小段", systemImage: "scissors") }
                        .toggleStyle(.button).font(.system(size: 13))
                        .onChange(of: segOnly) { _, v in
                            player.setSegment(v ? startSegment : nil, playNow: true)
                        }
                }

                HStack(spacing: 12) {
                    Stepper("每句 \(rep) 遍", value: $rep, in: 1...20)
                    Toggle("循环", isOn: $loopAll).labelsHidden()
                }
                .font(.system(size: 13))

                Picker("", selection: $scope) {
                    Text("这个词").tag("word")
                    Text("收藏").tag("fav")
                    Text("有难点").tag("mark")
                    Text("今天该复习").tag("due")
                }
                .pickerStyle(.segmented)
                .onChange(of: scope) { _, _ in Task { await build() } }
            }
            .padding(18)
            .navigationTitle("随身模式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { player.pause(); vk.enable(false); dismiss() }
                }
            }
            .task {
                await build()
                if let s = startSegment { segOnly = true; player.setSegment(s, playNow: false) }
                wire()
                await playCurrent()
            }
            .onDisappear { vk.enable(false); player.loop = false }
        }
    }

    private var progress: Double {
        let a = player.segment?.lowerBound ?? 0
        let b = player.segment?.upperBound ?? max(0.01, player.duration)
        return min(1, max(0, (player.position - a) / max(0.01, b - a)))
    }
    private var scopeTitle: String {
        switch scope {
        case "fav": return "收藏的句子"
        case "mark": return "标过难点的句子"
        case "due": return "今天该复习的"
        default: return store.word.isEmpty ? "随身练" : store.word + " 的例句"
        }
    }

    private func build() async {
        switch scope {
        case "due":
            let cards = (try? await Api.due(60)) ?? []
            list = cards.map { .init(src: $0.src, en: $0.en, cn: $0.cn, grp: $0.grp,
                                     gnum: nil, dfe: nil, tag: $0.tag, kind: $0.kind, bold: nil) }
        case "fav":
            list = store.items.filter { (store.prog[$0.src]?.fav ?? 0) == 1 }
        case "mark":
            list = store.items.filter { (store.prog[$0.src]?.marks ?? 0) > 0 }
        default:
            list = store.items
        }
        if list.isEmpty { list = store.items }
        i = max(0, list.firstIndex { $0.src == store.current?.src } ?? 0)
        round = 0
        Task { await Cache.shared.prefetch(list.map(\.src)) }   // 先下下来，出门断网也能听
    }

    private func wire() {
        vk.onUp = { next() }
        vk.onDown = { prev() }
        NowPlaying.shared.onNext = { next() }
        NowPlaying.shared.onPrev = { prev() }
        NowPlaying.shared.onToggle = { player.toggle() }
        NowPlaying.shared.onReplay = { Task { await playCurrent() } }
        player.onSegmentEnd = { pieceEnded() }
    }

    private func playCurrent() async {
        guard let s = cur else { return }
        try? await Player.shared.load(src: s.src)
        if segOnly, let seg = startSegment { player.segment = seg }
        NowPlaying.shared.title = s.en
        NowPlaying.shared.subtitle = (s.grp?.isEmpty == false ? s.grp! : store.word)
        NowPlaying.shared.blind = blind
        player.loop = false                 // 遍数由这里控制，不用引擎自己的循环
        player.play(from: player.segment?.lowerBound ?? 0)
        NowPlaying.shared.update()
    }

    /// 一遍放完：够遍数就下一句，不够就隔一会儿再来一遍
    private func pieceEnded() {
        round += 1
        let again = round < rep
        DispatchQueue.main.asyncAfter(deadline: .now() + (again ? gapIn : gapOut)) {
            if again { player.play(from: player.segment?.lowerBound ?? 0) }
            else {
                round = 0
                if i < list.count - 1 { i += 1; Task { await playCurrent() } }
                else if loopAll { i = 0; Task { await playCurrent() } }
            }
        }
    }
    private func next() { round = 0; i = i < list.count - 1 ? i + 1 : (loopAll ? 0 : i); Task { await playCurrent() } }
    private func prev() { round = 0; i = i > 0 ? i - 1 : (loopAll ? max(0, list.count - 1) : 0); Task { await playCurrent() } }
}
