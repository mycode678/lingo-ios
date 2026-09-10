import Foundation

/// 七个练法 —— **全部是纯逻辑**：给一句话的词级对齐，出题、判卷。
/// 不碰界面、不碰数据库、不碰播放器，所以每一条都能单元测试。
///
/// 为什么是这七个：先认中国人听不懂的病因，再一个病配一个药 ——
///
/// | 病因 | 表现 | 对症的练法 |
/// |---|---|---|
/// | ① 听不出连读、弱读、失爆 | 每个词都认识，连起来不认识 | 盲听填空 |
/// | ② 跟不上速度 | 前一句还在想，后一句过去了 | 速度阶梯 |
/// | ③ 想听清每个词 | 结果什么都没抓住 | 只听重读词 |
/// | ④ 词是"眼睛认识、耳朵不认识" | 只见过拼写没听过声音 | 听音辨词 |
/// | ⑤ 意群断错 | 不知道哪儿该断 | 意群断句 |
/// | 综合 | | 整句听写 |
/// | 输出 | | 影子跟读（已有，在精听台） |
enum TrainMode: String, CaseIterable, Identifiable, Codable {
    case blank      // ① 盲听填空
    case group      // ② 意群断句
    case stress     // ③ 只听重读词
    case ladder     // ④ 速度阶梯
    case wordId     // ⑤ 听音辨词
    case dictation  // ⑥ 整句听写
    case shadow     // ⑦ 影子跟读

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blank:     return "盲听填空"
        case .group:     return "意群断句"
        case .stress:    return "只听重读"
        case .ladder:    return "速度阶梯"
        case .wordId:    return "听音辨词"
        case .dictation: return "整句听写"
        case .shadow:    return "影子跟读"
        }
    }

    /// 一句话说清"治什么"。用户是小白，不能只给个名字。
    var cure: String {
        switch self {
        case .blank:     return "专挖母语者一带而过的词——正好是你听不见的那些"
        case .group:     return "标出你听到的停顿，跟母语者实际断的地方比"
        case .stress:    return "只放重读的那几个词，看你其实不需要听清每个词"
        case .ladder:    return "从 0.6 倍慢速一档档往上，听懂了才升"
        case .wordId:    return "放一个词的原声，四选一——治「眼睛认识耳朵不认识」"
        case .dictation: return "听完打出来，逐词比对，还告诉你哪个是连读听错的"
        case .shadow:    return "念一遍，跟母语者逐词比时长、连读和发音"
        }
    }

    var icon: String {
        switch self {
        case .blank:     return "square.dashed"
        case .group:     return "text.word.spacing"
        case .stress:    return "waveform.path"
        case .ladder:    return "speedometer"
        case .wordId:    return "ear"
        case .dictation: return "keyboard"
        case .shadow:    return "mic"
        }
    }

    /// 一轮出几道题（默认值，够练三五分钟）
    var defaultCount: Int {
        switch self {
        case .blank: return 8
        case .group: return 5
        case .stress: return 6
        case .ladder: return 5
        case .wordId: return 10
        case .dictation: return 4
        case .shadow: return 6
        }
    }
}

// MARK: - ① 盲听填空

/// 不是随机挖空，是**专挖被弱读的那些词**。
/// 中国人听力的坎九成在虚词：`for his` 母语者连成 /fərɪz/，
/// 你每个词都认识，但那一串就是听不出来。
struct BlankQuiz: Equatable {
    var words: [TrainKit.Word]
    /// 被挖掉的词下标（从小到大）
    var blanks: [Int]

