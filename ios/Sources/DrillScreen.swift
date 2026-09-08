import SwiftUI

/// 精听台（手机思维：拇指够得到的地方放常用的，一次性设置全收进抽屉）
///
/// 屏幕从上到下：极窄的顶栏 → **波形和原文居中**（拇指自然落点）→ 打分 → 播放控制。
/// 顶部只放"偶尔点一下"的图标，且都收小；底部放"一直要点"的大按钮。
///
/// 宽度上有个坑：SwiftUI 的竖列宽度＝最宽那个子视图的理想宽度。选区那排按钮一多，
/// 理想宽度就超过屏宽，整列被撑出去，波形和文字左右都被切掉（21.png 就是这么来的）。
/// 所以这里把宽度锁死在容器上，放不下的横排自己滚。
struct DrillScreen: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var player: Player
    @StateObject private var vm = DrillModel()
    @StateObject private var rec = Recorder.shared

    // 外观
    @AppStorage("ui.sentFont") private var sentFont = 21.0
    @AppStorage("ui.sentFace") private var sentFace = "system"
    @AppStorage("ui.sentColor") private var sentColor = ""          // 空＝跟随主题
    @AppStorage("ui.cnFont") private var cnFont = 16.0
    @AppStorage("ui.cnFace") private var cnFace = "system"
    @AppStorage("ui.cnColor") private var cnColor = ""
    @AppStorage("ui.cardBg") private var cardBg = ""

    // 行为
    @AppStorage("drill.autoNext") private var autoNext = false
    @AppStorage("drill.gapIn") private var gapIn = 0.8              // 同一段两遍之间
    @AppStorage("drill.gapOut") private var gapOut = 1.2            // 换下一句之前
    @AppStorage("drill.times") private var loopTimes = 0
    @AppStorage("drill.snap") private var snap = true
    @AppStorage("drill.autoAB") private var autoAB = true
    @AppStorage("drill.showDef") private var showDef = false
    @AppStorage("drill.volKeys") private var volKeys = false
    @AppStorage("drill.autoPlay") private var autoPlay = true       // 切到一句就自动响
    @AppStorage("drill.boostHF") private var boostHF = false        // 听辅音（高频增强）

    @State private var showText = true
    @State private var showWalk = false
    @State private var showMore = false
    @State private var showStyle = false
    @State private var showList = false
    @State private var flash: String?

    var body: some View {
        NavigationStack {
            Group {
                if let s = store.current { content(s) } else { empty }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showWalk) { WalkScreen(startSegment: vm.selection) }
            .sheet(isPresented: $showMore) { settingsSheet }
            .sheet(isPresented: $showStyle) { styleSheet }
            .sheet(isPresented: $showList) {
                SentenceListSheet(onPick: { i in
                    player.pause(); store.index = i; rec.reset(); showText = true; flash = nil
                })
            }
        }
    }

    private var empty: some View {
        ContentUnavailableView("还没选句子", systemImage: "waveform",
            description: Text("去「查词」点一条例句，或者去「复习」拿今天到期的。"))
    }

    // MARK: - 主体

    private func content(_ s: Api.Sentence) -> some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                header
                // 位置钉死：波形、原文、小句各占固定高度，换句子时谁都不动。
                // 内容多了在自己那一块里滚，不许把别人挤上挤下（切句时整屏乱跳就是这么来的）。
                VStack(spacing: 8) {
                    Spacer(minLength: 0).frame(height: 10)
                    waveBlock(height: waveHeight(geo.size.height))
                    selectionBar
                    // 原文卡吃掉剩下的空间：对同一部手机是固定高度（切句不跳），
                    // 句子长了在卡片里自己滚，不会被截断
                    sentenceCard(s).frame(minHeight: 96, maxHeight: .infinity)
                    if !vm.chunks.isEmpty {
                        ScrollView { chunkRow }
                            .frame(height: chunkHeight)
                            .scrollIndicators(.hidden)
                    }
                }
                .frame(width: geo.size.width)
                // 录完之后的结果单独浮一层，不动上面的布局
                .overlay(alignment: .bottom) {
                    if rec.hasTake {
                        VStack(spacing: 0) {
                            HStack {
                                Text("跟读结果").font(.system(size: 12)).foregroundStyle(.secondary)
                                Spacer()
                                Button { rec.reset() } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                            }
                            .padding(.horizontal, 14).padding(.top, 8)
                            ScrollView { takeBlock.padding(.bottom, 6) }
                        }
                        .frame(maxHeight: geo.size.height * 0.46)
                        .background(.ultraThinMaterial)
                        .transition(.move(edge: .bottom))
                    }
                }
                gradeRow
                transport
            }
            .frame(width: geo.size.width)
        }
        .task(id: s.src) {
            await vm.load(s)
            vm.snap = snap
            player.gapIn = gapIn
            player.claim(loop: player.loop, times: loopTimes,
                         segment: vm.selection,
                         onEnd: { autoAdvance(after: s.src) })
            player.boostHF = boostHF
            rec.reset()
            showText = true
            flash = nil
            wireVolumeKeys()
            // 切到一句就自动响。走路时用音量键切句、屏幕黑着，不自动播等于没法用。
            if autoPlay { player.play(from: vm.selection?.lowerBound ?? 0) }
        }
        .onChange(of: volKeys) { _, _ in wireVolumeKeys() }
        .onChange(of: boostHF) { _, v in player.boostHF = v }
        .onDisappear {
            player.onSegmentEnd = nil
            VolumeKeys.shared.enable(false)          // 离开就把音量键还给系统
        }
    }

    /// 顶栏：34 点高的一条，图标全收小 —— 手机上这些是"偶尔点一下"的东西
    private var header: some View {
        HStack(spacing: 4) {
            iconButton("chevron.left", disabled: store.index == 0) { step(-1) }
            Text(store.word).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            Text("\(store.index + 1)/\(store.items.count)")
                .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
            if vm.loading { ProgressView().controlSize(.mini) }
            Spacer(minLength: 4)
            iconButton(volKeys ? "volume.2.fill" : "volume.slash", on: volKeys) { volKeys.toggle() }
            iconButton("list.bullet") { showList = true }
            iconButton("textformat") { showStyle = true }
            iconButton("headphones") { showWalk = true }
            iconButton("slider.horizontal.3") { showMore = true }
            iconButton("chevron.right", disabled: store.index >= store.items.count - 1) { step(1) }
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
    }
    private func iconButton(_ name: String, on: Bool = false, disabled: Bool = false,
                            _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: name)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 30, height: 26)
                .background(on ? Color.accentColor : Color(.secondarySystemBackground))
                .foregroundStyle(on ? Color.white : (disabled ? Color.secondary : Color.accentColor))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }

    /// 中间区大约是屏高减掉上下固定部分；波形最多 190，小屏和横屏按比例缩
    private func waveHeight(_ screenH: CGFloat) -> CGFloat {
        let mid = max(120, screenH - 34 - 46 - 100 - 49)
        return min(190, max(96, mid * 0.45))
    }

    private func waveBlock(height: CGFloat) -> some View {
        VStack(spacing: 3) {
            WaveView(vm: vm).frame(height: height)
            HStack(spacing: 8) {
                if let sel = vm.selection {
                    Text(String(format: "选区 %.2f–%.2fs", sel.lowerBound, sel.upperBound))
                        .monospacedDigit().foregroundStyle(Color.accentColor)
                }
                if !vm.marks.isEmpty { Text("难点\(vm.marks.count)").foregroundStyle(.red) }
                Spacer(minLength: 0)
                if let t = flash { Text(t).foregroundStyle(.secondary).lineLimit(1) }
                else if !vm.note.isEmpty { Text(vm.note).foregroundStyle(.secondary).lineLimit(1) }
            }
            .font(.system(size: 11))
            .padding(.horizontal, 10)
            .frame(height: 14)
        }
    }

    /// 放不下就横向滚，绝不撑宽整屏
    private var selectionBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                small("设A") { vm.setEdgeAtHead("a") }
                small("A−") { vm.nudge("a", -0.08) }
                small("A+") { vm.nudge("a", 0.08) }
                small("B−") { vm.nudge("b", -0.08) }
                small("B+") { vm.nudge("b", 0.08) }
                small("设B") { vm.setEdgeAtHead("b") }
                Divider().frame(height: 20)
                small("整句") { vm.setSelection(a: nil, b: nil, play: false); vm.zoomAll() }
                small("放满") { vm.zoomToSelection() }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 34)
    }
    private func small(_ t: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Text(t).font(.system(size: 12.5))
                .padding(.horizontal, 11).frame(height: 30)
                .background(Color(.secondarySystemBackground))
                .foregroundStyle(Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var chunkHeight: CGFloat { 82 }

    private func sentenceCard(_ s: Api.Sentence) -> some View {
        ScrollView {                       // 长句子在卡片内部滚，不挤别人也不被截
        VStack(alignment: .leading, spacing: 6) {
            // 播到哪个词，哪个词亮 —— 跟电脑版一样的浅黄底
            Text(highlighted(s.en))
                .font(face(sentFace, sentFont))
                .blur(radius: showText ? 0 : 9)
                .animation(.easeInOut(duration: 0.16), value: showText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { showText.toggle() }
            if let cn = s.cn, !cn.isEmpty {
                Text(cn)
                    .font(face(cnFace, cnFont))
                    .foregroundStyle(color(cnColor) ?? Color.secondary)
                    .blur(radius: showText ? 0 : 9)
            }
            if showDef, let d = s.dfe, !d.isEmpty {
                Text(d).font(.system(size: max(11, cnFont - 3))).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color(cardBg) ?? Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 8)
    }

    private var chunkRow: some View {
        FlowLayout(spacing: 6) {
            ForEach(Array(vm.chunks.enumerated()), id: \.offset) { i, c in
                let a = vm.words[c.0].s, b = vm.words[c.1].e
                let on = vm.selection.map { abs($0.lowerBound - a) < 0.02 && abs($0.upperBound - b) < 0.02 } ?? false
                Button { vm.selectChunk(i) } label: {
                    HStack(spacing: 5) {
                        Text(vm.words[c.0...c.1].map(\.w).joined(separator: " ")).lineLimit(1)
                        Text(String(format: "%.1f", b - a)).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 13))
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(on ? Color.accentColor.opacity(0.16) : Color(.secondarySystemBackground))
                    .overlay(RoundedRectangle(cornerRadius: 9)
                        .stroke(on ? Color.accentColor : .clear, lineWidth: 1.5))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
    }

    private var takeBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let h = rec.heard, !h.isEmpty {
                Text(rec.heardAttributed).font(.system(size: 15))
                if !rec.wrongWords.isEmpty {
                    Text("问题词：" + rec.wrongWords.joined(separator: " / "))
                        .font(.system(size: 11)).foregroundStyle(.orange)
                }
            }
            if let sc = rec.score {
                HStack(spacing: 18) {
                    scoreItem("词准确", sc.words)
                    scoreItem("语调", sc.tone)
                    scoreItem("节奏", sc.rhythm)
                    Spacer()
                    Button { rec.playMine(range: vm.selection) } label: {
                        Label("我的", systemImage: "person.wave.2").font(.system(size: 12))
                    }.buttonStyle(.bordered).controlSize(.small)
                }
            }
            if let c = rec.curve {
                VStack(alignment: .leading, spacing: 2) {
                    Text("语调 · 节奏　蓝＝原声　橙＝你的")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    CurveView(nat: c.nat, mine: c.mine, rms: c.rms)
                        .frame(height: 96)
                }
            }
            if let m = rec.message { Text(m).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 8)
    }
    private func scoreItem(_ k: String, _ v: Int?) -> some View {
        VStack(spacing: 0) {
            Text(v == nil ? "…" : "\(v!)")
                .font(.system(size: 21, weight: .semibold)).monospacedDigit()
                .foregroundStyle(scoreColor(v))
            Text(k).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
    private func scoreColor(_ v: Int?) -> Color {
        guard let v else { return .secondary }
        return v >= 75 ? .green : (v >= 55 ? .orange : .red)
    }

    private var gradeRow: some View {
        HStack(spacing: 6) {
            grade(1, "没听懂", .red); grade(2, "勉强", .orange)
            grade(3, "会了", .blue); grade(4, "脱口而出", .green)
        }
        .padding(.horizontal, 8).padding(.bottom, 4)
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
            Text(t).font(.system(size: 12.5)).lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 42)
                .background(c.opacity(0.14)).foregroundStyle(c)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var transport: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                bigButton(player.isPlaying ? "pause.fill" : "play.fill", prominent: true, w: 56) {
                    player.toggle()
                }
                bigButton("repeat", on: player.loop) {
                    player.loop.toggle()
                    if player.loop { player.play() } else { player.pause() }
                }
                bigButton(rec.isRecording ? "stop.fill" : "mic.fill",
                          on: rec.isRecording, tint: .red) {
                    rec.isRecording ? rec.stop(sentence: store.current, autoAB: autoAB, range: vm.selection)
                                    : rec.start()
                }
                bigButton(isFav ? "star.fill" : "star", on: isFav) { Task { await toggleFav() } }
                ForEach([1.0, 0.75, 0.6, 0.5], id: \.self) { r in
                    let on = abs(Double(player.rate) - r) < 0.01
                    Button {
                        player.rate = Float(r)
                        if player.isPlaying { player.play() }
                    } label: {
                        Text(r == 1.0 ? "1x" : String(format: "%.2g", r))
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(on ? Color.accentColor : Color(.secondarySystemBackground))
                            .foregroundStyle(on ? Color.white : Color.accentColor)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 6) {
                flatButton("标难点", "flag") { Task { await vm.toggleMark() } }
                flatButton("下一处", "arrow.right.to.line", disabled: vm.marks.isEmpty) { vm.nextMark() }
                if rec.hasTake {
                    flatButton("对比", "arrow.left.arrow.right") { rec.playAB(range: vm.selection) }
                }
            }
        }
        .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 4)
        .background(.bar)
        .onChange(of: gapIn) { _, v in player.gapIn = v }
        .onChange(of: gapOut) { _, v in player.gapOut = v }
        .onChange(of: loopTimes) { _, v in player.loopTimes = v }
        .onChange(of: snap) { _, v in vm.snap = v }
    }
    private func bigButton(_ icon: String, prominent: Bool = false, on: Bool = false,
                           tint: Color? = nil, w: CGFloat = 44,
                           _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Image(systemName: icon).font(.system(size: 17))
                .frame(width: w, height: 44)
                .background(prominent || on ? (tint ?? Color.accentColor) : Color(.secondarySystemBackground))
                .foregroundStyle(prominent || on ? Color.white : Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
    private func flatButton(_ t: String, _ icon: String, disabled: Bool = false,
                            _ act: @escaping () -> Void) -> some View {
        Button(action: act) {
            Label(t, systemImage: icon).font(.system(size: 12))
                .frame(maxWidth: .infinity, minHeight: 34)
                .background(Color(.secondarySystemBackground))
                .foregroundStyle(disabled ? Color.secondary : Color.accentColor)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain).disabled(disabled)
    }

    // MARK: - 两张抽屉

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("播放") {
                    Toggle("切到一句就自动播放", isOn: $autoPlay)
                    Toggle("一段播完自动下一句", isOn: $autoNext)
                    Picker("同一段两遍之间", selection: $gapIn) {
                        ForEach([0.3, 0.5, 0.8, 1.2, 2.0, 3.0], id: \.self) {
                            Text("\($0, specifier: "%.1f") 秒").tag($0) }
                    }
                    Picker("换下一句之前", selection: $gapOut) {
                        ForEach([0.0, 0.5, 1.0, 1.5, 2.0, 3.0], id: \.self) {
                            Text("\($0, specifier: "%.1f") 秒").tag($0) }
                    }
                    Picker("循环遍数", selection: $loopTimes) {
                        Text("一直循环").tag(0)
                        ForEach([2, 3, 5, 10], id: \.self) { Text("\($0) 遍").tag($0) }
                    }
                }
                Section {
                    Toggle("音量键切上下句", isOn: $volKeys)
                } header: { Text("音量键") } footer: {
                    Text("音量＋（上面那个）＝上一句，音量−（下面那个）＝下一句；按完音量会自动复位，离开这一屏自动还给系统。")
                }
                Section("选区") {
                    Toggle("拖动时吸到词边", isOn: $snap)
                    Toggle("记住每句的选区", isOn: $vm.rememberSelection)
                }
                Section {
                    Toggle("听辅音（高频增强）", isOn: $boostHF)
                } header: { Text("听感") } footer: {
                    Text("把 2.5kHz 以上抬高一点，句尾的 t/s/k 这些辅音会清楚很多，专抠连读用。")
                }
                Section("跟读") { Toggle("录完自动对比播放", isOn: $autoAB) }
                Section("显示") { Toggle("显示英文释义", isOn: $showDef) }
                Section {
                    Text("波形：单指拖＝平移，双指捏＝缩放，点一下＝把最近的边界挪过来，"
                         + "长按拖＝画新选区，拖两端圆点＝改边界。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("精听设置").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") { showMore = false } } }
        }
    }

    /// 原文/译文的样式：字体、字号、颜色、卡片底色，上面实时预览
    private var styleSheet: some View {
        NavigationStack {
            Form {
                Section("预览") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Excuse me, can you tell me the way to the museum please?")
                            .font(face(sentFace, sentFont))
                            .foregroundStyle(color(sentColor) ?? Color.primary)
                        Text("劳驾，请问去博物馆怎么走？")
                            .font(face(cnFace, cnFont))
                            .foregroundStyle(color(cnColor) ?? Color.secondary)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(color(cardBg) ?? Color(.secondarySystemGroupedBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                Section("原文") {
                    Picker("字体", selection: $sentFace) { faceOptions }
                    sizeRow("字号", $sentFont, 14...48)
                    colorRow("颜色", $sentColor)
                }
                Section("译文") {
                    Picker("字体", selection: $cnFace) { faceOptions }
                    sizeRow("字号", $cnFont, 11...40)
                    colorRow("颜色", $cnColor)
                }
                Section("卡片底色") { colorRow("底色", $cardBg) }
                Section {
                    Button("全部恢复默认") {
                        sentFace = "system"; sentFont = 21; sentColor = ""
                        cnFace = "system"; cnFont = 16; cnColor = ""; cardBg = ""
                    }
                }
            }
            .navigationTitle("原文样式").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") { showStyle = false } } }
        }
    }
    private var faceOptions: some View {
        Group {
            Text("系统").tag("system")
            Text("圆体").tag("rounded")
            Text("衬线").tag("serif")
            Text("等宽").tag("mono")
        }
    }
    private func sizeRow(_ t: String, _ v: Binding<Double>, _ r: ClosedRange<Double>) -> some View {
        HStack {
            Text(t)
            Slider(value: v, in: r, step: 1)
            Text("\(Int(v.wrappedValue))").monospacedDigit()
                .foregroundStyle(.secondary).frame(width: 28)
        }
    }
    private func colorRow(_ t: String, _ hex: Binding<String>) -> some View {
        HStack {
            ColorPicker(t, selection: Binding(
                get: { color(hex.wrappedValue) ?? Color.primary },
                set: { hex.wrappedValue = $0.hexString }))
            if !hex.wrappedValue.isEmpty {
                Button("默认") { hex.wrappedValue = "" }.font(.caption).buttonStyle(.bordered)
            }
        }
    }

    // MARK: - 小工具

    /// 把句子拆成词，播到哪个词就给哪个词加浅黄底。
    /// 词的时间来自服务器的强制对齐；它是按"去掉标点后按空格切"生成的，
    /// 所以这里按同样的规则对位：只有含字母数字的那些词才占一个位置。
    private func highlighted(_ text: String) -> AttributedString {
        let base = color(sentColor) ?? Color.primary
        guard !vm.words.isEmpty, player.isPlaying || player.position > 0 else {
            var a = AttributedString(text); a.foregroundColor = base; return a
        }
        let t = player.position
        var active = -1
        for (i, w) in vm.words.enumerated() where t >= w.s && t < w.e { active = i; break }
        if active < 0, let last = vm.words.last, t >= last.e { active = -1 }

        var out = AttributedString("")
        var k = 0
        for (n, tok) in text.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            var piece = AttributedString((n > 0 ? " " : "") + tok)
            piece.foregroundColor = base
            let hasLetter = tok.contains { $0.isLetter || $0.isNumber }
            if hasLetter {
                if k == active {
                    piece.backgroundColor = Color.yellow.opacity(0.45)
                }
                k += 1
            }
            out += piece
        }
        return out
    }

    private func face(_ name: String, _ size: Double) -> Font {
        switch name {
        case "rounded": return .system(size: size, design: .rounded)
        case "serif":   return .system(size: size, design: .serif)
        case "mono":    return .system(size: size, design: .monospaced)
        default:        return .system(size: size)
        }
    }
    private func color(_ hex: String) -> Color? { hex.isEmpty ? nil : Color(hex: hex) }
    private var isFav: Bool { (store.prog[store.current?.src ?? ""]?.fav ?? 0) == 1 }
    private func toggleFav() async {
        guard let s = store.current else { return }
        try? await Api.fav(s.src, !isFav, meta: store.meta(s))
        await store.refreshProgress()
    }
    /// 音量＋在机身上面＝上一句，音量−在下面＝下一句。
    /// 按物理位置来最不容易按错，别的听力 App 也是这个方向。
    private func wireVolumeKeys() {
        let vk = VolumeKeys.shared
        vk.onUp = { step(-1) }
        vk.onDown = { step(1) }
        vk.enable(volKeys)
    }
    /// 首尾相接：最后一句再往下就回到第一句，反之亦然 ——
    /// 走路时用音量键连着切，卡在最后一句上就得掏手机，不能这样。
    private func step(_ d: Int) {
        let n = store.items.count
        guard n > 0 else { return }
        let i = ((store.index + d) % n + n) % n
        guard i != store.index else { return }
        player.pause()
        store.index = i
        flash = nil
        showText = true
        rec.reset()
    }
    /// 一段播完 → 等"换下一句之前"这个间隔 → 再跳。
    /// 中途要是切了句或停了播，这次回调作废（拿当时那句的地址对一下就知道）。
    private func autoAdvance(after src: String) {
        guard autoNext else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, gapOut)) {
            guard autoNext, store.current?.src == src else { return }
            step(1)
        }
    }

    private func showFlash(_ t: String) {
        flash = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if flash == t { flash = nil } }
    }
}

extension Color {
    /// ColorPicker 给的是 Color，要存进 UserDefaults 就得转成 #rrggbb
    var hexString: String {
        let c = UIColor(self)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "#%02x%02x%02x", Int(r * 255), Int(g * 255), Int(b * 255))
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
