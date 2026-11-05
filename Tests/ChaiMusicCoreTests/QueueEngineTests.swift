import Foundation
import XCTest
@testable import ChaiMusicCore

final class QueueEngineTests: XCTestCase {
    private func ids(_ count: Int) -> [UUID] { (0..<count).map { _ in UUID() } }

    func test531SongShufflePlaysEverySongExactlyOnce() {
        let songs = ids(531)
        var engine = QueueEngine()
        engine.start(ids: songs, shuffle: true)
        var played: [UUID] = []
        while let current = engine.state.currentID {
            played.append(current)
            _ = engine.advance(automatic: true)
        }
        XCTAssertEqual(played.count, 531)
        XCTAssertEqual(Set(played), Set(songs))
        XCTAssertEqual(Set(played).count, played.count)
        XCTAssertNil(engine.advance())
    }

    func testQueueHasNo25Or50SongPageBoundary() {
        for count in [24, 25, 26, 49, 50, 51, 531] {
            let songs = ids(count)
            var engine = QueueEngine()
            engine.start(ids: songs)
            var played: [UUID] = []
            while let current = engine.state.currentID {
                played.append(current)
                _ = engine.advance()
            }
            XCTAssertEqual(played, songs, "歌曲數量：\(count)")
        }
    }

    func testStateSurvivesAtomicSnapshotRoundTripAndResumesOrder() throws {
        let songs = ids(51)
        var engine = QueueEngine()
        let playlist = UUID()
        engine.start(ids: songs, shuffle: true, playlistID: playlist)
        _ = engine.advance()
        engine.insertNext(songs[0])
        engine.state.progress = 37.5
        engine.state.repeatMode = .all
        var snapshot = LibrarySnapshot()
        snapshot.queue = engine.state
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("snapshot.json")
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        let decoded = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: url))
        XCTAssertEqual(decoded.queue, engine.state)
        var restored = QueueEngine(state: decoded.queue)
        XCTAssertEqual(restored.state.playlistID, playlist)
        XCTAssertEqual(restored.state.progress, 37.5)
        XCTAssertEqual(restored.upcomingIDs, engine.upcomingIDs)
        XCTAssertEqual(restored.advance(), engine.advance())
    }

    func testInsertNextAndPreviousPreserveContinuation() {
        let songs = ids(4)
        var engine = QueueEngine()
        engine.start(ids: Array(songs.prefix(3)))
        engine.insertNext(songs[3])
        XCTAssertEqual(engine.upcomingIDs, [songs[3], songs[1], songs[2]])
        XCTAssertEqual(engine.advance(), songs[3])
        XCTAssertEqual(engine.previous(), songs[0])
        XCTAssertEqual(engine.advance(), songs[3])
        XCTAssertEqual(engine.advance(), songs[1])
        XCTAssertEqual(engine.advance(), songs[2])
        XCTAssertNil(engine.advance())
    }

    func testRepeatOneOnlyRepeatsOnAutomaticAdvance() {
        let songs = ids(2)
        var engine = QueueEngine()
        engine.start(ids: songs)
        engine.state.repeatMode = .one
        engine.state.progress = 10
        XCTAssertEqual(engine.advance(automatic: true), songs[0])
        XCTAssertEqual(engine.state.progress, 0)
        XCTAssertEqual(engine.advance(), songs[1])
    }

    func testRepeatAllWrapsAndRepeatOffEnds() {
        let songs = ids(2)
        var engine = QueueEngine()
        engine.start(ids: songs)
        engine.state.repeatMode = .all
        XCTAssertEqual(engine.advance(), songs[1])
        XCTAssertEqual(engine.advance(), songs[0])
        engine.state.repeatMode = .off
        XCTAssertEqual(engine.advance(), songs[1])
        XCTAssertNil(engine.advance())
    }

    func testDeletedCurrentPendingAndHistoryAreRemoved() {
        let songs = ids(5)
        var engine = QueueEngine()
        engine.start(ids: songs)
        _ = engine.advance()
        engine.insertNext(songs[4])
        engine.reconcile(validIDs: Set([songs[2], songs[3]]))
        XCTAssertEqual(engine.state.currentID, songs[2])
        XCTAssertEqual(engine.upcomingIDs, [songs[3]])
        XCTAssertEqual(engine.state.sourceIDs, [songs[2], songs[3]])
        XCTAssertTrue(engine.state.history.isEmpty)
        XCTAssertEqual(engine.advance(), songs[3])
        XCTAssertNil(engine.advance())
    }

    func testUpcomingRemovalAndMoveAffectPlayback() {
        let songs = ids(5)
        var engine = QueueEngine()
        engine.start(ids: songs)
        engine.removeUpcoming(at: IndexSet(integer: 1))
        XCTAssertEqual(engine.upcomingIDs, [songs[1], songs[3], songs[4]])
        engine.moveUpcoming(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(engine.upcomingIDs, [songs[4], songs[1], songs[3]])
        XCTAssertEqual(engine.advance(), songs[4])
        XCTAssertEqual(engine.advance(), songs[1])
        XCTAssertEqual(engine.advance(), songs[3])
        XCTAssertNil(engine.advance())
    }

    func testShuffleToggleKeepsCurrentAndAllRemainingSongs() {
        let songs = ids(51)
        var engine = QueueEngine()
        engine.start(ids: songs)
        _ = engine.advance()
        engine.setShuffle(true)
        XCTAssertEqual(engine.state.currentID, songs[1])
        XCTAssertEqual(Set(engine.upcomingIDs), Set(songs.dropFirst(2)))
        engine.setShuffle(false)
        XCTAssertEqual(engine.upcomingIDs, Array(songs.dropFirst(2)))
    }

    func testEmptyInputDuplicatesAndExplicitStart() {
        var engine = QueueEngine()
        engine.start(ids: [])
        XCTAssertNil(engine.state.currentID)
        XCTAssertNil(engine.advance())
        let songs = ids(3)
        engine.start(ids: songs + songs, startID: songs[1])
        XCTAssertEqual(engine.state.sourceIDs, songs)
        XCTAssertEqual(engine.state.currentID, songs[1])
        engine.start(ids: songs, startID: songs[1], shuffle: true)
        XCTAssertEqual(engine.state.currentID, songs[1])
        XCTAssertEqual(Set(engine.state.order), Set(songs))
    }
}