    static func make(_ a: TrainKit.Analysis, max: Int = 5) -> BlankQuiz {
        let n = a.words.count
        guard n >= 3 else { return BlankQuiz(words: a.words, blanks: []) }
        // 挖多少：句子越长挖越多，但两端要有靠山，不能挖成一片空白
        let cap = Swift.max(2, Swift.min(max, n / 3))

        // 先挖"弱读 + 虚词"（最该练的），不够再补纯弱读的，还不够补虚词
        let weakFn = a.words.indices.filter { a.weak.contains($0) && TrainKit.isFunction(a.words[$0].text) }
        let weakOnly = a.words.indices.filter { a.weak.contains($0) && !weakFn.contains($0) }
        let fnOnly = a.words.indices.filter { TrainKit.isFunction(a.words[$0].text) && !a.weak.contains($0) }

        var picked: [Int] = []
        for group in [weakFn, weakOnly, fnOnly] {
            for i in group where picked.count < cap {
                // 别挖出连着三个空 —— 那不是听力题，是猜谜
                if picked.contains(i - 1) && picked.contains(i - 2) { continue }
                picked.append(i)
            }
            if picked.count >= cap { break }
        }
        return BlankQuiz(words: a.words, blanks: picked.sorted())
    }

    /// 题面：挖掉的位置显示成下划线
    func prompt(_ filled: [Int: String] = [:]) -> String {
        words.indices.map { i in
            guard blanks.contains(i) else { return words[i].text }
            let v = filled[i]?.trimmingCharacters(in: .whitespaces) ?? ""
            return v.isEmpty ? "___" : v
        }.joined(separator: " ")
    }

    /// 判卷：只看词本身，大小写和标点不计较
    func check(_ answers: [Int: String]) -> [Int: Bool] {
        var out: [Int: Bool] = [:]
        for i in blanks {
            let got = TrainKit.norm(answers[i] ?? "")
            out[i] = !got.isEmpty && got == TrainKit.norm(words[i].text)
        }
        return out
    }

    func score(_ answers: [Int: String]) -> (right: Int, total: Int) {
        let r = check(answers)
        return (r.values.filter { $0 }.count, blanks.count)
    }
}

// MARK: - ② 意群断句

/// 母语者不是一个词一个词说的，是一串一串说的。
/// 让用户先标他听到的停顿，再跟真实停顿比 —— 差在哪儿一眼就看见。
struct GroupQuiz: Equatable {
    var words: [TrainKit.Word]
    /// 正确答案：在这些词之后断
    var answer: Set<Int>

    static func make(_ a: TrainKit.Analysis) -> GroupQuiz {
        // 最后一个词后面的"断"不算题
        var ans = a.groupEnd
        if let last = a.words.indices.last { ans.remove(last) }
        return GroupQuiz(words: a.words, answer: ans)
    }

    struct Result: Equatable {
        var hit: Set<Int> = []      // 标对了
        var missed: Set<Int> = []   // 母语者断了你没听出来
        var extra: Set<Int> = []    // 你多断了一次
        var right: Int { hit.count }
        var total: Int { hit.count + missed.count }
    }

    func grade(_ user: Set<Int>) -> Result {
        Result(hit: user.intersection(answer),
               missed: answer.subtracting(user),
               extra: user.subtracting(answer))
    }

    /// 出题时把空格去掉 —— 有空格等于把答案送给用户了
    var runOn: String { words.map(\.text).joined() }
}

// MARK: - ③ 只听重读词

/// 先只放重读的那几个词，其余压低到 20%，让用户猜整句；再放完整句。
/// 这一条是给用户建立"我不需要听清每个词"这个认知的 —— 理论和练习是同一件事。
enum StressQuiz {
    /// 播放计划：一段段音量不同的区间，交给播放器按顺序放
    struct Chunk: Equatable {
        var range: ClosedRange<Double>
        var volume: Float
        var stressed: Bool
    }

    /// 非重读部分压到多少
    static let dim: Float = 0.2

    static func plan(_ a: TrainKit.Analysis) -> [Chunk] {
        guard let first = a.words.first, let last = a.words.last else { return [] }
        var out: [Chunk] = []
        var t = first.s
        for (i, w) in a.words.enumerated() {
            let on = a.stressed.contains(i)
            // 词之间的空隙并进前一段，免得切出几十个碎片让播放器忙不过来
            let end = i + 1 < a.words.count ? a.words[i + 1].s : last.e
            let chunk = Chunk(range: t...Swift.max(t + 0.01, end),
                              volume: on ? 1.0 : dim, stressed: on)
            // 跟前一段同音量就合并
            if var prev = out.last, prev.stressed == chunk.stressed {
                prev.range = prev.range.lowerBound...chunk.range.upperBound
                out[out.count - 1] = prev
            } else {
                out.append(chunk)
            }
            t = chunk.range.upperBound
        }
        return out
    }

