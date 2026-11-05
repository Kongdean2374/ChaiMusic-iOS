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
