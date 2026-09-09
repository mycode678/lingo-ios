import Foundation
import Accelerate

/// 跟读对比的大脑：把"你念的"和"母语者念的"逐词摆在一起算差别。
///
/// 这是这个 App 最值钱的地方 —— 市面上的跟读打分只给你一个总分，
/// 不告诉你哪儿不对、为什么不对、怎么改。我们能说清楚，靠的是：
///   原声：全库已有词级对齐（fa.db 那 12 小时算出来的）
///   你的：手机上现算（Aligner，已验证和服务器一致，误差 6 毫秒）
/// 两边逐词对上之后，下面这些全是算得出来的，不需要人工标注：
///
///   音准     对齐时每个词的路径得分（GOP，业界给发音打分的标准做法）
///   重音     哪个音节最长最响音最高
///   节奏     每个词占整句的时长比 vs 原声的比
///   连读     两词之间的间隙；原声几乎为零＝该连读
///   语调     句尾音高走向
///
/// 中国人最典型的问题不是发音，是**把每个词念得一样重**——虚词该弱读却重读。
/// 这一点只有逐词时长比对才看得出来，所以下面把它算得最细。
struct Compare {

    /// 一个词的比对结果
    struct WordDiff: Identifiable {
        var id: Int
        var text: String
        var natStart: Double, natEnd: Double      // 原声在这句里的位置
        var myStart: Double, myEnd: Double        // 你的录音里的位置
        var accuracy: Int                         // 0~100，念得像不像
        var natDur: Double { natEnd - natStart }
        var myDur: Double { myEnd - myStart }
        /// 时长比：>1 说明你念得比母语者长（中国人念虚词常常 2 倍以上）
        var durRatio: Double { natDur > 0.01 ? myDur / natDur : 1 }
        var isFunction: Bool                      // 是不是虚词（the/a/to/of/for…）
        var natWeak: Bool                         // 原声里这个词被弱读了
        var linkAfter: Bool                       // 原声里它和下一个词连读
        var myLinkAfter: Bool                     // 你有没有连上
        var natStressed: Bool                     // 原声里它是重读词
    }

    /// 一条诊断：说人话，指出问题并给练法
    struct Note: Identifiable {
        var id = UUID()
        var kind: Kind
        var text: String
        enum Kind { case rhythm, liaison, stress, sound, good }
    }

    var words: [WordDiff] = []
    var notes: [Note] = []
    var overall: Int = 0
    var rhythmScore: Int = 0        // 节奏（时长分布像不像）
    var soundScore: Int = 0         // 音准（GOP 平均）
    var linkScore: Int = 0          // 连读

    /// 英语里最常被弱读的虚词。中国人最容易把它们念得和实词一样重。
    static let functionWords: Set<String> = [
        "a", "an", "the", "to", "of", "for", "and", "or", "but", "at", "in", "on",
        "is", "are", "was", "were", "am", "be", "been", "do", "does", "did",
        "can", "could", "will", "would", "shall", "should", "may", "might", "must",
        "have", "has", "had", "he", "she", "it", "you", "we", "they", "them",
        "his", "her", "its", "our", "their", "your", "my", "me", "him", "us",
        "as", "that", "than", "from", "with", "by", "some", "there"
    ]

