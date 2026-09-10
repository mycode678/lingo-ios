import XCTest
@testable import Lingo

/// 导入（D2a）和视频跟随（D6）里那些**纯算的部分**。
///
/// 这两块最容易出的错都不会崩，只会静悄悄地不对：
/// 分句分出一堆两个词的碎片、词级时间戳算错半秒 —— 用户只会觉得"这 App 不准"。
/// 所以拿真实格式的样本钉住。
final class MediaTests: XCTestCase {

    // MARK: 分句（导入）

    @MainActor
    func testSplitKeepsSentencesShortEnoughToPractice() {
        let s = ImportService.shared
        let text = "Hello there. This is a very long run on sentence that just keeps going and "
                 + "going without any punctuation at all so it has to be cut somewhere sensible."
        let out = s.split(text)
        XCTAssertFalse(out.isEmpty)
        for x in out {
            XCTAssertLessThanOrEqual(x.split(separator: " ").count, TrainKit.maxWords,
                                     "分出来的句子超过了难度闸的上限，练法直接用不了：\(x)")
            XCTAssertGreaterThanOrEqual(x.split(separator: " ").count, 3, "太碎：\(x)")
        }
    }

    @MainActor
    func testSplitMergesTinyFragments() {
        let out = ImportService.shared.split("Yeah. Right. I went to the shop this morning.")
        // "Yeah." "Right." 单独成句没法练，要并进去
        XCTAssertTrue(out.allSatisfy { $0.split(separator: " ").count >= 3 },
                      "还有两个词的碎片：\(out)")
    }

    // MARK: 链接解析（视频）

    func testVideoIDFromEveryLinkShapeUsersActuallyPaste() {
        let cases = [
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "https://youtu.be/dQw4w9WgXcQ",
            "https://www.youtube.com/embed/dQw4w9WgXcQ",
            "https://www.youtube.com/shorts/dQw4w9WgXcQ",
            "https://m.youtube.com/watch?v=dQw4w9WgXcQ&t=30s",
            "dQw4w9WgXcQ"
        ]
        for c in cases {
            XCTAssertEqual(YouTube.videoID(c), "dQw4w9WgXcQ", "解析不了：\(c)")
        }
        XCTAssertNil(YouTube.videoID("这不是链接"))
    }

    // MARK: 字幕解析（这是词级跟随的地基）

    /// 自动字幕：`segs[].tOffsetMs` 就是词级时间戳，必须原样用上
    func testJSON3AutoCaptionsGiveRealWordTimings() throws {
        let json = """
        {"events":[
          {"tStartMs":1000,"dDurationMs":2000,"segs":[
            {"utf8":"Peppa","tOffsetMs":0},
            {"utf8":" and","tOffsetMs":400},
            {"utf8":" her","tOffsetMs":700},
            {"utf8":" family","tOffsetMs":1100}]},
          {"tStartMs":3500,"dDurationMs":1500,"segs":[
            {"utf8":"have","tOffsetMs":0},
            {"utf8":" bought","tOffsetMs":600}]}
        ]}
        """
        let t = try YouTube.parseJSON3(Data(json.utf8))
        XCTAssertTrue(t.wordLevel, "自带 tOffsetMs 的必须判成词级")
        XCTAssertEqual(t.cues.count, 2)
        XCTAssertEqual(t.cues[0].words.map(\.text), ["Peppa", "and", "her", "family"])
        XCTAssertEqual(t.cues[0].words[1].start, 1.4, accuracy: 0.001)
        // 一个词的结束＝下一个词的开始，中间不能留空（留空会看见高亮闪断）
        XCTAssertEqual(t.cues[0].words[0].end, t.cues[0].words[1].start, accuracy: 0.001)
        XCTAssertEqual(t.cues[0].text, "Peppa and her family")
    }

    /// 人工字幕：只有整句时间，词的位置只能估 —— 但必须**如实标成估的**
    func testJSON3PlainCaptionsAreMarkedAsEstimated() throws {
        let json = """
        {"events":[{"tStartMs":0,"dDurationMs":4000,"segs":[
            {"utf8":"I"},{"utf8":" understand"},{"utf8":" you"}]}]}
        """
        let t = try YouTube.parseJSON3(Data(json.utf8))
        XCTAssertFalse(t.wordLevel, "没有 tOffsetMs 就不能说自己是词级的")
        let w = t.cues[0].words
        XCTAssertEqual(w.count, 3)
        // 按词长摊开：understand 最长，占的时间必须最多
        XCTAssertGreaterThan(w[1].end - w[1].start, w[0].end - w[0].start)
        XCTAssertEqual(w[0].start, 0, accuracy: 0.001)
        XCTAssertEqual(w[2].end, 4.0, accuracy: 0.01)
        // 首尾相接，不留缝
        XCTAssertEqual(w[0].end, w[1].start, accuracy: 0.001)
    }

    func testJSON3SkipsEmptyAndNewlineSegments() throws {
        let json = """
        {"events":[{"tStartMs":0,"dDurationMs":1000,"segs":[
            {"utf8":"hi","tOffsetMs":0},{"utf8":"\\n"},{"utf8":" ","tOffsetMs":500}]}]}
        """
        let t = try YouTube.parseJSON3(Data(json.utf8))
        XCTAssertEqual(t.cues[0].words.map(\.text), ["hi"])
    }

    func testJSON3RejectsGarbage() {
        XCTAssertThrowsError(try YouTube.parseJSON3(Data("not json".utf8)))
        XCTAssertThrowsError(try YouTube.parseJSON3(Data("{\"events\":[]}".utf8)))
    }

    /// 找当前词：二分要找对，而且播完之后不能一直亮着最后一个词
    func testWordIndexTracksTime() {
        let ws = [YouTube.Word(text: "a", start: 0, end: 1),
                  YouTube.Word(text: "b", start: 1, end: 2),
                  YouTube.Word(text: "c", start: 2, end: 3)]
        XCTAssertEqual(YouTube.wordIndex(ws, at: 0.5), 0)
        XCTAssertEqual(YouTube.wordIndex(ws, at: 1.0), 1)
        XCTAssertEqual(YouTube.wordIndex(ws, at: 2.9), 2)
        XCTAssertNil(YouTube.wordIndex(ws, at: 9), "早过完了还亮着，用户会以为卡住了")
        XCTAssertNil(YouTube.wordIndex([], at: 1))
    }
}
