import SwiftUI

/// 精听台。手机屏就那么大，排布按"用的频率"来，从上到下：
///   波形（全宽，顶到边）→ 选区微调 → 原文/译文（一眼能看到，不用滚）→ 小句 →
///   录音结果（录完才出现）→ 打分
/// 播放控制钉在底部不动，上下句按钮贴着波形，都不用滚就够得到。
struct DrillScreen: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var player: Player
    @StateObject private var vm = DrillModel()
    @StateObject private var rec = Recorder.shared

    @AppStorage("ui.sentFont") private var sentFont = 21.0
    @AppStorage("drill.autoNext") private var autoNext = false      // 一段播完自动下一句
    @AppStorage("drill.gapIn") private var gapIn = 0.8              // 循环时两遍之间停多久
    @AppStorage("drill.times") private var loopTimes = 0            // 循环几遍，0=一直
    @AppStorage("drill.snap") private var snap = true               // 拖选区吸到词边
    @AppStorage("drill.autoAB") private var autoAB = true           // 录完自动对比播放
    @AppStorage("drill.showDef") private var showDef = false        // 英文释义默认收起，小屏放不下

    @State private var showText = true
    @State private var showWalk = false
    @State private var showMore = false
    @State private var flash: String?          // 一闪而过的提示，不常驻占地方

    var body: some View {
        NavigationStack {
            Group {
                if let s = store.current { content(s) } else { empty }
            }
            .toolbar(.hidden, for: .navigationBar)     // 手机上这 44 点留给波形更值
            .sheet(isPresented: $showWalk) { WalkScreen(startSegment: vm.selection) }
            .sheet(isPresented: $showMore) { settingsSheet }
        }
    }

    private var empty: some View {
        ContentUnavailableView("还没选句子", systemImage: "waveform",
            description: Text("去「查词」点一条例句，或者去「复习」拿今天到期的。"))
    }

    private func content(_ s: Api.Sentence) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 10) {
                    waveBlock(s)              // 波形：全宽顶边
                    selectionBar
                    sentenceCard(s)           // 原文译文紧跟波形，一眼能看到
                    if !vm.chunks.isEmpty { chunkRow }
                    if rec.hasTake { takeBlock }
                    gradeRow(s)
                    Color.clear.frame(height: 8)
                }
                .padding(.bottom, 6)
            }
            transport                          // 钉在底部
        }
        .task(id: s.src) {
            await vm.load(s)
            vm.snap = snap
            player.gapIn = gapIn
            player.loopTimes = loopTimes
            // 一段播完之后干什么，由这一屏说了算 —— 随身模式也会设这个回调，
            // 不接管的话精听台会莫名其妙自己跳下一句（踩过）
            player.onSegmentEnd = { advanceIfWanted() }
            rec.reset()
            showText = true
            flash = nil
        }
        .onDisappear { player.onSegmentEnd = nil }
    }

    // MARK: - 波形块

    private func waveBlock(_ s: Api.Sentence) -> some View {
        VStack(spacing: 0) {
            // 上下句就贴在波形上沿，不用滚到顶
            HStack(spacing: 6) {
                Button { step(-1) } label: {
                    Image(systemName: "chevron.left").frame(width: 42, height: 32)
                }
                .buttonStyle(.bordered).disabled(store.index == 0)
                Text(store.word).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text("\(store.index + 1)/\(store.items.count)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if vm.loading { ProgressView().controlSize(.small) }
                Spacer()
                Button { showWalk = true } label: {
                    Image(systemName: "headphones").frame(width: 38, height: 32)
                }.buttonStyle(.bordered)
                Button { showMore = true } label: {
                    Image(systemName: "slider.horizontal.3").frame(width: 38, height: 32)
                }.buttonStyle(.bordered)
                Button { step(1) } label: {
                    Image(systemName: "chevron.right").frame(width: 42, height: 32)
                }
                .buttonStyle(.bordered).disabled(store.index >= store.items.count - 1)
            }
            .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 5)

            WaveView(vm: vm)
                .frame(height: 200)
                .frame(maxWidth: .infinity)      // 顶满宽度，手机上寸土寸金

            HStack(spacing: 8) {
                if let sel = vm.selection {
                    Text(String(format: "选区 %.2f–%.2fs", sel.lowerBound, sel.upperBound))
                        .monospacedDigit().foregroundStyle(Color.accentColor)
                }
                if !vm.marks.isEmpty { Text("难点\(vm.marks.count)").foregroundStyle(.red) }
                Spacer()
                if let t = flash { Text(t).foregroundStyle(.secondary) }
                else if !vm.note.isEmpty { Text(vm.note).foregroundStyle(.secondary).lineLimit(1) }
            }
            .font(.caption)
            .padding(.horizontal, 10).padding(.top, 4)
            .frame(height: 16)
        }
    }

    /// 选区微调：手指点按钮比拖手柄准
    private var selectionBar: some View {
        HStack(spacing: 5) {
            Button("设A") { vm.setEdgeAtHead("a") }
            Button("A−") { vm.nudge("a", -0.08) }
            Button("A+") { vm.nudge("a", 0.08) }
            Button("B−") { vm.nudge("b", -0.08) }
            Button("B+") { vm.nudge("b", 0.08) }
            Button("设B") { vm.setEdgeAtHead("b") }
            Divider().frame(height: 22)
            Button {
                vm.setSelection(a: nil, b: nil, play: false); vm.zoomAll()
            } label: { Image(systemName: "xmark") }
            Button { vm.zoomToSelection() } label: { Image(systemName: "arrow.left.and.right") }
                .disabled(vm.selection == nil)
        }
        .font(.system(size: 13))
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 8)
    }

    private func sentenceCard(_ s: Api.Sentence) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(s.en)
                .font(.system(size: sentFont))
                .blur(radius: showText ? 0 : 9)
                .animation(.easeInOut(duration: 0.16), value: showText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { showText.toggle() }
            if let cn = s.cn, !cn.isEmpty {
                Text(cn).font(.system(size: sentFont - 5)).foregroundStyle(.secondary)
                    .blur(radius: showText ? 0 : 9)
            }
            if showDef, let d = s.dfe, !d.isEmpty {
                Text(d).font(.system(size: sentFont - 7)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 8)
    }

    private var chunkRow: some View {
        FlowLayout(spacing: 7) {
            ForEach(Array(vm.chunks.enumerated()), id: \.offset) { i, c in
                let a = vm.words[c.0].s, b = vm.words[c.1].e
                let on = vm.selection.map { abs($0.lowerBound - a) < 0.02 && abs($0.upperBound - b) < 0.02 } ?? false
                Button { vm.selectChunk(i) } label: {
                    HStack(spacing: 5) {
                        Text(vm.words[c.0...c.1].map(\.w).joined(separator: " ")).lineLimit(1)
                        Text(String(format: "%.1fs", b - a)).font(.caption2).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 14))
                    .padding(.horizontal, 11).padding(.vertical, 9)
                    .background(on ? Color.accentColor.opacity(0.16) : Color(.secondarySystemBackground))
                    .overlay(RoundedRectangle(cornerRadius: 10)
                        .stroke(on ? Color.accentColor : .clear, lineWidth: 1.5))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
    }

    /// 录完之后才出现：听自己的、对比、机器听写、三个分数
    private var takeBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button { rec.playMine(range: vm.selection) } label: {
                    Label("我的", systemImage: "person.wave.2").frame(maxWidth: .infinity, minHeight: 40)
                }.buttonStyle(.bordered)
                Button { rec.playAB(range: vm.selection) } label: {
                    Label("对比连播", systemImage: "arrow.left.arrow.right").frame(maxWidth: .infinity, minHeight: 40)
                }.buttonStyle(.bordered)
            }
            if let h = rec.heard, !h.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("机器听写").font(.caption).foregroundStyle(.secondary)
                    Text(rec.heardAttributed).font(.system(size: 16))
                    if !rec.wrongWords.isEmpty {
                        Text("问题词：" + rec.wrongWords.joined(separator: " / "))
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }
            if let sc = rec.score {
                HStack(spacing: 20) {
                    scoreItem("词准确率", sc.words)
                    scoreItem("语调相似", sc.tone)
                    scoreItem("节奏相似", sc.rhythm)
                }
            }
            if let m = rec.message { Text(m).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 8)
    }
    private func scoreItem(_ k: String, _ v: Int?) -> some View {
        VStack(spacing: 2) {
            Text(v == nil ? "…" : "\(v!)")
                .font(.system(size: 26, weight: .semibold)).monospacedDigit()
                .foregroundStyle(scoreColor(v))
            Text(k).font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// 三元里混 .secondary（层级样式）和 .green（颜色）类型对不上，拆成函数
    private func scoreColor(_ v: Int?) -> Color {
        guard let v else { return .secondary }
        return v >= 75 ? .green : (v >= 55 ? .orange : .red)
    }

    private func gradeRow(_ s: Api.Sentence) -> some View {
        HStack(spacing: 7) {
            grade(1, "没听懂", .red); grade(2, "勉强", .orange)
            grade(3, "会了", .blue); grade(4, "脱口而出", .green)
        }
        .padding(.horizontal, 8)
    }
    private func grade(_ q: Int, _ t: String, _ c: Color) -> some View {
        Button {
            Task {
                guard let s = store.current else { return }
                if let r = try? await Api.grade(s.src, q, score: rec.score.map { Double($0.overall) },
                                                meta: store.meta(s)) {
                    let d = (r.card.due - Date().timeIntervalSince1970) / 86400
                    showFlash(d < 1 ? "下次 \(max(1, Int(d * 24))) 小时后" : "下次 \(Int(d.rounded())) 天后")
                    await store.refreshProgress()
                }
                if autoNext { step(1) }
            }
        } label: {
            Text(t).font(.system(size: 13)).frame(maxWidth: .infinity, minHeight: 46)
                .background(c.opacity(0.14)).foregroundStyle(c)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 底部常驻控制

    private var transport: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 21)).frame(width: 62, height: 48)
                }
                .buttonStyle(.borderedProminent)
                Button {
                    player.loop.toggle()
                    if player.loop { player.play() } else { player.pause() }
                } label: {
                    Image(systemName: "repeat").frame(width: 44, height: 48)
                }
                .prominent(player.loop)
                Button {
                    rec.isRecording ? rec.stop(sentence: store.current, autoAB: autoAB, range: vm.selection)
                                    : rec.start()
                } label: {
                    Image(systemName: rec.isRecording ? "stop.fill" : "mic.fill")
                        .frame(width: 44, height: 48)
                }
                .prominent(rec.isRecording)
                .tint(rec.isRecording ? .red : nil)
                Button { Task { await toggleFav() } } label: {
                    Image(systemName: isFav ? "star.fill" : "star").frame(width: 44, height: 48)
                }
                .prominent(isFav)
                ForEach([1.0, 0.75, 0.6, 0.5], id: \.self) { r in
                    Button {
                        player.rate = Float(r)
                        if player.isPlaying { player.play() }
                    } label: {
                        Text(r == 1.0 ? "1x" : String(format: "%.2g", r))
                            .font(.system(size: 12)).frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .prominent(abs(Double(player.rate) - r) < 0.01)
                }
            }
            HStack(spacing: 7) {
                Button { Task { await vm.toggleMark() } } label: {
                    Label("标难点", systemImage: "flag").font(.system(size: 12.5))
                        .frame(maxWidth: .infinity, minHeight: 38)
                }.buttonStyle(.bordered)
                Button { vm.nextMark() } label: {
                    Label("下一处", systemImage: "arrow.right.to.line").font(.system(size: 12.5))
                        .frame(maxWidth: .infinity, minHeight: 38)
                }.buttonStyle(.bordered).disabled(vm.marks.isEmpty)
                if rec.hasTake {
                    Button { rec.playAB(range: vm.selection) } label: {
                        Label("对比", systemImage: "arrow.left.arrow.right").font(.system(size: 12.5))
                            .frame(maxWidth: .infinity, minHeight: 38)
                    }.buttonStyle(.bordered)
                }
            }
        }
        .padding(.horizontal, 8).padding(.top, 7).padding(.bottom, 4)
        .background(.bar)
        .onChange(of: gapIn) { _, v in player.gapIn = v }
        .onChange(of: loopTimes) { _, v in player.loopTimes = v }
        .onChange(of: snap) { _, v in vm.snap = v }
    }

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("播放") {
                    Toggle("一段播完自动下一句", isOn: $autoNext)
                    Picker("循环间隔", selection: $gapIn) {
                        ForEach([0.3, 0.5, 0.8, 1.2, 2.0], id: \.self) { Text("\($0, specifier: "%.1f") 秒").tag($0) }
                    }
                    Picker("循环遍数", selection: $loopTimes) {
                        Text("一直循环").tag(0)
                        ForEach([2, 3, 5, 10], id: \.self) { Text("\($0) 遍").tag($0) }
                    }
                }
                Section("选区") {
                    Toggle("拖动时吸到词边", isOn: $snap)
                }
                Section("跟读") {
                    Toggle("录完自动对比播放", isOn: $autoAB)
                }
                Section("显示") {
                    Toggle("显示英文释义", isOn: $showDef)
                }
                Section {
                    Text("波形上：单指拖＝平移，双指捏＝缩放，点一下＝把最近的边界挪过来，"
                         + "长按拖＝画新选区，拖两端圆点＝改边界。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("精听设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") { showMore = false } } }
        }
    }

    // MARK: - 动作

    private var isFav: Bool { (store.prog[store.current?.src ?? ""]?.fav ?? 0) == 1 }
    private func toggleFav() async {
        guard let s = store.current else { return }
        let on = !isFav
        try? await Api.fav(s.src, on, meta: store.meta(s))
        await store.refreshProgress()
    }
    /// 只有开了"自动下一句"才跳，并且是**整屏跟着跳**（文字、波形、词边界一起换）
    private func advanceIfWanted() {
        guard autoNext else { return }
        step(1)
    }
    private func step(_ d: Int) {
        let i = max(0, min(store.items.count - 1, store.index + d))
        guard i != store.index else { return }
        player.pause()
        store.index = i
        flash = nil
        showText = true
        rec.reset()
    }
    private func showFlash(_ t: String) {
        flash = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if flash == t { flash = nil } }
    }
    private func fmt(_ t: Double) -> String {
        String(format: "%d:%05.2f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60))
    }
}

/// 会换行的横向排列（小句块用）
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > maxW, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
        return CGSize(width: maxW == .infinity ? x : maxW, height: y + rowH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x + s.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowH = max(rowH, s.height)
        }
    }
}
