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
    @AppStorage("ui.resultFont") private var resultFont = 17.0      // 跟读结果的字号，用户自己调
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
    /// 上一次自动播过的是哪一句 —— "切到一句就自动播"只该在**换了句子**时发生，
    /// 从别的标签页切回来不该突然响（他碰上过：一点精听就自己放）
    @State private var autoPlayedSrc: String?
    @State private var probeBar = false          // -probe：真机测试用的后门按钮排
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
            .coordinateSpace(name: "drill")           // 体检按这个坐标系算，转屏截图也不会算错
            .onPreferenceChange(BlockKey.self) { blocks in
                Audit.check(blocks, screen: geo.size)      // 只在 -demo -audit 下工作
            }
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
            if Demo.probe { probeBar = true }               // 真机测试用的那排后门按钮
            // 截图用：-sheet list|gap|rate 启动就把对应面板打开（抽屉里的布局也要验）
            if Demo.on, let sh = Demo.sheet {
                switch sh {
                case "list": showList = true
                case "gap":  showGap = true
                case "rate": editRate = 1
                default: break
                }
            }
            // 切到一句就自动响 —— 走路时用音量键切句、屏幕黑着，不自动播等于没法用。
            // 但只在**真的换了句子**时才响：从别的页切回精听不该突然出声。
            if autoPlay, autoPlayedSrc != s.src {
                autoPlayedSrc = s.src
                player.play(from: vm.selection?.lowerBound ?? 0)
            }
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

    /// 横屏两侧的空白条：轻触＝播放/暂停。不画东西，就是个隐形的大按钮。
    private var edgeTapZone: some View {
        Color.clear
            .frame(width: 30)
            .contentShape(Rectangle())
            .onTapGesture { player.toggle() }
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

                // 录音是"听"之外的另一半，跟播放键一样该显眼：录着的时候整块变红
                Button {
                    rec.isRecording ? rec.stop(sentence: store.current, natWords: vm.words, autoAB: autoAB, range: vm.selection)
                                    : rec.start()
                } label: {
                    Label(rec.isRecording ? "停止" : "录音",
                          systemImage: rec.isRecording ? "stop.fill" : "mic")
                        .fixedSize()
                        .font(.system(size: T.f2, weight: .medium))
                        .foregroundStyle(rec.isRecording ? Color.white : Color.accentColor)
                        .padding(.horizontal, 11).frame(height: 38)
                        .background(rec.isRecording ? Color.red : Color.accentColor.opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: T.ctl, style: .continuous))
                }
                .buttonStyle(.plain)

                if rec.hasTake {                       // 录过才有意义
                    Button { rec.playAB(range: vm.selection) } label: {
                        Label("对比", systemImage: "arrow.left.arrow.right").fixedSize()
                    }
                    .buttonStyle(LabelButton())
                    if !showTake { takeReopen }        // 关掉了还能叫回来
                }

                // 整句、铺满只在圈了选区时才出现 —— 没选区时它们没意义，白占位置
                // （小句再点一次也能回到整句）
                if vm.selection != nil {
                    Button {
                        vm.setSelection(a: nil, b: nil, play: false)
                        vm.zoomAll()
                        player.claim(loop: player.loop, times: loopTimes, segment: nil,
                                     onEnd: { autoAdvance(after: store.current?.src ?? "") })
                        player.play(from: 0)
                    } label: { Label("整句", systemImage: "rectangle.dashed").fixedSize() }
                    .buttonStyle(LabelButton())

                    Button { vm.zoomToSelection() } label: {
                        Label("铺满", systemImage: "arrow.left.and.right").fixedSize()
                    }
                    .buttonStyle(LabelButton())
                }

                LoopButton(player: player, times: loopTimes,
                           onToggle: { player.loop.toggle(); player.loop ? player.play() : player.pause() },
                           onHold: { showLoop = true })

                // 连播＝一句播完自动跳下一句（原来只能在设置抽屉里开）
                // 点＝开关连播，按住＝设"换下一句之前停多久"
                Label("连播", systemImage: "text.line.first.and.arrowtriangle.forward")
                    .fixedSize()
                    .font(.system(size: 12))
                    .foregroundStyle(autoNext ? Color.accentColor : Color.primary.opacity(0.7))
                    .padding(.horizontal, 9).frame(height: 38)
                    .background(autoNext ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { autoNext.toggle() }
                    .onLongPressGesture(minimumDuration: 0.25, maximumDistance: 30) { showGap = true }
                    .accessibilityElement()
                    .accessibilityLabel("连播")
                    .accessibilityAddTraits(.isButton)

                gapChip
                showMenu

                // 音量键：走路时屏幕黑着全靠它，开没开要一眼看得见
                Button {
                    volKeys.toggle()
                    showHint(volKeys ? "已经可以用音量键切上下句了\n＋上一句　−下一句"
                                     : "关了，音量键现在只调音量", 3.5)
                } label: {
                    Image(systemName: volKeys ? "speaker.wave.2.fill" : "speaker.wave.2")
                }
                .buttonStyle(IconButton(on: volKeys))

                Menu {
                    Button { showWalk = true } label: { Label("随身模式", systemImage: "headphones") }
                    Toggle("听辅音（更清楚）", isOn: $boostHF)
                    Button { showStyle = true } label: { Label("原文样式", systemImage: "textformat") }
                    Button { showMore = true } label: { Label("精听设置", systemImage: "slider.horizontal.3") }
                    Divider()
                    // 横屏藏了标签栏，这里给条路回去
                    Button { Nav.shared.tab = 0 } label: { Label("今天", systemImage: "sun.max") }
                    Button { Nav.shared.tab = 1 } label: { Label("找材料", systemImage: "books.vertical") }
                    Button { Nav.shared.tab = 3 } label: { Label("我的", systemImage: "person") }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: T.f3))
                        .foregroundStyle(Color.primary.opacity(0.55))
                        .frame(width: 40, height: 38)
                }

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
        .frame(maxWidth: .infinity)     // 不许按内容自撑宽，否则"内容比自己宽"不成立就滚不动
        .frame(height: 44)
        .accessibilityIdentifier("controlStrip")
    }

    // MARK: - 两种屏幕方向
    //
    // 这一屏踩过太多次"块与块互相压住"（译文压住控制条、选区条压住波形）。
    // 根子是：给每块写死高度，加起来超过屏幕时 SwiftUI **不会**自动收缩，
    // 而是让它们重叠。所以改成一句话的规矩：
    //
    //   固定的几条（顶栏/选区条/小句/控制条/打分）高度是常数；
    //   剩下多少 free 先算出来，再分给波形和原文卡，两者相加恒等于 free。
    //
    // 这样无论字号多大、显示几行、有没有小句，总高都不可能超过屏幕。
    // 另有 Audit（-demo -audit）在 CI 里把各种组合验一遍，重叠就 LAYOUT-FAIL。

    // 不再自己算"固定部分一共多高"——上一版就是因为常数估小了 10 点，
    // 结果顶栏被顶出屏幕 5 点、控制条掉出去 5 点（体检抓到的）。
    // 现在的规矩更简单也更不会错：
    //   除波形外，所有块都按自己的自然高度；
    //   **波形是唯一的弹性件**（最少 60，其余全给它），系统会自动把多的部分从它身上挤掉；
    //   原文卡有上限（屏高的 35%），保证它不会挤到别人头上。

    /// 原文卡"想要"多高（按整行算，勾了几样算几样）
    private var cardIdeal: CGFloat {
        guard anyText else { return 0 }
        var v: CGFloat = 18
        if showEn  { v += CGFloat(sentFont) * 1.35 * 3 }
        if showCn  { v += CGFloat(cnFont) * 1.5 * 2 }
        if showDef { v += CGFloat(cnFont) * 1.45 * 2 }
        if showDcn { v += CGFloat(cnFont) * 1.45 }
        return v
    }

    /// 原文卡实际多高：想要多少给多少，但不许超过屏幕的 35%
    private func cardH(_ total: CGFloat) -> CGFloat {
        anyText ? min(cardIdeal, total * 0.35) : 0
    }

    /// 横屏的波形高度：按屏高比例，不写死数字 ——
    /// 写死 210 在 SE（横屏才 375 高）上就把别的挤没了，在 iPad 上又浪费。
    ///   SE 375 → 195    11 Pro Max 414 → 215    iPad 1024 → 封顶 260
    private func waveH(_ total: CGFloat) -> CGFloat {
        min(max(total * 0.52, 150), 260)
    }

    private func landscape(_ s: Api.Sentence, _ geo: GeometryProxy) -> some View {
        // 这些常数都是体检（-audit）量出来的实际值，不是拍脑袋估的：
        // 顶栏内部写死 38；横屏控制条 44、打分 38＋6 内边距＝44。
        let cardHeight = cardH(geo.size.height)
        return VStack(spacing: 4) {
            // 上半截单独一层：跟读结果只浮在这一截上，不许盖住下面的控制条，
            // 也不许盖满波形（盖住就没法圈选区）。
            VStack(spacing: 4) {
                // 横屏波形固定高度，谁也别想挤它 —— 这是横屏存在的理由
                waveBlock
                    .frame(height: waveH(geo.size.height))
                    .padding(.horizontal, T.side).auditBlock("波形")
                VStack(spacing: 4) {
                    selectionBar(30).auditBlock("选区条")
                    if cardHeight > 0 {
                        sentenceCard(s).frame(height: cardHeight)
                            .padding(.horizontal, T.side).auditBlock("原文")
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .accessibilityElement(children: .contain)   // 不声明的话 UI 测试找不到这块
                .accessibilityIdentifier("swipeArea")
                .simultaneousGesture(swipeToStep)
            }
            .overlay(alignment: .bottom) {
                if rec.hasTake && showTake {
                    takePanel
                        .frame(maxHeight: geo.size.height * 0.55)
                        .background(.ultraThinMaterial)
                        .transition(.move(edge: .bottom))
                }
            }
            // 小句固定在底下这组的正上方，位置不随文字多少变
            chunkStrip.auditBlock("小句")
            controlStrip.auditBlock("控制条")
            gradeRow(30).auditBlock("打分")
        }
        // 宽度交给父视图（.infinity＝给我多少用多少）。
        // 千万别写死 geo.size.width：横屏那是含刘海区的整屏宽，比安全区宽 88 点，
        // 控制条会自认为够宽于是不滚，右边一截藏在点不到的地方（踩过两次）。
        .frame(maxWidth: .infinity)
        .padding(.bottom, 2)
        .overlay { hintOverlay }
        .overlay {
            HStack(spacing: 0) { edgeTapZone; Spacer(minLength: 0); edgeTapZone }
                .ignoresSafeArea()
        }
        .padding(.top, 2)
        .onAppear {
            // 一转到横屏就把文字全收起来：横屏是拿来盯波形、抠发音的
            showEn = false; showCn = false; showDef = false; showDcn = false
        }
    }

    private func portrait(_ s: Api.Sentence, _ geo: GeometryProxy) -> some View {
        // 同上，实测：控制条 44＋上下内边距＝58，打分 48＋6＝54＋行距＝60
        let cardHeight = cardH(geo.size.height)
        return VStack(spacing: 0) {
            probeButtons
            if Audit.on { AuditProbe() }
            VStack(spacing: 8) {
                // 唯一的弹性件。给它优先权，让它先把富余的高度吃掉 ——
                // 不给的话它和下面的文字区平分，中间空出一大片，界面看着像塌了。
                // 但也不能全吃：留下的那截是"左右滑切句"的手指落点，不能太窄。
                waveBlock
                    .frame(minHeight: 60, maxHeight: max(200, geo.size.height * 0.5))
                    .layoutPriority(1)
                    .padding(.horizontal, T.side).auditBlock("波形")
                // 波形以下这一整片都能左右滑着切句；波形自己不接（那儿要拖选区、捏缩放）
                VStack(spacing: 8) {
                    selectionBar.auditBlock("选区条")
                    if cardHeight > 0 {
                        sentenceCard(s).frame(height: cardHeight)
                            .padding(.horizontal, T.side).auditBlock("原文")
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .accessibilityElement(children: .contain)   // 不声明的话 UI 测试找不到这块
                .accessibilityIdentifier("swipeArea")
                .simultaneousGesture(swipeToStep)
            }
            .padding(.top, 6)
            .frame(maxHeight: .infinity)
            .overlay { hintOverlay }
            .overlay(alignment: .bottom) {
                if rec.hasTake && showTake {
                    takePanel
                        .frame(maxHeight: geo.size.height * 0.56)   // 字号可调大，留够高度
                        .background(.ultraThinMaterial)
                        .transition(.move(edge: .bottom))
                }
            }
            // 小句固定在最底下这组的正上方 —— 位置永远不随文字多少变，闭着眼也能点
            chunkStrip.auditBlock("小句")
            gradeRow.auditBlock("打分")
            transport.auditBlock("控制条")
        }
        .frame(maxWidth: .infinity)
    }

    /// 测试后门：把"耳机/锁屏/音量键"这些没法用代码按的动作，做成看得见点得到的按钮。
    /// 只在 -demo -probe 下出现，正式包里根本不会渲染。
    @ViewBuilder private var probeButtons: some View {
        if probeBar {
            HStack(spacing: 6) {
                Button("probe-vol-up") { VolumeKeys.shared.onUp?() }
                Button("probe-vol-down") { VolumeKeys.shared.onDown?() }
                Button("probe-remote-next") { NowPlaying.shared.onNext?() }
                Button("probe-remote-prev") { NowPlaying.shared.onPrev?() }
                Button("probe-remote-toggle") { NowPlaying.shared.onToggle?() }
            }
            .font(.system(size: 9))
            .frame(height: 18)
        }
    }

    /// 屏幕中间那句浮字（切句提示、音量键开关提示）
    @ViewBuilder private var hintOverlay: some View {
        if let h = stepHint {
            Text(h)
                .font(.system(size: 18, weight: .semibold))
                .multilineTextAlignment(.center).lineSpacing(4)
                .foregroundStyle(.white)
                .padding(.horizontal, 20).padding(.vertical, 14)
                .background(Color.black.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal, 24)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    /// 波形。原来下面挂着一行"选区 1.43–1.89s"，白占 18 点高度 ——
    /// 那是信息不是操作，改成浮在波形四角上，一点高度都不占。
    private var waveBlock: some View {
        WaveView(vm: vm)
            .clipShape(RoundedRectangle(cornerRadius: T.card, style: .continuous))
            // 角标要躲开波形顶上那一行词（截图里"excuse 1/3"正好把前几个词盖住了）：
            // 有词就整体下移一行的高度，没词就贴顶。22 是 WaveView 里词条行的高度。
            .overlay(alignment: .topLeading) { corner(leading).padding(.top, wordRowH) }
            .overlay(alignment: .topTrailing) { corner(trailing).padding(.top, wordRowH) }
    }

    /// 波形顶上那行词占多高（没对齐好、没词的时候是 0）
    private var wordRowH: CGFloat { vm.words.isEmpty ? 0 : 22 }

    /// 左上角：在练哪个词第几句（顶栏拆掉之后这个信息挪到这儿）
    @ViewBuilder private var leading: some View {
        Button { showList = true } label: {
            HStack(spacing: 4) {
                Text(store.word).font(.system(size: T.f2, weight: .semibold)).lineLimit(1)
                Text("\(store.index + 1)/\(store.items.count)")
                    .font(.system(size: T.f1)).monospacedDigit().opacity(0.7)
                if vm.loading { ProgressView().controlSize(.mini) }
            }
        }
        .buttonStyle(.plain)
    }

    /// 右上角：选区秒数、难点数、临时提示
    @ViewBuilder private var trailing: some View {
        HStack(spacing: T.s2) {
            if let t = flash {
                Text(t).lineLimit(1)
            } else if !vm.note.isEmpty {
                Text(vm.note).lineLimit(1)
            }
            if !vm.marks.isEmpty {
                Label("\(vm.marks.count)", systemImage: "flag.fill").foregroundStyle(.red)
            }
            if let sel = vm.selection {
                Text(String(format: "%.2f–%.2fs", sel.lowerBound, sel.upperBound))
                    .monospacedDigit().foregroundStyle(Color.accentColor)
            }
        }
        .font(.system(size: T.f1))
    }

    /// 角标统一外观：半透明底衬，压在波形上也看得清
    private func corner<V: View>(_ content: V) -> some View {
        content
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(6)
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
        Button { withAnimation(T.anim) { showTake = true } } label: {
            HStack(spacing: 4) {
                Image(systemName: "chart.bar.doc.horizontal")
                Text("结果")
                // 带上分数，一眼知道上一遍念得怎么样
                if let d = rec.diff {
                    Text("\(d.overall)").font(.system(size: T.f1, weight: .bold)).monospacedDigit()
                }
            }
            .fixedSize()
            .font(.system(size: T.f2, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 11).frame(height: 38)
            .background(rec.diff.map { T.Score.of($0.overall) } ?? Color.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: T.ctl, style: .continuous))
        }
        .buttonStyle(.plain)
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
                // 分项在下面的比对面板里（音准/节奏/连读），这儿只留总分，
                // 免得两套数字并排打架
                if rec.diff == nil, let sc = rec.score {
                    scoreItem("词准", sc.words)
                    scoreItem("语调", sc.tone)
                    scoreItem("节奏", sc.rhythm)
                }
                Spacer(minLength: 0)
                if let d = rec.diff {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(d.overall)")
                            .font(.system(size: 24, weight: .bold)).monospacedDigit()
                            .foregroundStyle(T.Score.of(d.overall))
                        Text("分").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                } else if let sc = rec.score {
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text("\(sc.overall)")
                            .font(.system(size: 24, weight: .bold)).monospacedDigit()
                            .foregroundStyle(scoreColor(sc.overall))
                        Text("分").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 4)
            // 打开时停在顶部：诊断在最上面，不该让人先往上滚才看得到
            ScrollViewReader { p in
                ScrollView {
                    takeBlock.padding(.bottom, 6).id("takeTop")
                }
                .onChange(of: rec.hasTake) { _, has in
                    if has { p.scrollTo("takeTop", anchor: .top) }
                }
            }
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
            .onLongPressGesture(minimumDuration: 0.25, maximumDistance: 30, perform: hold)
            // 用 Text＋手势拼出来的东西，系统默认不当它是按钮：VoiceOver 读不出来，
            // UI 测试也点不到。手动声明成按钮。
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityIdentifier("rate-" + label)
            .accessibilityAddTraits(.isButton)
    }

    private func setRate(_ i: Int, _ v: Double) {
        var a = rates
        guard a.indices.contains(i) else { return }
        a[i] = (v * 100).rounded() / 100
        ratesCSV = a.map { String(format: "%.2f", $0) }.joined(separator: ",")
    }

    /// 只跟字号有关，跟句子长短无关：短句不塌、长句在卡内滚，切句时纹丝不动
    /// 勾了几样才占多高；一样都没勾就是 0（卡片整个不出现，空间全给波形）。
    ///
    /// 两条硬要求（都是被截图打脸打出来的）：
    /// 1. 按**整行**算 —— 字号调大以后半行文字会被卡边切掉，看着像被小句盖住；
    /// 2. **封顶**在屏幕的三分之一 —— 不封顶时长句子会把小句和"没听懂"那排顶出屏幕。
    /// 超出的部分在卡片里自己滚。
    private var anyText: Bool { showEn || showCn || showDef || showDcn }
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

    /// 一块小句：点一下就圈住这几个词。竖屏换行排，横屏排一行横着滑。
    private func chunkChip(_ i: Int, _ c: (Int, Int)) -> some View {
        let a = vm.words[c.0].s, b = vm.words[c.1].e
        let on = vm.selection.map { abs($0.lowerBound - a) < 0.02 && abs($0.upperBound - b) < 0.02 } ?? false
        return Button {
            // 点几次就放几次这一小句 —— 反复练一小句是精听最常做的事，
            // 第二下跳回整句等于逼着人"取消再重选"（上一版就是这么设计错的）。
            // 要回整句：右边那个「整句」键，或者双击这个小句。
            //
            // 注意必须重新 claim 区间，不能只发一句 play() ——
            // 中间要是点过"比对结果里的某个词"，播放器的区间还停在那个词上，
            // 再点小句就只会响那个词（他碰上过）。
            if on {
                player.claim(loop: player.loop, times: loopTimes,
                             segment: vm.selection,
                             onEnd: { autoAdvance(after: store.current?.src ?? "") })
                player.play(from: vm.selection?.lowerBound ?? 0)
            } else {
                vm.selectChunk(i)
            }
        } label: {
            HStack(spacing: 5) {
                Text(vm.words[c.0...c.1].map(\.w).joined(separator: " ")).lineLimit(1)
                Text(String(format: "%.1f", b - a)).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .font(.system(size: 15.5))
            .foregroundStyle(on ? Color.accentColor : Color.primary.opacity(0.8))
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(on ? Color.accentColor.opacity(0.13) : Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: T.ctl, style: .continuous))
        }
        .buttonStyle(.plain)
        // 双击这一小句＝回到整句（不用挪手去够右边那个「整句」键）
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            vm.setSelection(a: nil, b: nil, play: false)
            vm.zoomAll()
            player.claim(loop: player.loop, times: loopTimes, segment: nil,
                         onEnd: { autoAdvance(after: store.current?.src ?? "") })
            player.play(from: 0)
        })
    }

    private var chunkRow: some View {
        FlowLayout(spacing: 7) {
            ForEach(Array(vm.chunks.enumerated()), id: \.offset) { i, c in chunkChip(i, c) }
        }
        .padding(.horizontal, T.side)
    }

    /// 横屏用：小句排成一行横着滑，只占 40 点。
    /// 上一版横屏干脆把小句砍了，可小句正是"圈半秒反复听"的入口，砍不得。
    private var chunkStrip: some View {
        Group {
            if vm.chunks.isEmpty {
                // 还没算出词边界时也占着这行位置 —— 不然小句会凭空冒出来，
                // 底下的打分和控制条跟着往下跳一格（他碰上过"小句没了"）
                HStack(spacing: T.s2) {
                    if vm.loading { ProgressView().controlSize(.mini) }
                    Text(vm.loading ? "正在切词…" : "这句还没切好词")
                        .font(.system(size: T.f2)).foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, T.side)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(Array(vm.chunks.enumerated()), id: \.offset) { i, c in chunkChip(i, c) }
                    }
                    .padding(.horizontal, T.side)
                }
            }
        }
        .frame(height: 44)
    }

    private var takeBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 出了岔子要显眼地说 —— 之前这行藏在最底下 11pt 灰字里，等于没有
            if let m = rec.message {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(m).font(.system(size: T.f2))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            // 逐词比对（手机上现算的）—— 有它就以它为主，它比听写文本有用得多
            if let d = rec.diff {
                CompareView(diff: d)
            }
            // 机器听写只是佐证："它听成了什么"。有逐词比对时降级成一行小字。
            if let h = rec.heard, !h.isEmpty {
                if rec.diff != nil {
                    Text("机器听成：" + h)
                        .font(.system(size: T.f1)).foregroundStyle(.tertiary)
                        .lineLimit(2)
                } else {
                    Text(rec.heardAttributed).font(.system(size: 15))
                    if !rec.wrongWords.isEmpty {
                        Text("问题词：" + rec.wrongWords.joined(separator: " / "))
                            .font(.system(size: 12)).foregroundStyle(.orange)
                    }
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

    private var gradeRow: some View { gradeRow(34) }
    /// 横屏高度紧张，打分行矮一档（40）；竖屏还是 48
    private func gradeRow(_ h: CGFloat) -> some View {
        HStack(spacing: T.gap) {
            grade(1, "没听懂", .red, h); grade(2, "勉强", .orange, h)
            grade(3, "会了", .blue, h); grade(4, "脱口而出", .green, h)
        }
        .padding(.horizontal, T.side).padding(.bottom, 4)
    }
    private func grade(_ q: Int, _ t: String, _ c: Color, _ h: CGFloat = 34) -> some View {
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
            // 字号保持看得清（15/16），压的是**块本身**：高度和留白。
            // 这四个键一次只按一下，色块做那么大反而喧宾夺主。
            Text(t).font(.system(size: h < 34 ? 15 : 16, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: h)
                .foregroundStyle(c)
                .background(c.opacity(0.10))
                .overlay(RoundedRectangle(cornerRadius: T.ctl, style: .continuous)
                    .stroke(c.opacity(0.30), lineWidth: 1))
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
                           _ range: ClosedRange<Double>, _ suffix: String,
                           step: Double = 0.1) -> some View {
        HStack {
            Text(title).font(.system(size: 15))
            Spacer()
            Button {
                v.wrappedValue = max(range.lowerBound, ((v.wrappedValue - step) * 100).rounded() / 100)
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
                v.wrappedValue = min(range.upperBound, ((v.wrappedValue + step) * 100).rounded() / 100)
            } label: { Image(systemName: "plus").frame(width: 40, height: 34) }
                .buttonStyle(.plain)
            Text(suffix).font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }

    private var gapSheet: some View {
        NavigationStack {
            Form {
                Section {
                    numberRow("同一段两遍之间", $gapIn, 0...6, "秒", step: 0.2)
                    numberRow("换下一句之前", $gapOut, 0...6, "秒", step: 0.2)
                } footer: {
                    Text("加减一次动 0.2 秒（0.1 太碎，得点半天）；中间的数字点开可以直接打。\n"
                         + "跟不上就调长，顺了就调短。0 就是不停顿，一遍接一遍。")
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
                    numberRow("同一段两遍之间", $gapIn, 0...6, "秒", step: 0.2)
                    numberRow("换下一句之前", $gapOut, 0...6, "秒", step: 0.2)
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
                Section {
                    Toggle("录完自动对比播放", isOn: $autoAB)
                    HStack {
                        Text("结果字号")
                        Slider(value: $resultFont, in: 14...28, step: 1)
                        Text("\(Int(resultFont))").monospacedDigit()
                            .foregroundStyle(.secondary).frame(width: 28, alignment: .trailing)
                    }
                    // 边拖边看，调到舒服为止
                    Text("这句念得很接近母语者了，节奏和连读都对。")
                        .font(.system(size: resultFont)).foregroundStyle(.secondary)
                } header: { Text("跟读") } footer: {
                    Text("跟读结果里的诊断、词块、分数会跟着这个字号变大变小。")
                }
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
        // 这个闭包是播放器回调，捕获的是**当时那份 View 值拷贝** ——
        // 读 self.autoNext 拿到的是设它时的旧值，之后在界面上开"连播"它根本看不见
        // （"先点连播再点播放没有连播"就是这么来的）。所以现取 UserDefaults；
        // player 和 store 是引用类型，可以直接读到最新的。
        let on = { UserDefaults.standard.bool(forKey: "drill.autoNext") }
        guard on() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, player.gapOut)) {
            guard on(), store.current?.src == src else { return }
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
