import Foundation

/// 分级听力训练的地基：**从词级对齐里把"母语者到底怎么念的"算出来**。
///
/// 为什么这是竞争力所在（用户原话）：
/// > 我知道的别的软件没有分级听力练习系统，我看了一扇贝听力口语app上来就给一个
/// > 普通用户完全听不懂的材料练习，然后不断的弹购买会员窗口，做app没有诚意。
///
/// 别家做不了不是因为技术难，是因为**没有全库的词级时间戳**。有了它，
/// 下面这四样全是算出来的，不用人工标一条：
///
///   弱读词   时长明显短于本句平均（虚词被一带而过）→ 正好是中国人听不见的那些
///   连读点   两词之间几乎没有间隙
///   重读词   时长长 + 响度高 → 母语者大脑真正抓取的信息
///   意群边界 词间间隙明显变大 → 该在哪儿断句
///
/// **这个文件不碰界面、不碰数据库、不用单例**，纯输入输出，
/// 所以七个练法的逻辑能单元测试，不用每改一条规则就开一次模拟器。
enum TrainKit {

    /// 一个词及它在音频里的位置
    struct Word: Equatable {
        var text: String
        var s: Double
        var e: Double
        init(_ text: String, _ s: Double, _ e: Double) { self.text = text; self.s = s; self.e = e }
        var dur: Double { max(0, e - s) }
    }

    /// 一句话被拆解成什么样
    struct Analysis: Equatable {
        var words: [Word]
        /// 被弱读的词（下标）
        var weak: Set<Int> = []
        /// 重读词（下标）
        var stressed: Set<Int> = []
        /// 这个词和**下一个词**连读
        var linkAfter: Set<Int> = []
        /// 意群在这个词之后断开（最后一个词不算）
        var groupEnd: Set<Int> = []

        /// 意群切分结果：每段是词下标区间
        var groups: [ClosedRange<Int>] {
            guard !words.isEmpty else { return [] }
            var out: [ClosedRange<Int>] = []
            var start = 0
            for i in 0..<words.count {
                if groupEnd.contains(i) || i == words.count - 1 {
                    out.append(start...i); start = i + 1
                }
            }
            return out
        }
    }

    // MARK: - 阈值
    //
    // 这几个数跟 `Compare` 里判弱读/连读/重读用的是同一套，故意保持一致 ——
    // 跟读打分说"你这个词该弱读"，训练里挖的空就得正好是它，
    // 两处标准不一样的话，用户会觉得 App 自相矛盾。

    /// 时长短于本句平均的这个倍数 → 弱读
    static let weakRatio = 0.6
    /// 时长长于本句平均的这个倍数（且够响）→ 重读
    static let stressRatio = 1.15
    /// 词间间隙小于这个 → 母语者连读了
    static let linkGap = 0.02
    /// 词间间隙大于这个 → 意群边界
    static let groupGap = 0.15

    /// 拆解一句话。
    ///
    /// `energy` 给的是每个词的相对响度（0~1），来自 `Compare.energy` 那一套。
    /// 拿不到就传 nil —— 那时只按时长判，重读会判得宽一点，但不会判错方向。
    static func analyze(_ words: [Word], energy: [Double]? = nil) -> Analysis {
        var a = Analysis(words: words)
        guard words.count >= 2 else { return a }

        let avg = words.map(\.dur).reduce(0, +) / Double(words.count)
        guard avg > 0 else { return a }

        for (i, w) in words.enumerated() {
            let loud = energy.flatMap { i < $0.count ? $0[i] : nil }
            // 弱读：短，而且不是被判成重读的那些。
            // 实词也可能短（"go"），所以再要求它是虚词或者短得离谱。
            if w.dur < avg * weakRatio,
               isFunction(w.text) || w.dur < avg * 0.45 {
                a.weak.insert(i)
            }
            // 重读：长 + 响。拿不到响度时只看时长（宁可少判，不能乱判）
            if w.dur > avg * stressRatio, (loud ?? 1) > 0.6, !isFunction(w.text) {
                a.stressed.insert(i)
            }
            if i + 1 < words.count {
                let gap = words[i + 1].s - w.e
                if gap < linkGap { a.linkAfter.insert(i) }
                if gap > groupGap { a.groupEnd.insert(i) }
            }
        }
        // 一个重读词都没有的句子（全是虚词或者全一样长）：
        // 退而求其次，把最长的那个实词当重读，免得"只听重读词"练法放出一片静音。
        if a.stressed.isEmpty {
            if let k = words.indices.filter({ !isFunction(words[$0].text) })
                .max(by: { words[$0].dur < words[$1].dur }) {
                a.stressed.insert(k)
            }
        }
        return a
    }