    private static func norm(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0 == "'" }
    }

    // MARK: - 主入口

    /// nat：原声的词级对齐（已有）  mine：你的录音对齐结果（手机上现算）
    /// natPCM / myPCM：两段 16k 单声道波形，用来算能量和音高
    static func make(nat: [Api.Word], mine: [Aligner.Word],
                     natPCM: [Float], myPCM: [Float]) -> Compare {
        var c = Compare()
        guard !nat.isEmpty, !mine.isEmpty else { return c }

        // 两边按词一一对上（对齐用的是同一份文本，所以顺序一致；
        // 少数词可能被模型跳过，按文本匹配兜底）
        var pairs: [(Api.Word, Aligner.Word)] = []
        var j = 0
        for n in nat {
            guard j < mine.count else { break }
            if norm(n.w) == norm(mine[j].text) {
                pairs.append((n, mine[j])); j += 1
            } else if let k = mine[j...].firstIndex(where: { norm($0.text) == norm(n.w) }) {
                pairs.append((n, mine[k])); j = k + 1
            }
        }
        guard pairs.count >= 2 else { return c }

        let natTotal = (nat.last!.e - nat.first!.s)
        let myTotal = (mine.last!.end - mine.first!.start)
        let natAvg = natTotal / Double(nat.count)

        for (i, p) in pairs.enumerated() {
            let (n, m) = p
            let natDur = n.e - n.s
            // 原声里被弱读：明显短于平均
            let weak = natDur < natAvg * 0.6
            // 原声里是重读词：明显长 + 能量高
            let stressed = natDur > natAvg * 1.15 && energy(natPCM, n.s, n.e) > 0.6
            // 连读：两词之间几乎没有间隙
            let natGap = i + 1 < pairs.count ? pairs[i+1].0.s - n.e : 1
            let myGap = i + 1 < pairs.count ? pairs[i+1].1.start - m.end : 1
            c.words.append(WordDiff(
                id: i, text: n.w,
                natStart: n.s, natEnd: n.e,
                myStart: m.start, myEnd: m.end,
                accuracy: Int((m.score * 100).rounded()),
                isFunction: functionWords.contains(norm(n.w)),
                natWeak: weak,
                linkAfter: natGap < 0.02,
                myLinkAfter: myGap < 0.02,
                natStressed: stressed))
        }

        // 三个分项
        c.soundScore = avg(c.words.map { $0.accuracy })
        c.rhythmScore = rhythm(c.words, natTotal: natTotal, myTotal: myTotal)
        c.linkScore = liaison(c.words)
        // 总分偏重节奏 —— 中国人的问题主要在这儿，不在单个音
        c.overall = Int((Double(c.soundScore) * 0.4
                       + Double(c.rhythmScore) * 0.4
                       + Double(c.linkScore) * 0.2).rounded())
        c.notes = diagnose(c)
        return c
    }

    // MARK: - 分项

    /// 节奏：每个词占整句的时长比，跟原声比。
    /// 中国人最典型的毛病是"每个词一样重"——虚词该一带而过却念足了时长。
    private static func rhythm(_ ws: [WordDiff], natTotal: Double, myTotal: Double) -> Int {
        guard natTotal > 0.1, myTotal > 0.1 else { return 0 }
        var err = 0.0
        for w in ws {
            let natFrac = w.natDur / natTotal
            let myFrac = w.myDur / myTotal
            // 虚词的偏差加倍计入 —— 那才是听起来"像中式英语"的根源
            err += abs(natFrac - myFrac) * (w.isFunction ? 2 : 1)
        }
        return clamp(100 - Int(err * 260))
    }

    /// 连读：原声连读的地方你连上了几处
    private static func liaison(_ ws: [WordDiff]) -> Int {
        let spots = ws.filter { $0.linkAfter }
        guard !spots.isEmpty else { return 100 }
        let got = spots.filter { $0.myLinkAfter }.count
        return clamp(Int(Double(got) / Double(spots.count) * 100))
    }

    // MARK: - 诊断（说人话）

    private static func diagnose(_ c: Compare) -> [Note] {
        var out: [Note] = []

        // ① 虚词念太长 —— 这是最该先说的一条
        let slowFn = c.words.filter { $0.isFunction && $0.durRatio > 1.6 }
            .sorted { $0.durRatio > $1.durRatio }
        if slowFn.count >= 2 {
            let names = slowFn.prefix(3).map { $0.text }.joined(separator: "、")
            let w = slowFn[0]
            out.append(Note(kind: .rhythm, text:
                "你把 \(names) 这些虚词念得太重了。\(w.text) 你用了 \(ms(w.myDur))，"
                + "母语者只有 \(ms(w.natDur))。英语里这类词要弱读到几乎听不见 ——"
                + "先只念重读的那几个词打拍子，顺了再把虚词像滑音一样塞进空隙。"))
        }

        // ② 该连读的没连上
        let missed = c.words.filter { $0.linkAfter && !$0.myLinkAfter }
        if let m = missed.first, let next = c.words.first(where: { $0.id == m.id + 1 }) {
            out.append(Note(kind: .liaison, text:
                "「\(m.text) \(next.text)」母语者连成了一个音，你中间断开了。"
                + "试试把 \(m.text) 的尾音直接滑进 \(next.text)，别停顿。"))
        }

        // ③ 某个词明显念不准
        if let bad = c.words.filter({ !$0.isFunction }).min(by: { $0.accuracy < $1.accuracy }),
           bad.accuracy < 60 {
            out.append(Note(kind: .sound, text:
                "「\(bad.text)」这个词念得最不像（\(bad.accuracy) 分），"
                + "点它单独听一遍原声再跟。"))
        }

        // ④ 整句太慢/太快
        let natLen = c.words.last.map { $0.natEnd } ?? 0
        let myLen = c.words.last.map { $0.myEnd } ?? 0
        if natLen > 0.5, myLen > natLen * 1.5 {
            out.append(Note(kind: .rhythm, text:
                "整句你比母语者慢了 \(Int((myLen / natLen - 1) * 100))%。"
                + "不用刻意加快每个词，把虚词吞掉，速度自然就上来了。"))
        }

        if out.isEmpty {
            out.append(Note(kind: .good, text:
                c.overall >= 85 ? "这句念得很接近母语者了，节奏和连读都对。"
                                : "整体没有明显问题，可以试着念得再自然一点。"))
        }
        return out
    }

    // MARK: - 小工具

    private static func ms(_ v: Double) -> String { "\(Int(v * 1000)) 毫秒" }
    private static func clamp(_ v: Int) -> Int { max(0, min(100, v)) }
    private static func avg(_ v: [Int]) -> Int {
        v.isEmpty ? 0 : Int((Double(v.reduce(0, +)) / Double(v.count)).rounded())
    }
    /// 一段音频的相对响度（0~1）
    private static func energy(_ pcm: [Float], _ a: Double, _ b: Double) -> Double {
        let sr = 16000.0
        let i0 = max(0, Int(a * sr)), i1 = min(pcm.count, Int(b * sr))
        guard i1 > i0 + 10 else { return 0 }
        var rms: Float = 0
        pcm.withUnsafeBufferPointer { p in
            vDSP_rmsqv(p.baseAddress! + i0, 1, &rms, vDSP_Length(i1 - i0))
        }
        return min(1, Double(rms) * 8)
    }
}
