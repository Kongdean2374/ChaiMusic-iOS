import Foundation
import XCTest
@testable import ChaiMusicCore

final class ListeningMathTests: XCTestCase {
    func testSeekPauseStallAndClockJumpsDoNotInflateSeconds() {
        XCTAssertEqual(ListeningMath.audibleSeconds(mediaDelta: 0.1, wallDelta: 0.11, playing: true, seeking: false), 0.1)
        XCTAssertEqual(ListeningMath.audibleSeconds(mediaDelta: 90, wallDelta: 0.1, playing: true, seeking: false), 0)
        XCTAssertEqual(ListeningMath.audibleSeconds(mediaDelta: 0.1, wallDelta: 0.1, playing: false, seeking: false), 0)
        XCTAssertEqual(ListeningMath.audibleSeconds(mediaDelta: 0.1, wallDelta: 0.1, playing: true, seeking: true), 0)
        XCTAssertEqual(ListeningMath.audibleSeconds(mediaDelta: 0, wallDelta: 0.1, playing: true, seeking: false), 0)
        XCTAssertEqual(ListeningMath.audibleSeconds(mediaDelta: -2, wallDelta: 0.1, playing: true, seeking: false), 0)
        XCTAssertEqual(ListeningMath.audibleSeconds(mediaDelta: .nan, wallDelta: 0.1, playing: true, seeking: false), 0)
    }

    func testCrossMidnightIsAllocatedToBothDaysWithoutDuplicatingTime() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 3_600))
        let midnight = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 5)))
        let slices = ListeningMath.split(seconds: 2, endingAt: midnight.addingTimeInterval(0.75), calendar: calendar)
        XCTAssertEqual(slices.count, 2)
        XCTAssertEqual(slices[0].seconds, 1.25, accuracy: 0.0001)
        XCTAssertEqual(slices[1].seconds, 0.75, accuracy: 0.0001)
        XCTAssertEqual(slices.reduce(0) { $0 + $1.seconds }, 2, accuracy: 0.0001)
        XCTAssertEqual(calendar.component(.day, from: slices[0].start), 4)
        XCTAssertEqual(calendar.component(.day, from: slices[1].start), 5)
    }

    func testCalendarDaySplitHandlesDaylightSaving() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let start = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 8)))
        let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))
        XCTAssertEqual(end.timeIntervalSince(start), 23 * 3_600)
        let slices = ListeningMath.split(seconds: end.timeIntervalSince(start), endingAt: end, calendar: calendar)
        XCTAssertEqual(slices.count, 1)
        XCTAssertEqual(slices[0].seconds, 23 * 3_600)
    }

    func testInvalidTimeDoesNotCreateHistory() {
        XCTAssertTrue(ListeningMath.split(seconds: 0, endingAt: Date()).isEmpty)
        XCTAssertTrue(ListeningMath.split(seconds: -.infinity, endingAt: Date()).isEmpty)
        XCTAssertTrue(ListeningMath.split(seconds: .nan, endingAt: Date()).isEmpty)
    }
}