    /// 用户"听到的"是哪几个词（给完答案后展示用）
    static func heard(_ a: TrainKit.Analysis) -> [String] {
        a.words.indices.filter { a.stressed.contains($0) }.map { a.words[$0].text }
    }
}

// MARK: - ④ 速度阶梯

/// 同一句 0.6 → 0.8 → 1.0 → 1.2，听懂了才升。
/// 记录你卡在哪一档，久了能看出"你的听力速度上限"在往上走 —— 这是别家没有的成长曲线。
enum SpeedLadder {
    static let rates: [Float] = [0.6, 0.8, 1.0, 1.2]

    /// 答对/答错之后该到第几档（0 起）
    static func next(from level: Int, passed: Bool) -> Int {
        passed ? Swift.min(rates.count - 1, level + 1) : Swift.max(0, level - 1)
    }

    /// 这一档算不算"过了这一句"——到 1.0 倍速听懂就算过关，1.2 是彩蛋
    static func cleared(_ level: Int) -> Bool { level >= 2 }

    static func label(_ level: Int) -> String {
        let r = rates[Swift.max(0, Swift.min(rates.count - 1, level))]
        return String(format: "%.1gx", Double(r))
    }
}

// MARK: - ⑤ 听音辨词

/// 放一个词的原声，四选一。数据现成 —— 词级切分本来就有。
/// 治的是"这个词我认识，但没听过它被说出来的样子"。
struct WordIdQuiz: Equatable {
    var answer: String
    /// 这个词在音频里的位置
    var range: ClosedRange<Double>
    var options: [String]
    var answerIndex: Int { options.firstIndex(of: answer) ?? 0 }

    /// `pool` 是干扰项的来源（同一批材料里的别的词）。
    /// `seed` 让选项顺序可复现 —— 不然测试没法断言。
    static func make(word: String, range: ClosedRange<Double>,
                     pool: [String], seed: UInt64 = 1) -> WordIdQuiz {
        let target = TrainKit.norm(word)
        var rng = SeededRNG(seed)
        // 干扰项挑"长得像的"：首字母相同或长度接近，才有区分度。
        // 全挑毫不相干的词，用户闭着眼也能选对，练不到东西。
        let cands = Array(Set(pool.map(TrainKit.norm)))
            .filter { $0 != target && $0.count >= 2 }
            .sorted { lhs, rhs in
                let a = similarity(target, lhs), b = similarity(target, rhs)
                return a == b ? lhs < rhs : a > b
            }
        var picked = Array(cands.prefix(8)).shuffled(using: &rng).prefix(3).map { $0 }
        // 材料太少凑不齐三个干扰项：有几个用几个，不硬编假词
        picked.append(target)
        return WordIdQuiz(answer: target, range: range,
                          options: picked.shuffled(using: &rng))
    }

    private static func similarity(_ a: String, _ b: String) -> Int {
        var s = 0
        if a.first == b.first { s += 2 }
        if a.last == b.last { s += 1 }
        s += Swift.max(0, 3 - abs(a.count - b.count))
        return s
    }
}

/// 可复现的随机数：出题顺序必须能在测试里断言，系统随机数做不到
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13; state ^= state >> 7; state ^= state << 17
        return state
    }
}

// MARK: - ⑥ 整句听写

/// 听完打出来，逐词比对。错的词标出来，还告诉你**是不是因为连读听错的** ——
/// 比如把 "an apple" 听成 "a napple"：对齐数据知道那儿是连读，别的 App 不知道。
struct DictationQuiz: Equatable {
    var words: [TrainKit.Word]
    var analysis: TrainKit.Analysis

