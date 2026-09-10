import XCTest
@testable import Lingo

/// 七个练法的逻辑测试 —— **不开模拟器、不碰界面、几秒钟跑完**。
///
/// 这是 D3 的验收条件之一：出题规则以后一定还会调（阈值、挖几个空、难度线），
/// 每调一次都开一遍模拟器点一轮，一是慢，二是点不全边界情况
/// （空句子、全是虚词的句子、用户漏打一个词）。
final class TrainKitTests: XCTestCase {

    /// 造一句带时间戳的话：`(词, 时长, 词后停顿)`
    private func sent(_ spec: [(String, Double, Double)]) -> [TrainKit.Word] {
        var t = 0.0
        return spec.map { w, dur, gap in
            let x = TrainKit.Word(w, t, t + dur)
            t += dur + gap
            return x
        }
    }

    /// 典型的一句：实词长、虚词短、for-his 之间零间隙（连读）、excused 后面停一下（意群）
    private var demo: [TrainKit.Word] {
        sent([("Smith", 0.40, 0.03), ("can", 0.10, 0.01), ("be", 0.09, 0.01),
              ("excused", 0.45, 0.22),        // ← 意群边界
              ("for", 0.10, 0.00),            // ← 和 his 连读
              ("his", 0.11, 0.02), ("lack", 0.32, 0.02), ("of", 0.09, 0.01),
              ("interest", 0.40, 0.03), ("in", 0.09, 0.01), ("the", 0.07, 0.01),
              ("course", 0.42, 0.00)])
    }

    // MARK: 拆解

    func testWeakWordsAreTheFunctionWords() {
        let a = TrainKit.analyze(demo)
        let weak = a.weak.map { demo[$0].text }.sorted()
        XCTAssertTrue(weak.contains("the"), "the 必须判成弱读，它是最典型的一个")
        XCTAssertTrue(weak.contains("of"))
        XCTAssertFalse(weak.contains("Smith"), "实词不该被判成弱读")
        XCTAssertFalse(weak.contains("course"))
    }

    func testLiaisonAndGroupBoundary() {
        let a = TrainKit.analyze(demo)
        // for 后面零间隙 → 连读
        let forIdx = demo.firstIndex { $0.text == "for" }!
        XCTAssertTrue(a.linkAfter.contains(forIdx), "for his 之间没有间隙，应判成连读")
        // excused 后面停了 220 毫秒 → 意群边界
        let exIdx = demo.firstIndex { $0.text == "excused" }!
        XCTAssertTrue(a.groupEnd.contains(exIdx), "停了 220 毫秒，应判成意群边界")
        XCTAssertFalse(a.groupEnd.contains(forIdx))
        XCTAssertEqual(a.groups.count, 2, "这句应该被切成两个意群")
    }

    func testStressNeverEmpty() {
        // 全是等长虚词的句子，也必须有一个"重读词"，
        // 否则「只听重读词」那一关会放出一片静音
        let flat = sent([("the", 0.1, 0.05), ("cat", 0.1, 0.05), ("of", 0.1, 0.05)])
        XCTAssertFalse(TrainKit.analyze(flat).stressed.isEmpty)
    }

    // MARK: 难度闸（用户原话："绝大部分人能够的着"）

    func testDifficultyGate() {
        XCTAssertNil(TrainKit.tooHard("Can you tell me the way to the museum please?"))
        // 太长
        let long = Array(repeating: "the", count: 20).joined(separator: " ")
        XCTAssertEqual(TrainKit.tooHard(long), .tooLong(20))
        // 生词太多。**这里必须硬断言词表装上了** ——
        // 写成"词表没装就跳过"的话，哪天资源没打进包，这条测试会一直绿，
        // 而难度闸其实已经形同虚设（全放行）。跳过的测试等于没测。
        XCTAssertTrue(Vocab.loaded, "common5000.txt 没打进 App 包，难度闸等于没有")
        XCTAssertNotNil(TrainKit.tooHard(
            "The perspicacious ichthyologist eschewed obfuscation entirely."))
    }

