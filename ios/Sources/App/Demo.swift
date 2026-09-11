import Foundation
import AVFoundation

/// 演示数据：给云端模拟器截图用。
/// 模拟器连不到家里的服务器，所以用 `-demo` 启动时全部走这份假数据 ——
/// 句子长短、小句多少、词边界都覆盖到，正好用来验布局。
enum Demo {
    static var on: Bool { ProcessInfo.processInfo.arguments.contains("-demo") }
    /// 启动时直接跳到某一屏：-screen dict|drill|review|lib|walk
    static var screen: String? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-screen"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    static let word = "excuse"

    /// 给截图用的假比对结果：故意造出"虚词念太长 + 该连读没连 + 一个词不准"
    /// 这三种典型毛病，好验界面在最热闹的情况下长什么样。
    @MainActor static func fakeCompare() -> Compare {
        var c = Compare()
        let src: [(String, Double, Double, Double, Double, Int, Bool, Bool, Bool, Bool, Bool)] = [
            // 词        原声起  原声止  我起    我止   准确 虚词  弱读  该连  我连  重读
            ("Excuse",  0.32, 0.72, 0.30, 0.78,  88, false, false, true,  true,  true),
            ("me",      0.72, 0.88, 0.78, 1.02,  76, true,  true,  false, false, false),
            ("can",     0.96, 1.08, 1.10, 1.42,  62, true,  true,  true,  false, false),
            ("you",     1.08, 1.22, 1.42, 1.66,  71, true,  true,  false, false, false),
            ("tell",    1.28, 1.58, 1.72, 2.02,  84, false, false, true,  true,  true),
            ("me",      1.58, 1.70, 2.02, 2.20,  69, true,  true,  false, false, false),
            ("the",     1.76, 1.84, 2.26, 2.58,  48, true,  true,  true,  false, false),
            ("way",     1.84, 2.12, 2.58, 2.86,  91, false, false, false, false, true),
            ("to",      2.18, 2.28, 2.92, 3.16,  58, true,  true,  true,  false, false),
            ("the",     2.28, 2.36, 3.16, 3.40,  52, true,  true,  true,  false, false),
            ("museum",  2.36, 2.86, 3.40, 3.98,  57, false, false, false, false, true),
            ("please",  2.92, 3.34, 4.04, 4.46,  86, false, false, false, false, true),
        ]
        c.words = src.enumerated().map { i, w in
            Compare.WordDiff(id: i, text: w.0,
                             natStart: w.1, natEnd: w.2, myStart: w.3, myEnd: w.4,
                             accuracy: w.5, isFunction: w.6, natWeak: w.7,
                             linkAfter: w.8, myLinkAfter: w.9, natStressed: w.10)
        }
        c.soundScore = 70; c.rhythmScore = 58; c.linkScore = 33; c.overall = 58
        c.notes = [
            .init(kind: .rhythm, text: "你把 the、to、can 这些虚词念得太重了。the 你用了 320 毫秒，"
                  + "母语者只有 80 毫秒。英语里这类词要弱读到几乎听不见 —— "
                  + "先只念重读的那几个词打拍子，顺了再把虚词像滑音一样塞进空隙。"),
            .init(kind: .liaison, text: "「can you」母语者连成了一个音，你中间断开了。"
                  + "试试把 can 的尾音直接滑进 you，别停顿。"),
            .init(kind: .sound, text: "「museum」这个词念得最不像（57 分），点它单独听一遍原声再跟。"),
        ]
        return c
    }
    /// -select 1 时预先圈一段，方便截图看"有选区"的样子
    static var preselect: Bool { ProcessInfo.processInfo.arguments.contains("-select") }
    /// 模拟器转不了屏，截横屏只能这么来：按横屏的宽高渲染，再整体转 90 度。
    /// 布局算的是"宽比高大就走横屏那套"，这样验出来的尺寸跟真机横屏一致。
    static var land: Bool { ProcessInfo.processInfo.arguments.contains("-land") }
    /// -alignbench：跑手机端对齐的验证屏（跟服务器的结果比对）
    static var alignBench: Bool { on && ProcessInfo.processInfo.arguments.contains("-alignbench") }
    /// -importbench：跑"用户上传音频"的导入精度基准（文本错误率 + 词边界误差）。
    /// 要跟 -usepack 一起用 —— 考卷就是随包那个测试材料包。
    static var importBench: Bool { on && ProcessInfo.processInfo.arguments.contains("-importbench") }
    /// -probe：打开测试后门（只在 -demo 下有效）。
    /// 真机上没法用代码按物理音量键、也没法替 AirPods 点两下，
    /// 但这些动作最终都汇到同一处代码。后门就是从内部触发那处代码，
    /// 于是"按了之后会怎样"能自动验，不用人拿着手机配合。
    static var probe: Bool { on && ProcessInfo.processInfo.arguments.contains("-probe") }
    /// -usepack：启动时把随包带的测试材料包装上（如果还没装）。
    /// 有它才能在模拟器里跑通"装了包 → 在精听台练起来"这条**真实用户流程**。
    static var useTestPack: Bool { on && ProcessInfo.processInfo.arguments.contains("-usepack") }
    /// -mode blank|group|stress|ladder|wordId|dictation|shadow：
    /// 启动直接打开这个练法。云端模拟器只会按启动参数截图，点不进二级页面，
    /// 没有它练法界面在 CI 里一张图都出不来（这次真机锁屏就抓瞎了）。
    static var trainMode: TrainMode? {
        let a = ProcessInfo.processInfo.arguments
        guard on, let i = a.firstIndex(of: "-mode"), i + 1 < a.count else { return nil }
        return TrainMode(rawValue: a[i + 1])
    }
    /// -noplay：关掉"切到一句就自动播"。只给测试用 ——
    /// 有它才验得了"还没听就不该冒出打分行"。
    static var noAutoPlay: Bool { on && ProcessInfo.processInfo.arguments.contains("-noplay") }
    /// -bigfont：把结果字号拉到最大，专门验"字调大之后会不会挤坏"
    static var bigFont: Bool { on && ProcessInfo.processInfo.arguments.contains("-bigfont") }
    /// -audit：布局体检模式 —— 把文字全打开、字号拉大，专门制造"内容最多"的情况
    static var audit: Bool { ProcessInfo.processInfo.arguments.contains("-audit") }
    /// -take：假装刚录完一条，用来截"跟读结果"那块
    static var take: Bool { ProcessInfo.processInfo.arguments.contains("-take") }
    /// 抽屉里的东西光靠主屏截不到：-sheet list|gap|rate 启动就把对应面板打开
    static var sheet: String? {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-sheet"), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    static let sentences: [Api.Sentence] = [
        .init(src: "/demo/1.mp3",
              en: "Excuse me, can you tell me the way to the museum please?",
              cn: "劳驾，请问去博物馆怎么走？", grp: "动词 1a 劳驾〔用于礼貌地引起他人注意〕",
              gnum: "动词 1a", dfe: "used when you want to get someone's attention politely",
              tag: "v1a", kind: "sent", bold: nil),
        .init(src: "/demo/2.mp3", en: "Oh, excuse me. I didn't know anyone was here.",
              cn: "噢，对不起，我不知道这里有人。", grp: "动词 1b 对不起",
              gnum: "动词 1b", dfe: "used to say that you are sorry", tag: "v1b", kind: "sent", bold: nil),
        // 特意放一条很长的，用来验"长句不截断"
        .init(src: "/demo/3.mp3",
              en: "Please excuse my handwriting, but I am writing this letter on the train "
                + "and it is very difficult to keep the pen steady while we are moving so fast.",
              cn: "请原谅我的字迹，我是在火车上写这封信的，车速很快，笔很难拿稳。",
              grp: "动词 2 原谅", gnum: "动词 2",
              dfe: "to forgive someone for something that is not very serious",
              tag: "v2", kind: "sent", bold: nil),
    ]

