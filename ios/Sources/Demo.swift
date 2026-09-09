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
    /// -select 1 时预先圈一段，方便截图看"有选区"的样子
    static var preselect: Bool { ProcessInfo.processInfo.arguments.contains("-select") }
    /// 模拟器转不了屏，截横屏只能这么来：按横屏的宽高渲染，再整体转 90 度。
    /// 布局算的是"宽比高大就走横屏那套"，这样验出来的尺寸跟真机横屏一致。
    static var land: Bool { ProcessInfo.processInfo.arguments.contains("-land") }
    /// -probe：打开测试后门（只在 -demo 下有效）。
    /// 真机上没法用代码按物理音量键、也没法替 AirPods 点两下，
    /// 但这些动作最终都汇到同一处代码。后门就是从内部触发那处代码，
    /// 于是"按了之后会怎样"能自动验，不用人拿着手机配合。
    static var probe: Bool { on && ProcessInfo.processInfo.arguments.contains("-probe") }
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