    func testInflectedWordsCountAsCommon() {
        XCTAssertTrue(Vocab.loaded, "common5000.txt 没打进 App 包")
        // wiped/weaving/hoped 这类"去 e 加 ed/ing"曾经全被当成生词，
        // 难度闸于是滤掉一大批正常句子（云端练法一道题都出不来）
        for w in ["running", "parties", "asked", "doesn't", "books", "moving",
                  "wiped", "weaving", "hoped", "making", "closed"] {
            XCTAssertTrue(Vocab.isCommon(w), "\(w) 是常用词的变形，不该被当成生词")
        }
    }

    // MARK: ① 盲听填空

    func testBlanksPickWeakFunctionWords() {
        let a = TrainKit.analyze(demo)
        let q = BlankQuiz.make(a)
        XCTAssertFalse(q.blanks.isEmpty)
        for i in q.blanks {
            XCTAssertTrue(TrainKit.isFunction(demo[i].text) || a.weak.contains(i),
                          "挖的是 \(demo[i].text)，既不是虚词也没被弱读")
        }
        XCTAssertFalse(q.blanks.contains(0), "第一个词是实词 Smith，不该被挖")
    }

    /// 句首**永远**不挖 —— 哪怕它是虚词。
    /// 真机截图上出过："___ match went all ___ way"，一上来就是空，
    /// 用户连个起步的抓手都没有。
    func testNeverBlankTheFirstWord() {
        // 第一个词是虚词 The：不加这条规则的话它铁定被挖
        let ws = sent([("The", 0.06, 0.02), ("match", 0.30, 0.02), ("went", 0.22, 0.02),
                       ("all", 0.10, 0.01), ("the", 0.06, 0.01), ("way", 0.26, 0.02),
                       ("to", 0.07, 0.01), ("a", 0.05, 0.01), ("finish", 0.34, 0)])
        let q = BlankQuiz.make(TrainKit.analyze(ws))
        XCTAssertFalse(q.blanks.isEmpty, "该挖的还是要挖")
        XCTAssertFalse(q.blanks.contains(0), "句首被挖了：" + q.prompt())
    }

    func testBlankGradingIgnoresCaseAndPunctuation() {
        let q = BlankQuiz.make(TrainKit.analyze(demo))
        let i = q.blanks[0]
        let ans = demo[i].text
        XCTAssertEqual(q.check([i: ans.uppercased() + ","])[i], true)
        XCTAssertEqual(q.check([i: "zzz"])[i], false)
        XCTAssertEqual(q.check([i: "  "])[i], false, "空着不能算对")
    }

    func testNoThreeBlanksInARow() {
        // 一句全是虚词时，也不许挖出连着三个空 —— 那不是听力题是猜谜
        let all = sent(Array(repeating: ("the", 0.06, 0.02), count: 12))
        let q = BlankQuiz.make(TrainKit.analyze(all), max: 8)
        for i in q.blanks {
            XCTAssertFalse(q.blanks.contains(i - 1) && q.blanks.contains(i - 2),
                           "第 \(i) 个词前面已经连着两个空了")
        }
    }

    // MARK: ② 意群断句

    func testGroupGrading() {
        let q = GroupQuiz.make(TrainKit.analyze(demo))
        let truth = q.answer
        let r = q.grade(truth.union([0]))       // 全标对，外加多断一处
        XCTAssertEqual(r.hit, truth)
        XCTAssertTrue(r.missed.isEmpty)
        XCTAssertEqual(r.extra, [0])
        XCTAssertFalse(q.runOn.contains(" "), "出题时不能带空格，那等于把答案给了用户")
    }

    // MARK: ③ 只听重读词

    func testStressPlanCoversWholeSentenceAndDims() {
        let a = TrainKit.analyze(demo)
        let plan = StressQuiz.plan(a)
        XCTAssertFalse(plan.isEmpty)
        XCTAssertEqual(plan.first!.range.lowerBound, demo.first!.s, accuracy: 0.001)
        XCTAssertEqual(plan.last!.range.upperBound, demo.last!.e, accuracy: 0.001)
        // 相邻两段首尾要接上，中间不能留空（留空就是断音）
        for i in 1..<plan.count {
            XCTAssertEqual(plan[i - 1].range.upperBound, plan[i].range.lowerBound, accuracy: 0.001)
        }
        XCTAssertTrue(plan.contains { $0.volume == StressQuiz.dim }, "总得有被压低的部分")
        XCTAssertTrue(plan.contains { $0.volume == 1.0 })
    }

