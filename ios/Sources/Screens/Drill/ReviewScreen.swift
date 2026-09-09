import SwiftUI

/// 复习：今天到期的句子一张张过。
/// 先**盲听** —— 不给字，逼自己听；听懂了再翻开对照；然后四档打分决定下次什么时候再问你。
struct ReviewScreen: View {
    /// 从「今天」全屏弹出来时给个关闭入口；当独立页用时不传
    var onClose: (() -> Void)? = nil
    @EnvironmentObject var store: Store
    @EnvironmentObject var player: Player
    @State private var queue: [Api.Card] = []
    @State private var i = 0
    @State private var shown = false
    @State private var loading = true
    @State private var toast: String?
    @State private var failed: String?
    @State private var showStyle = false
    @State private var showLoop = false
    // 字号、颜色跟精听台是同一套（同一批 @AppStorage 键），改一边两边都变
    @AppStorage("ui.sentFont") private var sentFont = 21.0
    @AppStorage("ui.sentFace") private var sentFace = "system"
    @AppStorage("ui.sentColor") private var sentColor = ""
    @AppStorage("ui.cnFont") private var cnFont = 16.0
    @AppStorage("ui.cnFace") private var cnFace = "system"
    @AppStorage("ui.cnColor") private var cnColor = ""
    @AppStorage("ui.cardBg") private var cardBg = ""
    @AppStorage("drill.times") private var loopTimes = 0