    static func make(_ a: TrainKit.Analysis) -> DictationQuiz {
        DictationQuiz(words: a.words, analysis: a)
    }

    enum Status: Equatable { case ok, wrong, missing }

    struct Token: Equatable {
        var text: String            // 正确答案
        var typed: String?          // 用户打的（missing 时为 nil）
        var status: Status
        /// 这个词跟前一个或后一个词是连读的 —— 错在这儿多半是连读没听出来
        var atLiaison: Bool
    }

    struct Result: Equatable {
        var tokens: [Token]
        var extra: [String]         // 用户多打出来的词
        var right: Int { tokens.filter { $0.status == .ok }.count }
        var total: Int { tokens.count }
        /// 错的词里有几个卡在连读点上
        var liaisonMisses: Int { tokens.filter { $0.status != .ok && $0.atLiaison }.count }
    }

    func grade(_ typed: String) -> Result {
        let ref = words.map { TrainKit.norm($0.text) }
        let got = TrainKit.tokenize(typed)
        let ops = align(ref, got)

        var tokens: [Token] = []
        var extra: [String] = []
        for op in ops {
            switch op {
            case .match(let i, let j):
                let liais = analysis.linkAfter.contains(i) || analysis.linkAfter.contains(i - 1)
                tokens.append(Token(text: words[i].text, typed: got[j],
                                    status: ref[i] == got[j] ? .ok : .wrong, atLiaison: liais))
            case .del(let i):
                let liais = analysis.linkAfter.contains(i) || analysis.linkAfter.contains(i - 1)
                tokens.append(Token(text: words[i].text, typed: nil,
                                    status: .missing, atLiaison: liais))
            case .ins(let j):
                extra.append(got[j])
            }
        }
        return Result(tokens: tokens, extra: extra)
    }

    /// 一句话诊断（说人话，不给一堆数字）
    static func note(_ r: Result) -> String {
        if r.total > 0 && r.right == r.total && r.extra.isEmpty { return "一字不差，这句你已经听透了。" }
        if r.liaisonMisses >= 2 {
            let ws = r.tokens.filter { $0.status != .ok && $0.atLiaison }.prefix(2).map(\.text)
            return "错的地方大多卡在连读上（\(ws.joined(separator: "、"))）。"
                + "母语者把它们粘成了一个音，你按一个词一个词去听就断不开。"
        }
        let missedFn = r.tokens.filter { $0.status != .ok && TrainKit.isFunction($0.text) }
        if missedFn.count >= 2 {
            return "漏掉的基本都是虚词（\(missedFn.prefix(3).map(\.text).joined(separator: "、"))）。"
                + "它们被一带而过，本来就不该指望听清 —— 靠语法补出来就行。"
        }
        if r.right * 2 < r.total { return "这句偏难，先用 0.6 倍速走一遍速度阶梯再回来。" }
        return "大体听对了，把标红的几个词单独再听一遍。"
    }

    // MARK: 对齐（编辑距离回溯）
    //
    // 不能按位置直接比：用户漏打一个词，后面全会错位，一句话本来只错一处，
    // 判出来满屏红。所以要做真正的序列对齐。

    private enum Op { case match(Int, Int), del(Int), ins(Int) }

    private func align(_ a: [String], _ b: [String]) -> [Op] {
        let n = a.count, m = b.count
        var d = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { d[i][0] = i }
        for j in 0...m { d[0][j] = j }
        for i in 1...max(n, 1) where n > 0 {
            for j in 1...max(m, 1) where m > 0 {
                let c = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = Swift.min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + c)
            }
        }
        var out: [Op] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0,
               d[i][j] == d[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1) {
                out.append(.match(i - 1, j - 1)); i -= 1; j -= 1
            } else if i > 0, d[i][j] == d[i - 1][j] + 1 {
                out.append(.del(i - 1)); i -= 1
            } else {
                out.append(.ins(j - 1)); j -= 1
            }
        }
        return out.reversed()
    }
}
