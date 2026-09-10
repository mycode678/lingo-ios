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
    /// 连播换到下一句时，播整句还是播这句记住的选区。默认整句 ——
    /// 划过一次选区之后连播就一直只放那一小段，是他最早提的问题。
    @AppStorage("drill.loopWhole") private var loopWhole = true
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
    /// 原文卡里的字实际占多高（量出来的，见 sentenceCard）
    @State private var cardContentH: CGFloat = 0
    /// 这一次换句是不是连播自己跳的（连播跳过来必须出声，跟"自动播"开关无关）
    @State private var autoNextJump = false
    /// 横屏临时把文字收起来（横屏是拿来盯波形抠发音的）。
    /// **一定要用 @State，不能去写那四个 @AppStorage** ——
    /// 那是用户持久化的偏好，横屏写一次 false，转回竖屏就再也回不来了，
    /// 用户在竖屏勾好的"显示原文+译文"转一次屏就永久没了。
    @State private var landHideText = false
    /// 这一句打过哪一档（换句就清空）。点完要看得见，不然不知道打没打过。
    @State private var graded: Int?
    /// 这一句**听完一遍**了没有。打分四键要等听完才出现 ——
    /// 一句都还没放完就摆四个"没听懂/勉强/会了/脱口而出"在拇指区，
    /// 既没意义又占掉一整行，还把跟读结果往上挤。
    ///
    /// 为什么是"听完"不是"开始播"：自动播默认开着，一进这一句就出声，
    /// 按"开始播"算的话它照样立刻出现，等于没改。按"听完"算，
    /// 进来那几秒屏幕是干净的，波形和原文能占满，听完再让人评分 ——
    /// 这也正好是评分该发生的时机。切句时清零。
    @State private var heardThisOne = false
    private let practice = PracticeService.shared
    /// 这次会话里本机改过收藏的句子（本机取消了收藏，服务器那份还写着 1，别让它盖回来）
    @State private var favTouched: Set<String> = []
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
                        .onAppear { landHideText = true }
                        .onDisappear { landHideText = false }
                } else {
                    portrait(s, geo)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // 分组背景：卡片是白的，底也得比白深一点，卡片才是卡片。
            // 两个方向共用 —— 只加在竖屏的话，横屏勾出原文来卡片照样是隐形的。
            .background(Color(.systemGroupedBackground))
            .coordinateSpace(name: "drill")           // 体检按这个坐标系算，转屏截图也不会算错
            .onPreferenceChange(BlockKey.self) { blocks in
                Audit.check(blocks, screen: geo.size)      // 只在 -demo -audit 下工作
            }
            // 体检结果的出口。必须两个方向都有：横屏才是最容易挤重叠的方向，
            // 原来只写在竖屏里，横屏那份体检永远是"没拿到"。
            .overlay(alignment: .topLeading) { if Audit.on { AuditProbe() } }
            .overlay(alignment: .topTrailing) { if Api.offline { NetProbe() } }
            // 这几个设置改完要立刻送到播放器。原来挂在 transport 上，
            // 而 transport 只有竖屏用，横屏改了得等切下一句才生效。
            .onChange(of: gapIn) { _, v in player.gapIn = v }
            .onChange(of: gapOut) { _, v in player.gapOut = v }
            .onChange(of: loopTimes) { _, v in player.loopTimes = v }
            .onChange(of: snap) { _, v in vm.snap = v }
        }

        .onAppear {
            // 锁屏/耳机的播放键交给这一屏。装载统一走下面的 .task，
            // 这里不再自己 claim —— 两条路各传各的区间，谁后落地谁说了算，
            // 结果是"有时放整句有时放那一小段"，还复现不了。
            wireNowPlaying(s)
        }
        .task(id: s.src) {
            await vm.load(s)
            // 这一屏跟复习页共用播放器：从复习页回来时播放器里装的可能是别的句子。
            // 这个判断必须放在 vm.load **之后** —— vm.load 自己就会把音频装好，
            // 放前面判的话每次换句都会多一次 pause+重新装载，正赶上用户
            // （和测试）在波形上拖选区，一拖就断。
            let fresh = player.loadedSrc != s.src
            vm.snap = snap
            player.gapIn = gapIn
            player.gapOut = gapOut          // 漏了这句：改完"换下一句之前"重开 App 就白改
            // 连播落到**新一句**时播多少：整句（默认）还是这句记住的选区。
            // 只认"真的换了句"。从别的标签页切回来 src 没变，这时候必须原样保留
            // 当前选区 —— 否则波形上选区还画着、右上角还写着秒数，按播放却放整句。
            let switched = autoPlayedSrc != s.src
            let seg = (switched && loopWhole) ? nil : vm.selection
            if fresh {
                player.pause()
                try? await Player.shared.load(src: s.src)
                vm.zoomAll()
            }
            player.claim(loop: player.loop, times: loopTimes,
                         segment: seg,
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
            // 连播自己跳过来的那一次必须响，跟"自动播"这个开关无关 ——
            // 否则关了自动播之后开连播，换过去就静止，看着像连播坏了。
            if switched {
                let byWalk = autoNextJump
                autoNextJump = false
                autoPlayedSrc = s.src
                // -noplay 是测试钩子（只在 -demo 下有效）：关掉自动播，
                // 才验得了"没播之前打分行不该在"。
                if (autoPlay && !Demo.noAutoPlay) || byWalk {
                    player.play(from: seg?.lowerBound ?? 0)
                }
            }
        }
        // 听完一遍（在放 → 不在放）才把打分四键放出来。见 heardThisOne。
        .onChange(of: player.isPlaying) { was, now in
            if was && !now && !heardThisOne {
                withAnimation(T.anim) { heardThisOne = true }
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
    /// 波形左右两侧的空白：轻触＝播放/暂停（走路时不用瞄准）。
    /// **只许盖在波形上**。原来是挂在整屏 overlay 上还 ignoresSafeArea，
    /// 于是屏幕左右各 30 点从上到下全是它 —— 打分键和控制条的左右边缘被吃掉
    /// 18 点，横屏单手时拇指正落在那儿，点"没听懂"变成暂停，还查不出原因。
    private var edgeTapZone: some View {
        Color.clear
            .frame(width: 30)
            .contentShape(Rectangle())
            .onTapGesture { player.toggle() }
    }

    /// 波形块 + 两侧轻触区（两个方向共用）
    private var waveWithEdgeTaps: some View {
        waveBlock.overlay {
            HStack(spacing: 0) { edgeTapZone; Spacer(minLength: 0); edgeTapZone }
        }
    }

    /// 底部控制条：**一条**横向可滑的长条，竖屏横屏共用。
    /// 顺序＝用得最多的在最左边（拇指落点）：列表、播放、录音、对比、整句、铺满，
    /// 然后才是循环、间隔、显示、倍速。放不下就往左滑，不再占第二行高度
    /// （原来两行 94 点，现在 44 点，省下的 50 点全给波形）。
    private var controlStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                // **最左边必须是播放**。他定的高频顺序是
                // 「播/停、录/停、整句、铺满、几个倍速、显示、听感、收藏、难点」，
                // 而这儿原来第一个是「句子列表」——左手拇指最容易够到的位置
                // 给了一个低频功能，播放被挤到第二格。真机截图上一眼就看出来了。
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18))
                        .frame(width: 56, height: T.hCtl)
                        .background(Color.accentColor).foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: T.ctl, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
                .accessibilityIdentifier("playPause")

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
                        .padding(.horizontal, 11).frame(height: T.hCtl)
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

                // 倍速紧跟在「铺满」后面 —— 他给的高频顺序是
                // 播/停、录/停、整句、铺满、几个倍速、显示、听感，
                // 原来倍速甩在最右边，得横滑到底才够得着。
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

                showMenu                                   // 显示

                // 听感也在他那份高频清单里，原来沉在 ⋯ 菜单第二层
                Label("听感", systemImage: boostHF ? "ear.badge.waveform" : "ear")
                    .fixedSize()
                    .font(.system(size: 12))
                    .foregroundStyle(boostHF ? Color.accentColor : Color.primary.opacity(0.7))
                    .padding(.horizontal, 9).frame(height: T.hCtl)
                    .background(boostHF ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        boostHF.toggle()
                        showHint(boostHF ? "把句尾的 t、s、k 这些辅音抬亮了，连读听得清"
                                         : "关了，恢复原声", 2.5)
                    }
                    .accessibilityElement()
                    .accessibilityLabel("听感")
                    .accessibilityAddTraits(.isButton)

                LoopButton(player: player, times: loopTimes,
                           onToggle: { player.loop.toggle(); player.loop ? player.play() : player.pause() },
                           onHold: { showLoop = true })

                // 连播＝一句播完自动跳下一句（原来只能在设置抽屉里开）
                // 点＝开关连播，按住＝设"换下一句之前停多久"
                Label("连播", systemImage: "text.line.first.and.arrowtriangle.forward")
                    .fixedSize()
                    .font(.system(size: 12))
                    .foregroundStyle(autoNext ? Color.accentColor : Color.primary.opacity(0.7))
                    .padding(.horizontal, 9).frame(height: T.hCtl)
                    .background(autoNext ? Color.accentColor.opacity(0.14) : Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .contentShape(Rectangle())
                    .onTapGesture { autoNext.toggle() }
                    .onLongPressGesture(minimumDuration: 0.25, maximumDistance: 30) { showGap = true }
                    .accessibilityElement()
                    .accessibilityLabel("连播")
                    .accessibilityAddTraits(.isButton)

                gapChip

                // 句子列表：低频，挪到右边来了（原来占着最左那格）
                Button { showList = true } label: {
                    Image(systemName: "list.bullet").font(.system(size: 15))
                        .foregroundStyle(Color.primary.opacity(0.75))
                        .frame(width: 44, height: T.hCtl)
                        .background(Color.primary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: T.ctl, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("句子列表")

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
                        .frame(width: 44, height: T.hCtl)
                }
                .accessibilityIdentifier("moreMenu")   // 测试盯这个，别盯系统的英文名

            }
            .padding(.horizontal, T.side)
        }
        .frame(maxWidth: .infinity)     // 不许按内容自撑宽，否则"内容比自己宽"不成立就滚不动
        .frame(height: T.hCtl + 6)
        // 右缘渐隐：这是全屏最长的一条横滑（要滑近两屏），原来一点提示都没有，
        // 最后一个倍速被屏幕边缘一刀切平，看着像渲染坏了。小句那条早就加了，
        // 同一屏两条横滑不能两套规则。
        .overlay(alignment: .trailing) {
            LinearGradient(colors: [Color(.systemGroupedBackground).opacity(0),
                                    Color(.systemGroupedBackground)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: 24).allowsHitTesting(false)
        }
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

    /// 原文卡"想要"多高。
    /// 优先用量出来的真实文字高度（cardContentH）；量到之前先用按行数估的值兜底。
    /// 以前只有估算，而且估的是**最坏情况**（英文按三行、中文按两行算），
    /// 短句子就白占一大片 —— 体检量出来卡片 269 点、字才占 90 点，中间空一大块。
    private var cardIdeal: CGFloat {
        guard anyText else { return 0 }
        if cardContentH > 1 { return cardContentH }
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

    private func landscape(_ s: Api.Sentence, _ geo: GeometryProxy) -> some View {
        // 这些常数都是体检（-audit）量出来的实际值，不是拍脑袋估的：
        // 横屏控制条 44、打分 34、选区条 30、小句 44，五个 4 点间距。
        //
        // 以前波形按屏高比例硬给（0.52，封顶 260），跟下面几块加起来能顶到
        // 451 点，而横屏内容区只有 393 —— 波形顶上被切掉 31 点、打分整行
        // 掉到屏幕外面。体检早就量出来了，但那时候它只打印不断言，所以一直没人管。
        //
        // 改成先把固定的几块扣掉，剩下多少才分给"波形 + 原文"，保证一定装得下。
        // 一行写成 30+44+44+34+4*5+2 编译器要算半天（真报过 unable to type-check），
        // 拆开写死类型
        let hSel: CGFloat = 30, hChunk: CGFloat = 44
        let hCtl: CGFloat = T.hCtl + 6, hGrade: CGFloat = 34 + 4
        let hGaps: CGFloat = 22 + 6          // 底边多留 6 点，躲开 home 指示条
        let fixed: CGFloat = hSel + hChunk + hCtl + hGrade + hGaps
        let avail: CGFloat = max(120, geo.size.height - fixed)
        let cardHeight: CGFloat = anyText ? min(cardIdeal, avail * 0.42) : 0
        let gapCard: CGFloat = cardHeight > 0 ? 4 : 0
        let waveHeight: CGFloat = max(100, avail - cardHeight - gapCard)
        return VStack(spacing: 4) {
            // 上半截单独一层：跟读结果只浮在这一截上，不许盖住下面的控制条，
            // 也不许盖满波形（盖住就没法圈选区）。
            VStack(spacing: 4) {
                // 横屏波形拿走剩下的全部高度 —— 这是横屏存在的理由
                waveWithEdgeTaps
                    .frame(height: waveHeight)
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
                    // 封顶别用屏高百分比 —— 0.55 屏高在横屏就是 216 点，
                    // 而它上面那一截总共才 253 点，波形只剩 37 点露在外面，
                    // 横屏存在的理由就没了。改成从"波形至少留 90 点"倒推。
                    takePanel
                        .frame(maxHeight: max(120, waveHeight + 4 + 30 + cardHeight - 90))
                        .background(.ultraThinMaterial)
                        .transition(.move(edge: .bottom))
                }
            }
            // 小句固定在底下这组的正上方，位置不随文字多少变
            // 顺序必须跟竖屏一致：小句 → 打分 → 控制条。
            // 原来横屏是"小句 → 控制条 → 打分"，跟竖屏上下颠倒 ——
            // 走路时转个屏，原来点"播放"的位置变成"没听懂"，
            // 一下就提交了一次评分还可能跳下一句，代价不小。
            chunkStrip.auditBlock("小句")
            if gradeShown { gradeRow(34).auditBlock("打分").transition(.opacity) }
            controlStrip.auditBlock("控制条")
        }
        // 宽度交给父视图（.infinity＝给我多少用多少）。
        // 千万别写死 geo.size.width：横屏那是含刘海区的整屏宽，比安全区宽 88 点，
        // 控制条会自认为够宽于是不滚，右边一截藏在点不到的地方（踩过两次）。
        .frame(maxWidth: .infinity)
        .padding(.bottom, 2)
        .overlay { hintOverlay }
        .padding(.top, 2)
    }

    private func portrait(_ s: Api.Sentence, _ geo: GeometryProxy) -> some View {
        // 高度怎么分：先给原文卡它实际需要的（封顶屏高 35%），
        // 再留一截给"左右滑切句"的手指落点（波形自己不接滑动，那儿要拖选区），
        // **剩下的全给波形**。
        // 这样两种情况都不难看：不显示文字时波形长满，显示文字时也不会空出一大片。
        let cardHeight: CGFloat = cardH(geo.size.height)
        let swipeRoom: CGFloat = 96
        // 波形封顶。真机截图上它长到 360，占掉整屏六成 ——
        // 可"圈出听不懂的那半秒"这件事，300 点绰绰有余，再高就是白占，
        // 代价是原文和跟读结果全被挤到屏幕外。
        //
        // 但**封顶得看下面有没有人接这块地**：
        //   勾了原文/译文 → 封顶 300，省下的给原文卡和跟读结果；
        //   一个字都不显示（默认）→ 下面只有一行引导，硬封 300 就空出小半屏灰底
        //     （第一版改完真机截图上就是这样，比原来还难看），所以放宽到 420。
        let room: CGFloat = max(180, geo.size.height - 36 - cardHeight - swipeRoom)
        let waveMax: CGFloat = min(anyText ? 300 : 420, room)
        return VStack(spacing: 0) {
            probeButtons
            VStack(spacing: 8) {
                // 波形按屏高比例给固定高度，剩下的全归原文卡。
                // 原来让波形把富余全吃掉，长到 350 点 —— 太高了，一半就够看够划；
                // 省下来的给"原文 + 录音波形"更值。
                // 录过音之后是上下两条波形（原声在上、自己的在下），才给它长一截。
                // 但**一个字都不显示时**（默认状态：先听声音不看字）下面没人接这块地，
                // 钉死 28% 就会空出小半屏灰底 —— 这种时候让波形自己长满。
                waveWithEdgeTaps
                    .frame(minHeight: 150, maxHeight: waveMax)
                    .padding(.horizontal, T.side).auditBlock("波形")
                    .layoutPriority(1)      // 必须写在最外层：套进 padding 里等于没写
                // 波形以下这一整片都能左右滑着切句；波形自己不接（那儿要拖选区、捏缩放）
                VStack(spacing: 8) {
                    selectionBar.auditBlock("选区条")
                    // 默认一个字都不显示（精听的规矩：先听声音，字是答案）。
                    // 但新用户第一次进来就是一片波形，不知道该干嘛 ——
                    // 空着的那块地给一句话，比留一片灰底强。
                    if !anyText {
                        Text("听不懂就在波形上圈出那半秒，反复听。\n要看原文，点下面控制条里的「显示」。")
                            .font(.system(size: T.f2)).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center).lineSpacing(3)
                            .frame(maxWidth: .infinity)
                            .padding(.top, T.s3).padding(.horizontal, T.s6)
                    }
                    if anyText {
                        // 卡片只要文字实际那么高（封顶屏高 35%），**别吃光剩余空间** ——
                        // 吃光的结果是字占 114 点、卡片 350 点，空出 236 点纯白，
                        // 占整个内容区的三成，界面看着像塌了。省下的高度归波形。
                        sentenceCard(s)
                            .frame(height: cardHeight)
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
                        // 波形压到 300 之后这儿宽裕了，给它更多高度。
                        // 从"波形至少留 90 点看得见"倒推，跟横屏用同一个规矩。
                        .frame(maxHeight: max(260, waveMax + 8 + 36 + cardHeight - 90))
                        .background(.ultraThinMaterial)
                        .transition(.move(edge: .bottom))
                }
            }
            // 小句固定在最底下这组的正上方 —— 位置永远不随文字多少变，闭着眼也能点
            chunkStrip.auditBlock("小句")
            if gradeShown {
                gradeRow.auditBlock("打分")
                    .padding(.top, 6)      // 原来跟小句贴在一起，两行糊成一块
                    .transition(.opacity)
            }
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
            // 这儿原来是 `− A +　− B +` 四个加减按钮，占掉半行 —— 那是程序员思维。
            // 正常人调选区就是**在波形上拖那两条边**，边缘本来就有拖拽热区。
            // 撤掉之后这一行只剩"现在圈的是哪一段"和收藏/难点，清爽多了。
            if let r = vm.selection {
                Label(String(format: "%.2f – %.2fs", r.lowerBound, r.upperBound),
                      systemImage: "selection.pin.in.out")
                    .font(.system(size: T.f2)).monospacedDigit()
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1).fixedSize()
            } else {
                Text("在波形上拖一段，就只反复听那一小段")
                    .font(.system(size: T.f1)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.85)
            }
            Spacer(minLength: 0)
            // 收藏和难点跟"这一句/这段选区"绑在一起，放选区这排比放播放排顺；
            // 底下那排腾出来给整句、铺满这些一直要点的。
            Button { Task { await toggleFav() } } label: {
                Image(systemName: isFav ? "star.fill" : "star")
            }
            .buttonStyle(IconButton(on: isFav))
            .accessibilityLabel("收藏")
            Button { Task { await vm.toggleMark() } } label: { Image(systemName: "flag") }
                .buttonStyle(IconButton(on: !vm.marks.isEmpty))
                .accessibilityLabel("难点")
            if !vm.marks.isEmpty {                      // 没标难点就不占位置
                Button { vm.nextMark() } label: { Image(systemName: "arrow.right.to.line") }
                    .buttonStyle(IconButton())
                    .accessibilityLabel("下一个难点")
            }
        }
        .padding(.horizontal, T.side)
        .frame(height: h)
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
            .padding(.horizontal, 9).frame(height: T.hCtl)
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
            .padding(.horizontal, 11).frame(height: T.hCtl)
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
            // 这根横杠长得跟 iOS sheet 的把手一模一样，用户一定会去点它。
            // 原来只有拖动能关，点了纹丝不动 —— 得连点几下才想起要拖。
            Capsule().fill(Color.primary.opacity(0.22))
                .frame(width: 34, height: 4).padding(.top, 5).padding(.bottom, 3)
                .frame(maxWidth: .infinity, minHeight: 30)      // 手指够得着的热区
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeIn(duration: 0.18)) { showTake = false } }
                .accessibilityIdentifier("takeGrabber")
                .accessibilityLabel("收起结果")
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
                // 下缘渐隐：这块内容常常滚不到底，没提示的时候最后一行被硬切平，
                // 看着像渲染坏了（真机截图上诊断第三条就只露了半行）。
                // 控制条那条横滑早就有渐隐了，同一屏不能两套规矩。
                .overlay(alignment: .bottom) {
                    LinearGradient(colors: [Color(.secondarySystemGroupedBackground).opacity(0),
                                            Color(.secondarySystemGroupedBackground)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 18).allowsHitTesting(false)
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
            .padding(.horizontal, 9).frame(height: T.hCtl)
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
            .frame(width: w, height: T.hCtl)
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
    /// 现在这一屏要不要显示文字。横屏临时收起来不算改用户的偏好。
    private var anyText: Bool { !landHideText && (showEn || showCn || showDef || showDcn) }
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
        // 量一下文字到底占多高，卡片就只要这么多，多的还给波形
        .background(GeometryReader { g in
            Color.clear.preference(key: CardHKey.self, value: g.size.height)
        })
        }
        .onPreferenceChange(CardHKey.self) { h in
            if abs(h - cardContentH) > 1 { cardContentH = h }
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
                // 右边缘渐隐：不加的话最后一块被一刀切平，看着像渲染坏了，
                // 也看不出"还能往右滑"。
                // 用 overlay 盖一层同色渐变，不用 mask —— mask 会不会连手势一起挡掉
                // 各版本说法不一，最后一块小句正好落在渐隐区里，赌不起。
                .overlay(alignment: .trailing) {
                    LinearGradient(colors: [Color(.systemGroupedBackground).opacity(0),
                                            Color(.systemGroupedBackground)],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: 24)
                        .allowsHitTesting(false)
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
                CompareView(diff: d, scoped: vm.selection != nil,
                            sentence: rec.refText.isEmpty ? (store.current?.en ?? "") : rec.refText)
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

    /// 听过或录过才给打分 —— 见 `heardThisOne`
    private var gradeShown: Bool { heardThisOne || rec.hasTake || graded != nil }
    private var gradeRow: some View { gradeRow(34) }
    /// 横屏高度紧张，打分行矮一档（40）；竖屏还是 48
    private func gradeRow(_ h: CGFloat) -> some View {
        // 颜色一律走 Theme 里的打分语义色。系统的 .orange/.green 在浅色底上
        // 只有 1.86:1，字又够不上 WCAG 的"大字"门槛（要 4.5:1），截图上明显发虚。
        HStack(spacing: T.gap) {
            // 颜色沿用他一直看到的那套（会了＝蓝、脱口而出＝绿），只是压暗到够对比度
            grade(1, "没听懂", T.Score.bad, h);    grade(2, "勉强", T.Score.ok, h)
            grade(3, "会了", T.Score.great, h);    grade(4, "脱口而出", T.Score.good, h)
        }
        .padding(.horizontal, T.side).padding(.bottom, 4)
    }
    private func grade(_ q: Int, _ t: String, _ c: Color, _ h: CGFloat = 34) -> some View {
        Button {
            guard let s = store.current else { return }
            graded = q          // 点过哪一档要看得见，不然不知道这句打没打过
            // 排期在本机算、本机存 —— 没网也能打分。这是"脱离服务器"的第一步。
            let due = practice.grade(s.src, q,
                                     score: rec.score.map { Double($0.overall) },
                                     meta: store.meta(s).mapValues { "\($0)" })
            let d = (due - Date().timeIntervalSince1970) / 86400
            showFlash(d < 1 ? "下次 \(max(1, Int(d * 24))) 小时后" : "下次 \(Int(d.rounded())) 天后")
            Task {
                await store.loadDueCount()
                // 顺手同步一份给服务器做备份，成不成都不影响本机
                _ = try? await Api.grade(s.src, q, score: rec.score.map { Double($0.overall) },
                                         meta: store.meta(s))
                await store.refreshProgress()
            }
            if autoNext { step(1) }
        } label: {
            // 字号保持看得清（15/16），压的是**块本身**：高度和留白。
            // 这四个键一次只按一下，色块做那么大反而喧宾夺主。
            // 选中的那一档反着来（实底白字），一眼看得出这句打过分了。
            // 原来点完毫无变化，唯一反馈是波形右上角 11pt 的小字，
            // 走路时根本看不见，录过音时还会被结果面板整个盖住。
            let on = graded == q
            Text(t).font(.system(size: h < 34 ? 15 : 16, weight: .semibold))
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: h)
                .foregroundStyle(on ? Color.white : c)
                .background(on ? c : c.opacity(0.12))
                .overlay(RoundedRectangle(cornerRadius: T.ctl, style: .continuous)
                    .stroke(c.opacity(on ? 0 : 0.30), lineWidth: 1))
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
        // 这几个设置的 onChange 别挂这儿 —— transport 只有竖屏用，
        // 横屏走的是 controlStrip，挂这儿等于横屏改了不生效。统一挂在 content 上。
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
            } label: { Image(systemName: "minus").frame(width: 44, height: T.hCtl) }
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
            } label: { Image(systemName: "plus").frame(width: 44, height: T.hCtl) }
                .buttonStyle(.plain)
            Text(suffix).font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }

    private var gapSheet: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("连播时播", selection: $loopWhole) {
                        Text("整句").tag(true)
                        Text("我划的选区").tag(false)
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("选「整句」：换到下一句就从头放整句。\n"
                         + "选「我划的选区」：这句以前划过哪一段，连播过来就只放那一段，"
                         + "适合把几句里同一个难点连着抠。")
                }
                Section {
                    numberRow("同一段两遍之间", $gapIn, 0...6, "秒", step: 0.2)
                    numberRow("换下一句之前", $gapOut, 0...6, "秒", step: 0.2)
                } footer: {
                    Text("加减一次动 0.2 秒（0.1 太碎，得点半天）；中间的数字点开可以直接打。\n"
                         + "跟不上就调长，顺了就调短。0 就是不停顿，一遍接一遍。")
                }
            }
            .navigationTitle("连播")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarTrailing) {
                Button("完成") { showGap = false } } }
        }
        .presentationDetents([.height(400)])
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
                // 这一屏只放"底下那排够不着"的东西。
                // 凡是主界面已经有按钮的（连播、循环、倍速、间隔、听感、显示、音量键），
                // 这里一律不再重复摆一遍开关，只留一句话指路。
                Section("播放") {
                    Toggle("切到一句就自动播放", isOn: $autoPlay)
                }
                Section {
                    Text("连播 / 连播时播整句还是选区 / 换句停多久：底部「连播」长按")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    Text("循环几遍：底部循环那个牌子长按")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    Text("倍速：底部那一排长按任意一档就能改")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    Text("听感（听辅音）：底部「听感」点一下")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                    Text("音量键切上下句：底部那个小喇叭点一下\n"
                         + "音量＋＝上一句，音量−＝下一句；按完音量自动复位，离开这一屏还给系统。")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                } header: { Text("这些在底下那排上") }
                Section("选区") {
                    Toggle("拖动时吸到词边", isOn: $snap)
                    Toggle("记住每句的选区", isOn: $vm.rememberSelection)
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
    /// 收藏状态以本机为准（没网也要能收藏）；本机没记过才看服务器那份
    private var isFav: Bool {
        guard let src = store.current?.src else { return false }
        if practice.isFav(src) { return true }
        return (store.prog[src]?.fav ?? 0) == 1 && !favTouched.contains(src)
    }
    private func toggleFav() async {
        guard let s = store.current else { return }
        let on = !isFav
        practice.setFav(s.src, on, meta: store.meta(s).mapValues { "\($0)" })
        favTouched.insert(s.src)      // 这句的收藏已经由本机接管，别再被服务器那份盖回去
        try? await Api.fav(s.src, on, meta: store.meta(s))   // 顺手备份
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
        graded = nil
        heardThisOne = false
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
            autoNextJump = true          // 这一跳是连播干的，落地必须出声
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

/// 原文卡文字的真实高度
struct CardHKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
