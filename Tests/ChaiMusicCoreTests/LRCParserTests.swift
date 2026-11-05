import XCTest
@testable import ChaiMusicCore

final class LRCParserTests: XCTestCase {
    func testBasicTimestampsSortAndPreserveUnicode() {
        let lyrics = LRCParser.parse("[00:12.50]第二句\n[00:01.250]第一句 🎵\n[ar:演出者]")
        XCTAssertEqual(lyrics.lines.map(\.text), ["第一句 🎵", "第二句"])
        XCTAssertEqual(lyrics.lines.map(\.time), [1.25, 12.5])
    }

    func testMultipleTimestampsRepeatText() {
        let lyrics = LRCParser.parse("[00:01.00][00:03.00]重複歌詞")
        XCTAssertEqual(lyrics.lines.map(\.time), [1, 3])
        XCTAssertEqual(lyrics.lines.map(\.text), ["重複歌詞", "重複歌詞"])
    }

    func testOffsetUsesSecondsAndActiveLineBoundary() {
        let lyrics = LRCParser.parse("[offset:500]\n[00:01.00]第一句\n[00:03.00]第二句")
        XCTAssertEqual(lyrics.offset, -0.5)
        XCTAssertNil(lyrics.activeIndex(at: 0.49))
        XCTAssertEqual(lyrics.activeIndex(at: 0.5), 0)
        XCTAssertEqual(lyrics.activeIndex(at: 2.5), 1)
    }

    func testMalformedLinesDoNotInventTimedLyrics() {
        let lyrics = LRCParser.parse("\n[broken]內容\n[00:xx]錯誤\n[00:04.00]有效")
        XCTAssertEqual(lyrics.lines.count, 1)
        XCTAssertEqual(lyrics.lines.first?.text, "有效")
        XCTAssertTrue(LRCParser.parse("").lines.isEmpty)
    }

    func testEnhancedWordTimingAndNegativeOffset() {
        let lyrics = LRCParser.parse("[offset:-250]\n[00:01.00]<00:01.00>你<00:01.50>好")
        XCTAssertEqual(lyrics.offset, 0.25)
        XCTAssertEqual(lyrics.lines.first?.text, "你好")
        XCTAssertEqual(lyrics.lines.first?.words.map(\.time), [1, 1.5])
        XCTAssertEqual(lyrics.lines.first?.words.map(\.text), ["你", "好"])
    }
}

final class LyricsV2Tests: XCTestCase {
    func testStaticTextDoesNotInventTimestamps() {
        let lyrics = LRCParser.parse("[lang:zh-Hant-TW]\n一盞茶\n一首歌")
        XCTAssertTrue(lyrics.lines.isEmpty)
        XCTAssertEqual(lyrics.staticText, "一盞茶\n一首歌")
        XCTAssertEqual(lyrics.language, "zh-Hant-TW")
    }

    func testHoursAndMalformedSeconds() {
        let lyrics = LRCParser.parse("[01:02:03.250]長篇錄音\n[00:61.00]無效秒數\n[00:04.50]短句")
        XCTAssertEqual(lyrics.lines.map(\.time), [4.5, 3723.25])
        XCTAssertNil(LRCParser.timestamp("00:60.00"))
        XCTAssertNil(LRCParser.timestamp("nan:01"))
        XCTAssertNil(LRCParser.timestamp("-1:05"))
    }

    func testRepeatedEnhancedLyricsShiftAllWordTimestamps() {
        let lyrics = LRCParser.parse("[00:01.0][00:11.0]<00:01.0>茶<00:01.5>香")
        XCTAssertEqual(lyrics.lines.count, 2)
        XCTAssertEqual(lyrics.lines[1].words.map(\.time), [11, 11.5])
        XCTAssertEqual(lyrics.lines[1].text, "茶香")
    }

    func testInvalidWordOrderFallsBackToLine() {
        let lyrics = LRCParser.parse("[00:01.0]<00:02.0>前<00:01.5>後")
        XCTAssertEqual(lyrics.lines.first?.text, "前後")
        XCTAssertTrue(lyrics.lines.first?.words.isEmpty == true)
    }

    func testRecordingIdentityRejectsSimilarTitleAndPrefersWords() {
        var wrong = LRCParser.parse("[00:01.0]<00:01.0>別的錄音")
        wrong.recordingID = "studio-v2"
        var plain = LRCParser.parse("這是原文")
        plain.recordingID = "studio-v1"
        var timed = LRCParser.parse("[00:01.0]原文")
        timed.recordingID = "studio-v1"
        var words = LRCParser.parse("[00:01.0]<00:01.0>原<00:01.5>文")
        words.recordingID = "studio-v1"
        XCTAssertEqual(LyricsSelection.best([wrong, plain, timed, words], recordingID: "studio-v1"), words)
        XCTAssertNil(LyricsSelection.best([wrong], recordingID: "studio-v1"))
        XCTAssertNil(LyricsSelection.best([wrong, words], recordingID: nil))
    }

    func testTimestampTranslationMatchesEffectiveTimeline() throws {
        let original = LRCParser.parse("[offset:500]\n[00:01.0]Hello\n[00:02.0]Music")
        let result = try TranslationMapper.apply("[00:00.5]你好\n[00:01.5]音樂", to: original)
        XCTAssertEqual(result.lines.map(\.translation), ["你好", "音樂"])
        XCTAssertEqual(result.offset, -0.5)
        XCTAssertEqual(result.lines.map(\.time), original.lines.map(\.time))
    }

    func testPlainTranslationRequiresExactLineCount() throws {
        let original = LRCParser.parse("[00:01.0]Hello\n[00:02.0]Music")
        let result = try TranslationMapper.apply("你好\n音樂", to: original)
        XCTAssertEqual(result.lines.map(\.translation), ["你好", "音樂"])
        XCTAssertThrowsError(try TranslationMapper.apply("只有一行", to: original))
        XCTAssertThrowsError(try TranslationMapper.apply("[00:20.0]版本不相符", to: original))
    }

    func testStaticTranslationAndBlankTimedBreak() throws {
        let original = LRCParser.parse("Hello\nMusic")
        let translated = try TranslationMapper.apply("你好\n音樂", to: original)
        XCTAssertEqual(translated.staticTranslation, "你好\n音樂")
        XCTAssertEqual(translated.staticText, "Hello\nMusic")
        let timed = LRCParser.parse("[00:01.0]Hello\n[00:02.0]\n[00:03.0]Music")
        XCTAssertEqual(timed.lines.count, 3)
        XCTAssertEqual(try TranslationMapper.apply("你好\n音樂", to: timed).lines.map(\.translation), ["你好", nil, "音樂"])
    }

    func testOffsetAndSeekKeepOriginalWordTimeline() {
        var lyrics = LRCParser.parse("[00:01.0]<00:01.0>第<00:01.5>一\n[00:04.0]第二")
        lyrics.offset = 0.5
        XCTAssertEqual(lyrics.activeIndex(at: 4.7), 1)
        XCTAssertEqual(lyrics.activeIndex(at: 2.0), 0)
        XCTAssertNil(lyrics.activeIndex(at: 1.0))
        XCTAssertEqual(lyrics.lines[0].words.map(\.time), [1, 1.5])
    }
}