    // MARK: - 词

    /// 归一化：比对答案、查词表都走它。撇号要留（don't / it's）。
    static func norm(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "'" }
    }

    /// 虚词表跟跟读打分共用一份，别再各写各的
    static func isFunction(_ w: String) -> Bool {
        Compare.functionWords.contains(norm(w))
    }

    /// 把一句话切成词（只用来判难度；练习里的词一律用对齐结果，那才有时间戳）
    static func tokenize(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init).map(norm).filter { !$0.isEmpty }
    }

    // MARK: - 难度闸
    //
    // 用户原话：
    // > 练习的句子最好不要包含太复杂的单词，大部分人的单词量很小……
    // > 就像现在朗文词典里的例句差不多，绝大部分人能够的着。
    //
    // 光有这句话没法验收，所以定成两个**机器能判**的数：
    //   句长 ≤ 18 词，且 90% 以上的词落在常用 5000 词表里。
    // 数字以后可以调，但必须有 —— 不然"句子不要太难"这条验收是空的。

    static let maxWords = 18
    static let minCommonRatio = 0.9

    /// 为什么这句不适合当练习题；`nil` = 可以用
    enum TooHard: Equatable {
        case tooLong(Int)
        case rareWords([String])
        var reason: String {
            switch self {
            case .tooLong(let n):   return "太长了（\(n) 词，上限 \(TrainKit.maxWords)）"
            case .rareWords(let w): return "生词太多：\(w.prefix(4).joined(separator: "、"))"
            }
        }
    }

    static func tooHard(_ text: String) -> TooHard? {
        let ws = tokenize(text)
        guard !ws.isEmpty else { return .tooLong(0) }
        if ws.count > maxWords { return .tooLong(ws.count) }
        let rare = ws.filter { !Vocab.isCommon($0) }
        let ratio = 1 - Double(rare.count) / Double(ws.count)
        if ratio < minCommonRatio { return .rareWords(Array(Set(rare)).sorted()) }
        return nil
    }

    static func isEasyEnough(_ text: String) -> Bool { tooHard(text) == nil }
}

/// 常用词表。
///
/// 5000 个最常用的英文单词，一行一个，随 App 打包（36KB）。
/// 来源是公开的英文词频表（Google 十万词表取前 5000），**只有词、没有释义**，
/// 跟朗文那份有版权的内容没有关系 —— 词表本身不构成受版权保护的内容。
///
/// 用它干一件事：判断一句话"是不是绝大部分人能够得着"。
enum Vocab {
    private static let set: Set<String> = {
        guard let u = Bundle.main.url(forResource: "common5000", withExtension: "txt"),
              let s = try? String(contentsOf: u, encoding: .utf8) else {
            // 词表读不到时**不能把所有句子都判成难**（那样训练直接没题）。
            // 空集合配合下面的 isCommon 返回 true，等于放行 —— 宁可题偏难，不能没题。
            return []
        }
        return Set(s.split(whereSeparator: \.isNewline).map(String.init))
    }()

    /// 词表加载失败时一律放行，见上面
    static var loaded: Bool { !set.isEmpty }

    static func isCommon(_ w: String) -> Bool {
        guard loaded else { return true }
        let x = TrainKit.norm(w)
        if x.isEmpty || x.allSatisfy(\.isNumber) { return true }
        if set.contains(x) { return true }
        // 词形变化：词表是原形表，练习句里是活用形。
        // 只做最常见的几种回退，做不全没关系 —— 放行比误判成生词好。
        for suf in ["s", "es", "ed", "d", "ing", "'s", "n't", "'ll", "'re", "'ve"]
        where x.hasSuffix(suf) {
            let stem = String(x.dropLast(suf.count))
            if stem.count >= 2, set.contains(stem) { return true }
            // wiped → wipe，weaving → weave，making → make
            // **这条最容易漏**：英语里去 e 再加 ed/ing 是最常见的变形之一，
            // 少了它，wiped / weaving / hoped 全被当成生词，
            // 难度闸会把一大批正常句子误判成"生词太多"而不出题
            // （云端 CI 上三句测试句全军覆没，就是这么暴露出来的）。
            if stem.count >= 2, set.contains(stem + "e") { return true }
            // running → run（去掉重复的尾字母）
            if let last = stem.last, stem.count >= 3,
               stem.dropLast().last == last, set.contains(String(stem.dropLast())) { return true }
            // parties → party
            if stem.hasSuffix("i"), set.contains(stem.dropLast() + "y") { return true }
        }
        return false
    }
}
