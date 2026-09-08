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
    // 精听就该先听声音，不是先看字。四个都默认关着，要看哪样自己点"显示"里勾。
    // 用新的键名（show2.*）是故意的：老键上已经存了旧默认值，不换名新默认到不了手机上。
    @AppStorage("show2.en")  private var showEn = false             // 原文
    @AppStorage("show2.cn")  private var showCn = false             // 译文
    @AppStorage("show2.dfe") private var showDef = false            // 英文释义
    @AppStorage("show2.dcn") private var showDcn = false            // 中文释义
    @AppStorage("drill.volKeys") private var volKeys = false
    @AppStorage("drill.autoPlay") private var autoPlay = true       // 切到一句就自动响
    @AppStorage("drill.boostHF") private var boostHF = true         // 听辅音（高频增强）
    /// 倍速档位自己定：慢到 0.4 快到 2.0，几档也自己定（2~5 档）。
    /// 存成一串逗号分隔的数，简单、好迁移；解析不出来就退回默认四档。
    @AppStorage("drill.rates") private var ratesCSV = "1.0,0.75,0.6,0.5"
    /// 四档之外的那个"自定"：想要 0.85、1.25 这种随手加一个，不用动前面四档
    @AppStorage("drill.customRate") private var customRate = 0.0

    @State private var showWalk = false
    @State private var showMore = false
    @State private var showStyle = false
    @State private var showList = false
    @State private var showGap = false          // 播放间隔的小面板
    @State private var editRate: Int?           // 正在改第几档速度（-1＝那个自定义档）
    @State private var showLoop = false         // 循环遍数面板
    @State private var showTake = true          // 跟读结果这块开着没（往下滑收起）
    @State private var flash: String?
    /// 中间浮一句话（切句时的"4 / 12"、开关音量键的提示）—— 单独一个状态，
    /// 不能用 flash：换句子时 .task 会把 flash 清掉，提示还没看见就没了。
    @State private var stepHint: String?

    var body: some View {
        NavigationStack {
            Group {
                if let s = store.current { content(s) } else { empty }
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showWalk) { WalkScreen(startSegment: vm.selection) }
            .sheet(isPresented: $showMore) { settingsSheet }
            .sheet(isPresented: $showStyle) { StyleSheet() }
            .sheet(isPresented: $showGap) { gapSheet }
            .sheet(isPresented: $showLoop) { LoopSheet(player: player) }
            .sheet(isPresented: Binding(get: { editRate != nil },
                                        set: { if !$0 { editRate = nil } })) { rateSheet }
            .sheet(isPresented: $showList) {
                SentenceListSheet(onPick: { i in
                    player.pause(); store.index = i; rec.reset(); flash = nil
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
            Group {
                if geo.size.width > geo.size.height {
                    // 横屏＝沉浸模式：连标签栏一起藏掉，那条白带（标签栏＋home 条
                    // 差不多 50 点）全归波形。要换页转回竖屏，或用右上角"⋯"里的跳转。
                    landscape(s, geo)
                        .toolbar(.hidden, for: .tabBar)
                } else {
                    portrait(s, geo)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }

        .onAppear {
            // 复习页和精听页共用一个播放器：在复习里放过 A 句，回到精听页时
            // 播放器里装的还是 A，点播放就放错人。切回来先对一下是不是当前这句。
            wireNowPlaying(s)          // 锁屏/耳机的播放键交给这一屏
            guard player.loadedSrc != s.src else { return }
            Task {
                player.pause()
                try? await Player.shared.load(src: s.src)
                player.claim(loop: player.loop, times: loopTimes, segment: vm.selection,
                             onEnd: { autoAdvance(after: s.src) })
            }
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
            flash = nil
            wireVolumeKeys()
            wireNowPlaying(s)
            if Demo.on && Demo.take { rec.demoTake() }      // 截图用：假装刚录完
            // 截图用：-sheet list|gap|rate 启动就把对应面板打开（抽屉里的布局也要验）
            if Demo.on, let sh = Demo.sheet {
                switch sh {
                case "list": showList = true
                case "gap":  showGap = true
                case "rate": editRate = 1
                default: break
                }
            }
            // 切到一句就自动响。走路时用音量键切句、屏幕黑着，不自动播等于没法用。
            if autoPlay { player.play(from: vm.selection?.lowerBound ?? 0) }
        }
        .onChange(of: volKeys) { _, _ in wireVolumeKeys() }
        .onChange(of: boostHF) { _, v in player.boostHF = v }
        .onChange(of: rec.hasTake) { _, has in       // 录完自动把结果弹出来
            if has { withAnimation(.easeOut(duration: 0.18)) { showTake = true } }
        }
        .onDisappear {
            player.onSegmentEnd = nil
            VolumeKeys.shared.enable(false)          // 离开就把音量键还给系统
        }
    }

    /// 横屏：屏幕矮而宽，正好给波形。
    /// 波形吃掉一半以上的高度（圈选区终于不用捏着放大镜找），原文放大摆在下面，
    /// 所有控件收成**一条**横排 —— 横屏宽度够，不必再分两行。
    /// 小句那一排在横屏收起来（竖屏有），换来的高度全给波形。
    private func landscape(_ s: Api.Sentence, _ geo: GeometryProxy) -> some View {
        // 高度是横屏唯一稀缺的东西：11 Pro Max 横屏 414，减去标签栏和home条只剩约 344。
        // 固定部分：顶栏 34 + 选区条 28 + 控制条 36 + 打分 38 + 间距 16 ＝ 152，
        // 剩下的 190 全归波形（文字默认不显示，勾了才占位）。
        // 别给波形写死大 minHeight，总和一超就是顶栏被切掉半截（1.jpg 那样）。
        VStack(spacing: 4) {
            // 上半截（顶栏、波形、选区条、原文）单独一层：跟读结果只浮在这一截上，
            // 不许盖住下面的控制条 —— 盖住了就没法边看结果边重录/重播（横屏尤其憋屈）。
            VStack(spacing: 4) {
                header
                waveBlock                               // 横屏的主角：弹性件，剩多少占多少
                    .frame(minHeight: 110, maxHeight: .infinity)
                    .padding(.horizontal, T.side)
                selectionBar(28)
                if anyText {                            // 一样都没勾就整块不出现
                    sentenceCard(s)
                        .frame(height: min(cardHeight, geo.size.height * 0.3))
                        .padding(.horizontal, T.side)
                        .contentShape(Rectangle())
                        .simultaneousGesture(swipeToStep)
                }
            }
            .overlay(alignment: .bottom) {
                if rec.hasTake && showTake {
                    takePanel
                        .background(.ultraThinMaterial)
                        .transition(.move(edge: .bottom))
                }
            }
            controlStrip
            gradeRow(38)
        }
        .padding(.bottom, 2)
        .overlay {
            if let h = stepHint {
                Text(h)
                    .font(.system(size: 18, weight: .semibold))
                    .multilineTextAlignment(.center).lineSpacing(4)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20).padding(.vertical, 14)
                    .background(Color.black.opacity(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .transition(.opacity).allowsHitTesting(false)
            }
        }
        .padding(.top, 2)
    }

    /// 底部控制条：**一条**横向可滑的长条，竖屏横屏共用。
    /// 顺序＝用得最多的在最左边（拇指落点）：列表、播放、录音、对比、整句、铺满，
    /// 然后才是循环、间隔、显示、倍速。放不下就往左滑，不再占第二行高度
    /// （原来两行 94 点，现在 44 点，省下的 50 点全给波形）。
    private var controlStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Button { showList = true } label: {
                    Image(systemName: "list.bullet").font(.system(size: 15))
                        .foregroundStyle(Color.primary.opacity(0.75))
                        .frame(width: 42, height: 38)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: T.ctl, style: .continuous))
                }
                .buttonStyle(.plain)

                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18))
                        .frame(width: 52, height: 38)
                        .background(Color.accentColor).foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: T.ctl, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    rec.isRecording ? rec.stop(sentence: store.current, autoAB: autoAB, range: vm.selection)
                                    : rec.start()
                } label: {
                    Label(rec.isRecording ? "停止" : "录音",
                          systemImage: rec.isRecording ? "stop.fill" : "mic").fixedSize()
                }
                .buttonStyle(LabelButton(on: rec.isRecording))

                if rec.hasTake {                       // 录过才有意义
                    Button { rec.playAB(range: vm.selection) } label: {
                        Label("对比", systemImage: "arrow.left.arrow.right").fixedSize()
                    }
                    .buttonStyle(LabelButton())
                    if !showTake { takeReopen }
                }

                Button {
                    vm.setSelection(a: nil, b: nil, play: false)
                    vm.zoomAll()
                    player.claim(loop: player.loop, times: loopTimes, segment: nil,
                                 onEnd: { autoAdvance(after: store.current?.src ?? "") })
                    player.play(from: 0)
                } label: { Label("整句", systemImage: "rectangle.dashed").fixedSize() }
                .buttonStyle(LabelButton(on: vm.selection == nil))

                Button { vm.zoomToSelection() } label: {
                    Label("铺满", systemImage: "arrow.left.and.right").fixedSize()
                }
                .buttonStyle(LabelButton())
                .disabled(vm.selection == nil).opacity(vm.selection == nil ? 0.35 : 1)

                LoopButton(player: player, times: loopTimes,
                           onToggle: { player.loop.toggle(); player.loop ? player.play() : player.pause() },
                           onHold: { showLoop = true })

                gapChip
                showMenu

                ForEach(Array(rates.enumerated()), id: \.offset) { i, r in
                    rateChip(rateLabel(r), on: abs(r - nearestRate) < 0.001, w: 52,
                             tap: { player.rate = Float(r); if player.isPlaying { player.play() } },
                             hold: { editRate = i })
                }
                rateChip(customRate > 0 ? rateLabel(customRate) : "自定",
                         on: customRate > 0 && abs(Double(player.rate) - customRate) < 0.001, w: 52,
                         tap: {
                             if customRate > 0 { player.rate = Float(customRate)
                                                 if player.isPlaying { player.play() } }
                             else { editRate = -1 }
                         },
                         hold: { editRate = -1 })
            }
            .padding(.horizontal, T.side)
        }
        .frame(height: 44)
    }

    /// 竖屏：从上到下 顶栏 → 波形 → 选区条 → 原文 → 小句 → 打分 → 播放条
    private func portrait(_ s: Api.Sentence, _ geo: GeometryProxy) -> some View {
        VStack(spacing: 0) {
            header
                // 位置钉死：波形、原文、小句各占固定高度，换句子时谁都不动。
                // 内容多了在自己那一块里滚，不许把别人挤上挤下（切句时整屏乱跳就是这么来的）。
                // 高度不手算：波形当弹性件，剩多少占多少（最少 88）。
                // 手算常数在小屏上必然算错 —— SE 上底部控制条被标签栏压住就是这么来的。
                VStack(spacing: 8) {
                    waveBlock
                        .frame(minHeight: 88, maxHeight: .infinity)
                        .padding(.horizontal, T.side)
                    // 波形以下这一整片都能左右滑着切句 —— 走路时单手最省事的动作。
                    // 波形自己不接：那儿要拖选区、双指缩放，两个手势打架必输。
                    VStack(spacing: 8) {
                        selectionBar
                        // 原文卡固定高度（切句不跳），句子长了在卡片里自己滚，不会被截断
                        if anyText {
                            sentenceCard(s)
                                .frame(height: cardHeight)
                                .padding(.horizontal, T.side)
                        }
                        if !vm.chunks.isEmpty {
                            ScrollView { chunkRow }
                                .frame(height: chunkHeight)
                                .scrollIndicators(.hidden)
                        }
                        Spacer(minLength: 0)
                    }
                    // 什么都不显示时这块只剩选区条那点高度，滑不动 ——
                    // 给它留 72 点的可滑地带（波形是弹性件，不留就被它吃光）
                    .frame(minHeight: 72)
                    .contentShape(Rectangle())      // 空白处也能滑，不用非按在字上
                    .simultaneousGesture(swipeToStep)
                    .overlay {
                        if let h = stepHint {
                            Text(h)
                                .font(.system(size: 18, weight: .semibold))
                                .multilineTextAlignment(.center)
                                .lineSpacing(4)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 20).padding(.vertical, 14)
                                .background(Color.black.opacity(0.72))
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .padding(.horizontal, 24)
                                .transition(.opacity)
                                .allowsHitTesting(false)
                        }
                    }
                }
                .padding(.top, 6)
                .frame(width: geo.size.width)
                .frame(maxHeight: .infinity)
                // 录完之后的结果单独浮一层，不动上面的布局
                .overlay(alignment: .bottom) {
                    if rec.hasTake && showTake {
                        takePanel
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

    /// 顶栏只回答一个问题："我现在在练哪个词的第几句"。
    /// 常用的切句、选句子一律不放这儿 —— 6.5 寸屏单手够不到顶部，
    /// 走路时更别提。它们在底部拇指区，见 transport。
    private var header: some View {
        HStack(spacing: 2) {
            Button { showList = true } label: {
                HStack(spacing: 5) {
                    Text(store.word).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    Text("\(store.index + 1)/\(store.items.count)")
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                    Image(systemName: "chevron.down").font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    if vm.loading { ProgressView().controlSize(.mini) }
                }
                .padding(.horizontal, 6).frame(height: 34)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Spacer(minLength: 0)

            // 音量键切句：单独一个开关摆在这儿，别藏菜单里 ——
            // 走路时屏幕黑着，全靠它；开没开必须一眼看得见。
            Button {
                volKeys.toggle()
                showHint(volKeys ? "已经可以用音量键切上下句了\n＋上一句　−下一句"
                                 : "关了，音量键现在只调音量", 3.5)
            } label: {
                Image(systemName: volKeys ? "speaker.wave.2.fill" : "speaker.wave.2")
            }
            .buttonStyle(IconButton(on: volKeys))

            Button { showWalk = true } label: { Image(systemName: "headphones") }
                .buttonStyle(IconButton())
            Menu {
                Button { showStyle = true } label: { Label("原文样式", systemImage: "textformat") }
                Button { showMore = true } label: { Label("精听设置", systemImage: "slider.horizontal.3") }
                Divider()
                // 横屏把标签栏藏了，这里给条路回去
                Button { Nav.shared.tab = 0 } label: { Label("去查词", systemImage: "magnifyingglass") }
                Button { Nav.shared.tab = 2 } label: { Label("去复习", systemImage: "arrow.triangle.2.circlepath") }
                Button { Nav.shared.tab = 3 } label: { Label("我的库", systemImage: "books.vertical") }
                Toggle("听辅音（更清楚）", isOn: $boostHF)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 15))
                    .foregroundStyle(Color.primary.opacity(0.55))
                    .frame(width: 40, height: 34)
            }
        }
        .padding(.horizontal, T.side - 4)
        .frame(height: 38)
    }

    private var waveBlock: some View {
        VStack(spacing: 4) {
            WaveView(vm: vm)
                .frame(maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: T.card, style: .continuous))
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
    /// 选区微调：A 和 B 各自成组（−／设／＋），右边两个图标管整句和放满。
    /// 八个一模一样的胶囊排一排像调试面板，分了组才看得出这是"两端各调各的"。
    private var selectionBar: some View { selectionBar(36) }
    /// 横屏高度金贵，这排压到 28，省下的全给波形
    private func selectionBar(_ h: CGFloat) -> some View {
        HStack(spacing: T.gap) {
            edgeGroup("A", h, minus: { vm.nudge("a", -0.08) },
                      set: { vm.setEdgeAtHead("a") }, plus: { vm.nudge("a", 0.08) })
            edgeGroup("B", h, minus: { vm.nudge("b", -0.08) },
                      set: { vm.setEdgeAtHead("b") }, plus: { vm.nudge("b", 0.08) })
            Spacer(minLength: 0)
            // 收藏和难点跟"这一句/这段选区"绑在一起，放选区这排比放播放排顺；
            // 底下那排腾出来给整句、铺满这些一直要点的。
            Button { Task { await toggleFav() } } label: {
                Image(systemName: isFav ? "star.fill" : "star")
            }
            .buttonStyle(IconButton(on: isFav))
            Button { Task { await vm.toggleMark() } } label: { Image(systemName: "flag") }
                .buttonStyle(IconButton(on: !vm.marks.isEmpty))
            if !vm.marks.isEmpty {                      // 没标难点就不占位置
                Button { vm.nextMark() } label: { Image(systemName: "arrow.right.to.line") }
                    .buttonStyle(IconButton())
            }
        }
        .padding(.horizontal, T.side)
        .frame(height: h)
    }
    private func edgeGroup(_ name: String, _ h: CGFloat = 36, minus: @escaping () -> Void,
                           set: @escaping () -> Void, plus: @escaping () -> Void) -> some View {
        let bh = h - 4
        return HStack(spacing: 0) {
            Button(action: minus) { Image(systemName: "minus").frame(width: 30, height: bh) }
            Button(action: set) {
                Text(name).font(.system(size: 13, weight: .medium)).frame(width: 26, height: bh)
            }
            Button(action: plus) { Image(systemName: "plus").frame(width: 30, height: bh) }
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.primary.opacity(0.75))
        .background(Color.primary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: T.ctl, style: .continuous))
    }

    // MARK: - 倍速档位
    private var rates: [Double] {
        let v = ratesCSV.split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            .filter { $0 >= 0.3 && $0 <= 3.0 }
        return v.count >= 2 ? v : [1.0, 0.75, 0.6, 0.5]
    }
    /// 0.75 → "0.75x"，1.0 → "1x"：小屏上少一个字符就少挤一分
    private func rateLabel(_ v: Double) -> String {
        var t = String(format: "%.2f", v)
        while t.hasSuffix("0") { t.removeLast() }
        if t.hasSuffix(".") { t.removeLast() }
        return t + "x"
    }
    /// 当前速度未必正好等于某一档（改过档位、或在别处调过），选最近的那档亮起来
    private var nearestRate: Double {
        rates.min(by: { abs($0 - Double(player.rate)) < abs($1 - Double(player.rate)) }) ?? 1.0
    }
    /// 循环间隔那个牌子：点一下开面板。练的时候一直在动，不能埋进设置抽屉里。
    private var gapChip: some View {
        Button { showGap = true } label: {
            HStack(spacing: 3) {
                Image(systemName: "timer").font(.system(size: 12))
                Text(gapIn == 0 ? "不停" : "\(gapIn, specifier: "%.1f")s")
                    .font(.system(size: 13, weight: .medium)).monospacedDigit()
            }
            .fixedSize()
            .foregroundStyle(Color.primary.opacity(0.75))
            .padding(.horizontal, 9).frame(height: 34)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: T.ctl, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// 结果下滑收起来之后，用它叫回来（录音还在，不用重录）
    private var takeReopen: some View {
        Button { withAnimation(.easeOut(duration: 0.18)) { showTake = true } } label: {
            Label("结果", systemImage: "chart.bar.doc.horizontal").fixedSize()
        }
        .buttonStyle(LabelButton(on: true))
    }

    /// 跟读结果。横屏高度是宝贵资源，所以**不给它单独的标题栏**：
    /// 操作（对比、我的）和三个分项、总分全挤在同一行，顶上只有一条 4 点高的小横杠
    /// 提示"能下滑收起"。关闭不用按钮 —— 往下一滑就收（录音还留着，
    /// 底排会冒出"结果"把它叫回来）。操作一律靠左，拇指不用横穿屏幕。
    private var takePanel: some View {
        VStack(spacing: 0) {
            Capsule().fill(Color.primary.opacity(0.22))
                .frame(width: 34, height: 4).padding(.top, 5).padding(.bottom, 3)
            HStack(spacing: 6) {
                Button { rec.playAB(range: vm.selection) } label: {
                    Label("对比", systemImage: "arrow.left.arrow.right").fixedSize()
                }
                .buttonStyle(LabelButton())
                Button { rec.playMine(range: vm.selection) } label: {
                    Label("我的", systemImage: "person.wave.2").fixedSize()
                }
                .buttonStyle(LabelButton())
                if let sc = rec.score {
                    scoreItem("词准", sc.words)
                    scoreItem("语调", sc.tone)
                    scoreItem("节奏", sc.rhythm)
                }
                Spacer(minLength: 0)
                if let sc = rec.score {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(sc.overall)")
                            .font(.system(size: 24, weight: .bold)).monospacedDigit()
                            .foregroundStyle(scoreColor(sc.overall))
                        Text("分").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 4)
            ScrollView { takeBlock.padding(.bottom, 6) }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 12)
                .onEnded { g in
                    if g.translation.height > 40 {
                        withAnimation(.easeIn(duration: 0.18)) { showTake = false }
                    }
                }
        )
    }

    /// 显示什么：原文/译文/中文释义/英文释义各自开关，默认一个都不显示。
    /// 精听的规矩是先听声音，字是听不出来时才翻的答案。
    private var showMenu: some View {
        Menu {
            Toggle("原文", isOn: $showEn)
            Toggle("译文", isOn: $showCn)
            Toggle("中文释义", isOn: $showDcn)
            Toggle("英文释义", isOn: $showDef)
            Divider()
            Button(anyText ? "全部隐藏（只听声音）" : "全部显示") {
                let on = !anyText
                showEn = on; showCn = on; showDcn = on; showDef = on
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: anyText ? "eye" : "eye.slash").font(.system(size: 13))
                Text("显示").font(.system(size: 13, weight: .medium))
            }
            .fixedSize()
            .foregroundStyle(anyText ? Color.accentColor : Color.primary.opacity(0.7))
            .padding(.horizontal, 9).frame(height: 34)
            .background(anyText ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: T.ctl, style: .continuous))
        }
    }

    /// w 给了就是固定宽（横滑长条里用），不给就平分（老的分段样式）
    private func rateChip(_ label: String, on: Bool, w: CGFloat? = nil,
                          tap: @escaping () -> Void, hold: @escaping () -> Void) -> some View {
        Text(label)
            .font(.system(size: 13, weight: on ? .semibold : .regular))
            .monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
            .foregroundStyle(on ? Color.accentColor : Color.primary.opacity(0.75))
            .frame(width: w, height: 38)
            .frame(maxWidth: w == nil ? .infinity : nil)
            .background(on ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: T.ctl, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture(perform: tap)
            .onLongPressGesture(minimumDuration: 0.5, maximumDistance: 30, perform: hold)
    }

    private func setRate(_ i: Int, _ v: Double) {
        var a = rates
        guard a.indices.contains(i) else { return }
        a[i] = (v * 100).rounded() / 100
        ratesCSV = a.map { String(format: "%.2f", $0) }.joined(separator: ",")
    }

    private var chunkHeight: CGFloat { 84 }
    /// 只跟字号有关，跟句子长短无关：短句不塌、长句在卡内滚，切句时纹丝不动
    /// 勾了几样才占多高；一样都没勾就是 0（卡片整个不出现，空间全给波形）
    private var anyText: Bool { showEn || showCn || showDef || showDcn }
    private var cardHeight: CGFloat {
        guard anyText else { return 0 }
        return 20
            + (showEn  ? CGFloat(sentFont) * 2.9 : 0)
            + (showCn  ? CGFloat(cnFont) * 1.7 : 0)
            + (showDef ? CGFloat(cnFont) * 1.5 : 0)
            + (showDcn ? CGFloat(cnFont) * 1.5 : 0)
    }

    private func sentenceCard(_ s: Api.Sentence) -> some View {
        ScrollView {                       // 长句子在卡片内部滚，不挤别人也不被截
        VStack(alignment: .leading, spacing: 6) {
            if showEn {
                // 播到哪个词，哪个词亮 —— 跟电脑版一样的浅黄底
                Text(highlighted(s.en))
                    .font(face(sentFace, sentFont))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if showCn, let cn = s.cn, !cn.isEmpty {
                Text(cn)
                    .font(face(cnFace, cnFont))
                    .foregroundStyle(color(cnColor) ?? Color.secondary)
            }
            if showDef, let d = s.dfe, !d.isEmpty {
                Text(d).font(.system(size: max(11, cnFont - 3))).foregroundStyle(.tertiary)
            }
            if showDcn, let d = s.dcn, !d.isEmpty {
                Text(d).font(.system(size: max(11, cnFont - 3))).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle(color(cardBg))
    }

    private var chunkRow: some View {
        FlowLayout(spacing: 7) {
            ForEach(Array(vm.chunks.enumerated()), id: \.offset) { i, c in
                let a = vm.words[c.0].s, b = vm.words[c.1].e
                let on = vm.selection.map { abs($0.lowerBound - a) < 0.02 && abs($0.upperBound - b) < 0.02 } ?? false
                Button { vm.selectChunk(i) } label: {
                    HStack(spacing: 5) {
                        Text(vm.words[c.0...c.1].map(\.w).joined(separator: " ")).lineLimit(1)
                        Text(String(format: "%.1f", b - a)).font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    .font(.system(size: 13.5))
                    .foregroundStyle(on ? Color.accentColor : Color.primary.opacity(0.8))
                    .padding(.horizontal, 11).padding(.vertical, 9)
                    .background(on ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: T.ctl, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, T.side)
    }

    private var takeBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let h = rec.heard, !h.isEmpty {
                Text(rec.heardAttributed).font(.system(size: 15))
                if !rec.wrongWords.isEmpty {
                    Text("问题词：" + rec.wrongWords.joined(separator: " / "))
                        .font(.system(size: 12)).foregroundStyle(.orange)
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
    /// 一个分项："词准 88" 横着来 —— 原来是竖排大数字＋10pt 小标签，
    /// 占三倍地方，标签还小到看不清。
    private func scoreItem(_ k: String, _ v: Int?) -> some View {
        HStack(spacing: 3) {
            Text(k).font(.system(size: 12)).foregroundStyle(.secondary)
            Text(v == nil ? "…" : "\(v!)")
                .font(.system(size: 16, weight: .semibold)).monospacedDigit()
                .foregroundStyle(scoreColor(v))
        }
        .fixedSize()
    }
    private func scoreColor(_ v: Int?) -> Color {
        guard let v else { return .secondary }
        return v >= 75 ? .green : (v >= 55 ? .orange : .red)
    }

    private var gradeRow: some View { gradeRow(48) }
    /// 横屏高度紧张，打分行矮一档（40）；竖屏还是 48
    private func gradeRow(_ h: CGFloat) -> some View {
        HStack(spacing: T.gap) {
            grade(1, "没听懂", .red, h); grade(2, "勉强", .orange, h)
            grade(3, "会了", .blue, h); grade(4, "脱口而出", .green, h)
        }
        .padding(.horizontal, T.side).padding(.bottom, 6)
    }
    private func grade(_ q: Int, _ t: String, _ c: Color, _ h: CGFloat = 48) -> some View {
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
            Text(t).font(.system(size: h < 44 ? 14 : 15, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, minHeight: h)
                .foregroundStyle(c)
                .background(c.opacity(0.14))
                .overlay(RoundedRectangle(cornerRadius: T.ctl, style: .continuous)
                    .stroke(c.opacity(0.45), lineWidth: 1.2))
                .clipShape(RoundedRectangle(cornerRadius: T.ctl, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// 底部＝拇指区，所有高频动作都在这儿：
    /// 竖屏底部：就是那条横滑的控制条（原来两行，合并省了 50 点高度）
    private var transport: some View {
        controlStrip
        .padding(.top, 8).padding(.bottom, 6)
        .background(.bar)
        .onChange(of: gapIn) { _, v in player.gapIn = v }
        .onChange(of: gapOut) { _, v in player.gapOut = v }
        .onChange(of: loopTimes) { _, v in player.loopTimes = v }
        .onChange(of: snap) { _, v in vm.snap = v }
    }
    // MARK: - 两个小面板：播放间隔、改某一档速度

    /// 一行"减 — 数字 — 加"：0.1 一步，中间那个数字点开能直接打字
    private func numberRow(_ title: String, _ v: Binding<Double>,
                           _ range: ClosedRange<Double>, _ suffix: String) -> some View {
        HStack {
            Text(title).font(.system(size: 15))
            Spacer()
            Button {
                v.wrappedValue = max(range.lowerBound, ((v.wrappedValue - 0.1) * 10).rounded() / 10)
            } label: { Image(systemName: "minus").frame(width: 40, height: 34) }
                .buttonStyle(.plain)
            TextField("", value: v, format: .number.precision(.fractionLength(0...2)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.center)
                .font(.system(size: 17, weight: .medium)).monospacedDigit()
                .frame(width: 66, height: 34)
                .background(Color.primary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onChange(of: v.wrappedValue) { _, nv in
                    if nv < range.lowerBound { v.wrappedValue = range.lowerBound }
                    if nv > range.upperBound { v.wrappedValue = range.upperBound }
                }
            Button {
                v.wrappedValue = min(range.upperBound, ((v.wrappedValue + 0.1) * 10).rounded() / 10)
            } label: { Image(systemName: "plus").frame(width: 40, height: 34) }
                .buttonStyle(.plain)
            Text(suffix).font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }

    private var gapSheet: some View {
        NavigationStack {
            Form {
                Section {
                    numberRow("同一段两遍之间", $gapIn, 0...6, "秒")
                    numberRow("换下一句之前", $gapOut, 0...6, "秒")
                } footer: {
                    Text("跟不上就调长，顺了就调短。0 就是不停顿，一遍接一遍。")
                }
            }
            .navigationTitle("播放间隔")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") { showGap = false } } }
        }
        .presentationDetents([.height(260)])
    }

    private var rateSheet: some View {
        let i = editRate ?? 0
        let custom = (i < 0)
        return NavigationStack {
            Form {
                Section {
                    numberRow("速度", custom
                        ? Binding(get: { customRate > 0 ? customRate : 0.85 },
                                  set: { customRate = ($0 * 100).rounded() / 100 })
                        : Binding(get: { rates.indices.contains(i) ? rates[i] : 1.0 },
                                  set: { setRate(i, $0) }), 0.4...2.0, "倍")
                    if custom {
                        Button("就用这个速度") {
                            if customRate > 0 { player.rate = Float(customRate)
                                                if player.isPlaying { player.play() } }
                            editRate = nil
                        }
                    }
                } footer: {
                    Text(custom
                         ? "填一个前面四档没有的速度，比如 0.85、1.25。填好点一下那个格子就能用。"
                         : "底部那一排任意一档长按就能改。慢到 0.4 快到 2.0，中间的数字点开可以直接打。")
                }
                Section {
                    Button("四档恢复默认（1x / 0.75x / 0.6x / 0.5x）") {
                        ratesCSV = "1.0,0.75,0.6,0.5"
                        editRate = nil
                    }
                }
            }
            .navigationTitle(custom ? "自定速度" : "第 \(i + 1) 档速度")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") { editRate = nil } } }
        }
        .presentationDetents([.height(300)])
    }

    // MARK: - 两张抽屉

    private var settingsSheet: some View {
        NavigationStack {
            Form {
                Section("播放") {
                    Toggle("切到一句就自动播放", isOn: $autoPlay)
                    Toggle("一段播完自动下一句", isOn: $autoNext)
                    numberRow("同一段两遍之间", $gapIn, 0...6, "秒")
                    numberRow("换下一句之前", $gapOut, 0...6, "秒")
                    Picker("循环遍数", selection: $loopTimes) {
                        Text("一直循环").tag(0)
                        ForEach([2, 3, 5, 10], id: \.self) { Text("\($0) 遍").tag($0) }
                    }
                }
                Section {
                    Text("倍速：底部那一排长按任意一档就能改")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    Text("间隔：底部 ⏱ 那个牌子点一下就能改")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
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
                Section("显示") {
                    Text("原文、译文、中英文释义都在底部那个「显示」里勾 —— "
                         + "默认一个都不显示，先听声音，听不出来再翻答案。")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
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

    private func face(_ name: String, _ size: Double) -> Font { TX.face(name, size) }
    private func color(_ hex: String) -> Color? { TX.color(hex) }
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
    /// 左右滑＝切句。往左滑下一句、往右滑上一句，跟翻书一个方向。
    /// 判定要横向明显压过纵向：卡片里上下滚长句子时不能被误判成切句。
    private var swipeToStep: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { g in
                let dx = g.translation.width, dy = g.translation.height
                guard abs(dx) > 48, abs(dx) > abs(dy) * 1.5 else { return }
                step(dx < 0 ? 1 : -1)
            }
    }

    private func step(_ d: Int) {
        let n = store.items.count
        guard n > 0 else { return }
        let i = ((store.index + d) % n + n) % n
        guard i != store.index else { return }
        player.pause()
        store.index = i
        rec.reset()
        // 切句不给任何反馈（不震动、不弹字）：手势大家早就用熟了，反馈反而打扰
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

    /// 把锁屏、控制中心、耳机线控上的播放键接到这一屏。
    /// 这些按钮是全局的，谁最后接管就归谁 —— 随身模式退出后要由精听台重新接回来，
    /// 否则锁屏上按播放还在动随身模式那套（或者干脆没反应）。
    private func wireNowPlaying(_ s: Api.Sentence) {
        let np = NowPlaying.shared
        np.title = s.en
        np.subtitle = store.word + (s.gnum.map { " · " + $0 } ?? "")
        np.blind = false
        np.onToggle = { player.toggle() }        // 播放/暂停，跟屏幕上那个键一个行为
        np.onNext = { step(1) }
        np.onPrev = { step(-1) }
        np.onReplay = { player.play(from: vm.selection?.lowerBound ?? 0) }
        np.update()
    }

    /// 屏幕中间浮一句话，过几秒自己消失
    private func showHint(_ t: String, _ sec: Double = 2.0) {
        withAnimation(.easeOut(duration: 0.12)) { stepHint = t }
        DispatchQueue.main.asyncAfter(deadline: .now() + sec) {
            withAnimation(.easeIn(duration: 0.25)) { if stepHint == t { stepHint = nil } }
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