    static let words: [[Api.Word]] = [
        chop("Excuse me can you tell me the way to the museum please", 2.8),
        chop("Oh excuse me I didn't know anyone was here", 2.4),
        chop("Please excuse my handwriting but I am writing this letter on the train and it is "
             + "very difficult to keep the pen steady while we are moving so fast", 8.6),
    ]

    /// 把一句话按词平均切一下，中间留几个停顿（好让"小句"能切出多段）
    private static func chop(_ text: String, _ dur: Double) -> [Api.Word] {
        let ws = text.split(separator: " ").map(String.init)
        var out: [Api.Word] = []
        var t = 0.15
        let step = (dur - 0.3) / Double(ws.count)
        for (i, w) in ws.enumerated() {
            let len = step * (0.55 + 0.35 * Double((i * 7) % 5) / 4)
            out.append(.init(w: w, s: t, e: t + len))
            t += len + (i % 5 == 4 ? 0.22 : 0.03)     // 每五个词留一个明显停顿
        }
        return out
    }

    /// 合成一段"像人说话"的波形：按词的时间起伏，模拟器里看得出形状
    static func pcm(_ index: Int, sampleRate: Double) -> [Float] {
        let ws = words[min(index, words.count - 1)]
        let dur = (ws.last?.e ?? 2.5) + 0.2
        let n = Int(dur * sampleRate)
        var out = [Float](repeating: 0, count: n)
        for (k, w) in ws.enumerated() {
            let a = Int(w.s * sampleRate), b = min(n, Int(w.e * sampleRate))
            guard b > a else { continue }
            let f = 110.0 + Double((k * 37) % 90)        // 音高换着来
            for i in a..<b {
                let x = Double(i - a) / Double(b - a)
                let env = sin(.pi * x)                    // 每个词两头轻中间重
                let noise = Double((i * 1103515245 % 1000)) / 1000 - 0.5
                out[i] = Float(env * (0.55 * sin(2 * .pi * f * Double(i) / sampleRate)
                                      + 0.25 * noise))
            }
        }
        return out
    }
}
