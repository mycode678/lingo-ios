import SwiftUI

/// 复习：今天到期的句子一张张过。
/// 先**盲听** —— 不给字，逼自己听；听懂了再翻开对照；然后四档打分决定下次什么时候再问你。
struct ReviewScreen: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var player: Player
    @State private var queue: [Api.Card] = []
    @State private var i = 0
    @State private var shown = false
    @State private var loading = true
    @State private var toast: String?

    private var card: Api.Card? { queue.indices.contains(i) ? queue[i] : nil }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView()
                } else if let c = card {
                    VStack(spacing: 20) {
                        Text("第 \(i + 1) / \(queue.count) 张　·　\(c.word ?? "")")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()

                        VStack(spacing: 14) {
                            Text((c.reps ?? 0) > 0 ? "复习 · 练过 \(c.reps ?? 0) 次" : "新句子")
                                .font(.caption2).foregroundStyle(.secondary)
                            if shown {
                                Text(c.en).font(.system(size: 23)).multilineTextAlignment(.center)
                                if let cn = c.cn, !cn.isEmpty {
                                    Text(cn).font(.system(size: 15)).foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                }
                                if let g = c.grp, !g.isEmpty {
                                    Text(g).font(.caption2).foregroundStyle(.tertiary)
                                        .multilineTextAlignment(.center)
                                }
                            } else {
                                Text("先听，别看字")
                                    .font(.system(size: 17)).foregroundStyle(.secondary)
                                    .padding(.vertical, 26)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .card()

                        HStack(spacing: 10) {
                            Button { player.isPlaying ? player.pause() : replay() } label: {
                                Label(player.isPlaying ? "暂停" : "再听一遍",
                                      systemImage: player.isPlaying ? "pause.fill" : "play.circle.fill")
                                    .font(.system(size: 17, weight: .medium))
                                    .frame(maxWidth: .infinity, minHeight: 52)
                            }
                            .buttonStyle(.borderedProminent)
                            Button { player.loop.toggle(); if player.loop { replay() } } label: {
                                Image(systemName: "repeat").frame(width: 54, height: 52)
                            }
                            .prominent(player.loop)
                        }

                        if shown {
                            HStack(spacing: 8) {
                                gradeButton(1, "没听懂", .red)
                                gradeButton(2, "勉强", .orange)
                                gradeButton(3, "会了", .blue)
                                gradeButton(4, "脱口而出", .green)
                            }
                        } else {
                            Button("显示原文") { withAnimation { shown = true } }
                                .font(.system(size: 16))
                                .frame(maxWidth: .infinity, minHeight: 50)
                                .buttonStyle(.bordered)
                        }

                        HStack {
                            Button("跳过") { next() }
                            Spacer()
                            Button("拿去精听") { toDrill(c) }
                        }
                        .font(.system(size: 14))

                        if let t = toast {
                            Text(t).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(18)
                } else {
                    ContentUnavailableView("今天没有到期的了",
                        systemImage: "checkmark.circle",
                        description: Text("去「查词」挑个新词，点「学这个词」，它的例句就会进到这里。"))
                }
            }
            .navigationTitle("复习")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                }
            }
            .task { await load() }
            .onDisappear { player.pause() }
        }
    }

    private func gradeButton(_ q: Int, _ t: String, _ c: Color) -> some View {
        Button {
            Task {
                guard let card else { return }
                if let r = try? await Api.grade(card.src, q,
                        meta: ["word": card.word ?? "", "en": card.en, "cn": card.cn ?? "",
                               "grp": card.grp ?? "", "tag": card.tag ?? "", "kind": card.kind ?? "sent"]) {
                    let d = (r.card.due - Date().timeIntervalSince1970) / 86400
                    toast = d < 1 ? "下次 \(max(1, Int(d * 24))) 小时后" : "下次 \(Int(d.rounded())) 天后"
                }
                await store.loadDueCount()
                next()
            }
        } label: {
            Text(t).font(.system(size: 14)).frame(maxWidth: .infinity, minHeight: 50)
                .background(c.opacity(0.15)).foregroundStyle(c)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        // 复习这一屏自己说了算：把精听台留下的循环、选区、"播完干什么"全清掉，
        // 不然会一直自动播、还停不下来（踩过）
        player.loop = false
        player.loopTimes = 0
        player.onSegmentEnd = nil
        player.setSegment(nil, playNow: false)
        loading = true
        queue = (try? await Api.due(40)) ?? []
        i = 0; shown = false; toast = nil
        loading = false
        replay()
    }
    private func replay() {
        guard let c = card else { return }
        Task {
            try? await Player.shared.load(src: c.src)
            Player.shared.setSegment(nil, playNow: false)
            Player.shared.play(from: 0)
        }
    }
    private func next() {
        shown = false; toast = nil
        if i < queue.count - 1 { i += 1; replay() }
        else { Task { await load() } }
    }
    /// 这句听不明白 —— 直接拿到精听台上抠
    private func toDrill(_ c: Api.Card) {
        Task {
            if let w = c.word, store.word != w { await store.look(w) }
            if let idx = store.items.firstIndex(where: { $0.src == c.src }) { store.index = idx }
        }
    }
}