    private var card: Api.Card? { queue.indices.contains(i) ? queue[i] : nil }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView()
                } else if let f = failed {
                    ContentUnavailableView {
                        Label("连不上服务器", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(f + "\n在「我的库 → 设置」里检查地址和账号密码。")
                    } actions: {
                        Button("重试") { Task { await load() } }.buttonStyle(.borderedProminent)
                    }
                } else if let c = card {
                    VStack(spacing: 20) {
                        Text("第 \(i + 1) / \(queue.count) 张　·　\(c.word ?? "")")
                            .font(.caption).foregroundStyle(.secondary).monospacedDigit()

                        VStack(spacing: 14) {
                            Spacer(minLength: 0)
                            Text((c.reps ?? 0) > 0 ? "复习 · 练过 \(c.reps ?? 0) 次" : "新句子")
                                .font(.caption2).foregroundStyle(.secondary)
                            if shown {
                                Text(c.en)
                                    .font(TX.face(sentFace, sentFont))
                                    .foregroundStyle(TX.color(sentColor) ?? Color.primary)
                                    .multilineTextAlignment(.center)
                                if let cn = c.cn, !cn.isEmpty {
                                    Text(cn)
                                        .font(TX.face(cnFace, cnFont))
                                        .foregroundStyle(TX.color(cnColor) ?? Color.secondary)
                                        .multilineTextAlignment(.center)
                                }
                                if let g = c.grp, !g.isEmpty {
                                    Text(g).font(.caption2).foregroundStyle(.tertiary)
                                        .multilineTextAlignment(.center)
                                }
                            } else {
                                // 盲听：卡片是空的，得让它看着"就是要空"，而不是界面坏了
                                Image(systemName: "ear")
                                    .font(.system(size: 34, weight: .light))
                                    .foregroundStyle(.tertiary)
                                Text("先听，别看字")
                                    .font(.system(size: 17)).foregroundStyle(.secondary)
                                Text("点一下这块＝播放／暂停，点两下＝翻开原文")
                                    .font(.caption).foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)   // 卡片撑满上半屏，
                        .card(TX.color(cardBg))                             // 控件自然被推到下半屏
                        .contentShape(Rectangle())
                        // 中间这一大片就是主操作区：点一下＝再听一遍，点两下＝翻开/盖上原文。
                        // 双击必须写在单击前面，否则单击先吃掉手势，双击永远不触发。
                        .onTapGesture(count: 2) { withAnimation { shown.toggle() } }
                        .onTapGesture { player.isPlaying ? player.pause() : replay() }
                        .overlay(                                           // 浅色背景下卡片要看得见边
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                        )

                        HStack(spacing: 14) {
                            Button { player.isPlaying ? player.pause() : replay() } label: {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: 24))
                                    .frame(width: 64, height: 64)
                                    .background(Color.accentColor).foregroundStyle(.white)
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            // 点＝开关循环，按住 0.5 秒＝选循环几遍
                            LoopButton(player: player, times: loopTimes,
                                       onToggle: { player.loop.toggle(); if player.loop { replay() } },
                                       onHold: { showLoop = true })
                            Button { toDrill(card!) } label: { Image(systemName: "waveform") }
                                .buttonStyle(IconButton())
                            // 下一张不再放按钮：左右滑就行，跟精听台一致
                        }

                        HStack(spacing: T.gap) {
                            gradeButton(1, "没听懂", .red)
                            gradeButton(2, "勉强", .orange)
                            gradeButton(3, "会了", .blue)
                            gradeButton(4, "脱口而出", .green)
                        }

                        if let t = toast {
                            Text(t).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(18)
                    // 整屏任意地方左右滑都能换上下句 —— 手指停在下半屏就能操作，
                    // 不用够到卡片那么高的地方。往左滑是下一张。
                    .contentShape(Rectangle())
                    .simultaneousGesture(
                        // 左右、上下都能换：往左/往上＝下一张，往右/往下＝上一张。
                        // 哪个方向划得多就按哪个算，省得斜着划两边都触发。
                        DragGesture(minimumDistance: 20)
                            .onEnded { g in
                                let dx = g.translation.width, dy = g.translation.height
                                if abs(dx) >= abs(dy) {
                                    guard abs(dx) > 48 else { return }
                                    dx < 0 ? next() : prev()
                                } else {
                                    guard abs(dy) > 48 else { return }
                                    dy < 0 ? next() : prev()
                                }
                            }
                    )
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
                    HStack(spacing: 2) {
                        Button { showStyle = true } label: { Image(systemName: "textformat") }
                        Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    }
                }
                if let onClose {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("完成") { player.pause(); onClose() }
                    }
                }
            }
            .task { await load() }
            .sheet(isPresented: $showStyle) { StyleSheet() }
            .sheet(isPresented: $showLoop) { LoopSheet(player: player) }
            .onDisappear { player.pause() }
        }
    }

    private func gradeButton(_ q: Int, _ t: String, _ c: Color) -> some View {
        Button {
            Task {
                guard let card else { return }
                let meta = ["word": card.word ?? "", "en": card.en, "cn": card.cn ?? "",
                            "grp": card.grp ?? "", "tag": card.tag ?? "", "kind": card.kind ?? "sent"]
                // 本机算排期、本机存，没网照样复习
                let due = PracticeService.shared.grade(card.src, q, meta: meta)
                let d = (due - Date().timeIntervalSince1970) / 86400
                toast = d < 1 ? "下次 \(max(1, Int(d * 24))) 小时后" : "下次 \(Int(d.rounded())) 天后"
                _ = try? await Api.grade(card.src, q, meta: meta)      // 顺手备份
                await store.loadDueCount()
                next()
            }
        } label: {
            Text(t).font(.system(size: 13.5)).lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 48)
                .foregroundStyle(c).background(c.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: T.ctl, style: .continuous)
                    .stroke(c.opacity(0.28), lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: T.ctl, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        // 复习这一屏自己说了算：把精听台留下的循环、选区、"播完干什么"全清掉，
        // 不然会一直自动播、还停不下来（踩过）
        player.claim()          // 复习：不循环、不带选区、播完什么也不干
        loading = true; failed = nil
        if Demo.on {
            queue = Demo.sentences.map { .init(src: $0.src, word: Demo.word, en: $0.en, cn: $0.cn,
                                               grp: $0.grp, tag: $0.tag, kind: "sent", reps: 1, due: 0) }
        } else {
            // 复习队列从本机取 —— 没网也要能复习，这是"脱离服务器"的核心场景之一。
            await PracticeService.shared.seedFromServerIfNeeded()
            let local = PracticeService.shared.due(40)
            if !local.isEmpty {
                queue = local.map { .init(src: $0.src, word: $0.word, en: $0.en,
                                          cn: $0.cn, grp: $0.grp, tag: $0.tag,
                                          kind: "sent", reps: $0.reps, due: $0.due) }
            } else {
                // 本机一条都没有（刚装上、还没搬过家）才去问服务器
                do { queue = try await Api.due(40) }
                catch { failed = error.localizedDescription; queue = [] }
            }
        }
        i = 0; shown = false; toast = nil
        loading = false
        if failed == nil { replay() }
    }
    private func replay() {
        guard let c = card else { return }
        Task {
            try? await Player.shared.load(src: c.src)
            Player.shared.setSegment(nil, playNow: false)
            Player.shared.play(from: 0)
        }
    }
    private func prev() {
        shown = false; toast = nil
        if i > 0 { i -= 1; replay() }
    }
    private func next() {
        shown = false; toast = nil
        if i < queue.count - 1 { i += 1; replay() }
        else { Task { await load() } }
    }
    /// 这句听不明白 —— 直接拿到精听台上抠
    private func toDrill(_ c: Api.Card) {
        Task {
            player.pause()
            if let w = c.word, store.word != w { await store.look(w) }
            if let idx = store.items.firstIndex(where: { $0.src == c.src }) { store.index = idx }
            Nav.shared.tab = 2                     // 真的跳到精听台
        }
    }
}