    // MARK: ④ 速度阶梯

    func testLadderClimbsAndFalls() {
        XCTAssertEqual(SpeedLadder.next(from: 0, passed: true), 1)
        XCTAssertEqual(SpeedLadder.next(from: 0, passed: false), 0, "最低档不能再往下掉")
        XCTAssertEqual(SpeedLadder.next(from: 3, passed: true), 3, "顶档不能越界")
        XCTAssertEqual(SpeedLadder.next(from: 2, passed: false), 1)
        XCTAssertFalse(SpeedLadder.cleared(1))
        XCTAssertTrue(SpeedLadder.cleared(2), "1.0 倍速听懂才算过这一句")
    }

    // MARK: ⑤ 听音辨词

    func testWordIdOptionsAlwaysContainAnswerAndNoDuplicate() {
        let pool = ["museum", "music", "amusing", "way", "tell", "please", "course"]
        let q = WordIdQuiz.make(word: "museum", range: 1.0...1.5, pool: pool, seed: 7)
        XCTAssertTrue(q.options.contains("museum"))
        XCTAssertEqual(Set(q.options).count, q.options.count, "选项不能重复")
        XCTAssertEqual(q.options.count, 4)
        XCTAssertEqual(q.options[q.answerIndex], "museum")
        // 同一个种子必须出同样的题，不然测试没法断言、用户返回上一题也会变样
        let again = WordIdQuiz.make(word: "museum", range: 1.0...1.5, pool: pool, seed: 7)
        XCTAssertEqual(q.options, again.options)
    }

    func testWordIdSurvivesTinyPool() {
        let q = WordIdQuiz.make(word: "way", range: 0...1, pool: ["tell"], seed: 3)
        XCTAssertTrue(q.options.contains("way"))
        XCTAssertLessThanOrEqual(q.options.count, 4)
        XCTAssertFalse(q.options.isEmpty)
    }

    // MARK: ⑥ 整句听写

    func testDictationAlignsInsteadOfComparingByPosition() {
        let q = DictationQuiz.make(TrainKit.analyze(demo))
        // 漏打一个词：后面的词不能因为错位全判错
        let typed = "Smith can be excused for his lack interest in the course"
        let r = q.grade(typed)
        XCTAssertEqual(r.total, demo.count)
        XCTAssertEqual(r.tokens.filter { $0.status == .missing }.map(\.text), ["of"])
        XCTAssertEqual(r.right, demo.count - 1, "只错一处，别的都该算对")
    }

    func testDictationFlagsLiaisonAndExtras() {
        let q = DictationQuiz.make(TrainKit.analyze(demo))
        // for his 连读，用户听成了别的
        let r = q.grade("Smith can be excused fer is lack of interest in the course zzz")
        XCTAssertTrue(r.liaisonMisses >= 1, "错在连读点上要能认出来")
        XCTAssertEqual(r.extra, ["zzz"])
        XCTAssertTrue(DictationQuiz.note(r).count > 4)
    }

    func testDictationPerfect() {
        let q = DictationQuiz.make(TrainKit.analyze(demo))
        let r = q.grade(demo.map(\.text).joined(separator: " "))
        XCTAssertEqual(r.right, r.total)
        XCTAssertTrue(r.extra.isEmpty)
        XCTAssertTrue(DictationQuiz.note(r).contains("一字不差"))
    }

    func testDictationEmptyInput() {
        let q = DictationQuiz.make(TrainKit.analyze(demo))
        let r = q.grade("")
        XCTAssertEqual(r.right, 0)
        XCTAssertEqual(r.total, demo.count)
    }

    // MARK: 边界：别在空句子上崩

    func testEmptyAndTinySentences() {
        XCTAssertTrue(TrainKit.analyze([]).words.isEmpty)
        let one = [TrainKit.Word("hi", 0, 0.3)]
        XCTAssertTrue(TrainKit.analyze(one).groups.count <= 1)
        XCTAssertTrue(BlankQuiz.make(TrainKit.analyze(one)).blanks.isEmpty)
        XCTAssertTrue(StressQuiz.plan(TrainKit.analyze([])).isEmpty)
    }
}
