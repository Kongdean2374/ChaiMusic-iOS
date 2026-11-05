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
        for count in [24, 25, 26, 49, 50, 51, 100, 531, 1_000] {
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
    func testEverySupportedSizeRestoresExactRoundAtManyPositions() throws {
        for count in [25, 50, 100, 531, 1_000] {
            let songs = ids(count)
            var engine = QueueEngine()
            engine.start(ids: songs, shuffle: true)
            let initialOrder = engine.state.order
            var played: [UUID] = []
            for position in 0..<count {
                if position % 23 == 0 {
                    engine.state.progress = 19.25
                    let data = try JSONEncoder().encode(engine.state)
                    engine = QueueEngine(state: try JSONDecoder().decode(QueueState.self, from: data))
                    XCTAssertEqual(engine.state.order, initialOrder)
                    XCTAssertEqual(engine.state.progress, 19.25)
                    XCTAssertEqual(engine.state.index, position)
                }
                played.append(try XCTUnwrap(engine.state.currentID))
                _ = engine.advance(automatic: true)
            }
            XCTAssertEqual(played, initialOrder)
            XCTAssertEqual(Set(played).count, count)
            XCTAssertEqual(engine.state.history, initialOrder)
            XCTAssertNil(engine.state.currentID)
        }
    }

    func testFullRepeatConsumesAll531BeforeStartingNextRound() {
        let songs = ids(531)
        var engine = QueueEngine()
        engine.start(ids: songs, shuffle: true)
        engine.state.repeatMode = .all
        for _ in 0..<2 {
            var seen = Set<UUID>()
            for _ in songs {
                guard let current = engine.state.currentID else { XCTFail("過早結束完整佇列"); return }
                XCTAssertTrue(seen.insert(current).inserted)
                _ = engine.advance(automatic: true)
            }
            XCTAssertEqual(seen, Set(songs))
        }
    }

    func testDeletionWhileManualInsertIsPlayingPreservesBaseCursor() {
        let songs = ids(6)
        var engine = QueueEngine()
        engine.start(ids: Array(songs.prefix(4)))
        engine.insertNext(songs[4])
        engine.insertNext(songs[5])
        XCTAssertEqual(engine.advance(), songs[5])
        engine.reconcile(validIDs: Set([songs[0], songs[1], songs[3], songs[4]]))
        XCTAssertEqual(engine.state.currentID, songs[4])
        XCTAssertEqual(engine.advance(), songs[1])
        XCTAssertEqual(engine.advance(), songs[3])
        XCTAssertNil(engine.advance())
        XCTAssertEqual(engine.state.sourceIDs, [songs[0], songs[1], songs[3]])
    }

    func testCrossPlaylistStartResetsHistoryAndManualQueue() {
        let songs = ids(10)
        var engine = QueueEngine()
        engine.start(ids: Array(songs.prefix(5)), playlistID: UUID())
        _ = engine.advance()
        engine.insertNext(songs[9])
        let nextPlaylist = UUID()
        engine.start(ids: Array(songs.suffix(5)), shuffle: true, playlistID: nextPlaylist)
        XCTAssertTrue(engine.state.pending.isEmpty)
        XCTAssertTrue(engine.state.history.isEmpty)
        XCTAssertEqual(engine.state.playlistID, nextPlaylist)
        XCTAssertEqual(Set(engine.state.sourceIDs), Set(songs.suffix(5)))
        XCTAssertEqual(engine.state.progress, 0)
    }

    func testRestoringMalformedCursorDoesNotTrap() {
        let songs = ids(3)
        var state = QueueState()
        state.sourceIDs = songs + songs
        state.order = songs
        state.index = Int.max
        state.progress = .infinity
        var engine = QueueEngine(state: state)
        XCTAssertEqual(engine.state.sourceIDs, songs)
        XCTAssertEqual(engine.state.progress, 0)
        XCTAssertTrue(engine.upcomingIDs.isEmpty)
        engine.reconcile(validIDs: Set(songs))
        XCTAssertNil(engine.advance())
    }

}
