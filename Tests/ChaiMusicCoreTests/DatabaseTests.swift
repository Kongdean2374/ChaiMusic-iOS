import XCTest
@testable import ChaiMusicCore

final class DatabaseTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ChaiMusic-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testSQLitePersistsThousandTracksAndWholeQueueAcrossReopen() async throws {
        let root = try temporaryRoot()
        let tracks = (0..<1000).map { Track(title: "測試曲 \($0)", fileName: "\($0).wav") }
        var engine = QueueEngine()
        engine.start(ids: tracks.map(\.id), shuffle: true)
        for _ in 0..<531 { _ = engine.advance() }
        engine.state.progress = 45.75
        engine.insertNext(tracks[50].id)
        let first = try LibraryDatabase(root: root)
        let snapshot = LibrarySnapshot(version: 2, tracks: tracks, queue: engine.state)
        first.schedule(snapshot) { _ in }
        try await first.flush()
        let reopened = try LibraryDatabase(root: root)
        let loaded = try reopened.load()
        XCTAssertEqual(loaded.tracks.count, 1000)
        XCTAssertEqual(loaded.queue, engine.state)
        XCTAssertEqual(loaded.tracks.map(\.id), tracks.map(\.id))
    }

    func testLegacyJSONMigrationPreservesOriginalAndMetadata() throws {
        let root = try temporaryRoot()
        var track = Track(title: "舊版收藏", fileName: "legacy.wav")
        track.isFavorite = true
        let snapshot = LibrarySnapshot(tracks: [track], playlists: [Playlist(name: "舊歌單", trackIDs: [track.id])])
        let bytes = try JSONEncoder().encode(snapshot)
        let legacy = root.appendingPathComponent("library.json")
        try bytes.write(to: legacy)
        let database = try LibraryDatabase(root: root)
        let loaded = try database.load()
        XCTAssertEqual(loaded.version, 2)
        XCTAssertEqual(loaded.tracks.first?.isFavorite, true)
        XCTAssertEqual(loaded.playlists.first?.trackIDs, [track.id])
        XCTAssertEqual(try Data(contentsOf: legacy), bytes)
    }

    func testTransactionRemovesDeletedRowsAndPreservesPlaylistOrdering() async throws {
        let root = try temporaryRoot()
        let database = try LibraryDatabase(root: root)
        let a = Track(title: "甲", fileName: "a.wav")
        let b = Track(title: "乙", fileName: "b.wav")
        let playlist = Playlist(name: "順序", trackIDs: [b.id, a.id])
        try await database.replace(with: LibrarySnapshot(tracks: [a, b], playlists: [playlist]))
        let before = try database.load()
        XCTAssertEqual(before.playlists.first?.trackIDs, [b.id, a.id])
        try await database.replace(with: LibrarySnapshot(tracks: [b]))
        let after = try database.load()
        XCTAssertEqual(after.tracks.map(\.id), [b.id])
        XCTAssertTrue(after.playlists.isEmpty)
    }

    func testCoalescedUpdatesKeepLatestSecondsAndQueue() async throws {
        let root = try temporaryRoot()
        let database = try LibraryDatabase(root: root)
        let track = Track(title: "計時", fileName: "timer.wav")
        var snapshot = LibrarySnapshot(tracks: [track])
        snapshot.events = [ListeningEvent(trackID: track.id)]
        for second in 1...25 {
            snapshot.events[0].seconds = Double(second)
            snapshot.queue.progress = Double(second)
            database.schedule(snapshot) { _ in }
        }
        try await database.flush()
        let loaded = try database.load()
        XCTAssertEqual(loaded.events.first?.seconds, 25)
        XCTAssertEqual(loaded.queue.progress, 25)
        XCTAssertEqual(loaded.events.count, 1)
    }

    func testBackupRoundTripIncludesAudioArtworkAndAlternateAndRemovesURLSecrets() async throws {
        let root = try temporaryRoot()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Audio"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Artwork"), withIntermediateDirectories: true)
        let audio = Data([0, 1, 2, 3, 4])
        let artwork = Data([10, 11, 12])
        try audio.write(to: root.appendingPathComponent("Audio/main.wav"))
        try Data([5, 6]).write(to: root.appendingPathComponent("Audio/high.flac"))
        try artwork.write(to: root.appendingPathComponent("Artwork/cover.image"))
        var track = Track(title: "合法測試", fileName: "main.wav", artworkName: "cover.image")
        track.variants = [SourceVariant(url: URL(string: "https://user:password@example.invalid/song?token=secret"), localFileName: "high.flac", sourceName: "測試")]
        let service = BackupService()
        let archive = try await service.export(snapshot: LibrarySnapshot(tracks: [track]), root: root)
        defer { try? FileManager.default.removeItem(at: archive) }
        let target = try temporaryRoot()
        let restored = try await service.restore(from: archive, into: target)
        let restoredTrack = try XCTUnwrap(restored.snapshot.tracks.first)
        XCTAssertEqual(restoredTrack.id, track.id)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("Audio/" + restoredTrack.fileName)), audio)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("Artwork/" + XCTUnwrap(restoredTrack.artworkName))), artwork)
        XCTAssertEqual(restoredTrack.variants?.first?.url?.absoluteString, "https://example.invalid/song")
        XCTAssertEqual(restored.installedFiles.count, 3)
    }

    func testCorruptArchiveDoesNotInstallAnyFiles() async throws {
        let root = try temporaryRoot()
        let service = BackupService()
        let archive = try await service.export(snapshot: LibrarySnapshot(), root: root)
        defer { try? FileManager.default.removeItem(at: archive) }
        var bytes = try Data(contentsOf: archive)
        bytes[bytes.count - 1] ^= 0x01
        try bytes.write(to: archive)
        let target = try temporaryRoot()
        do {
            _ = try await service.restore(from: archive, into: target)
            XCTFail("損毀的備份不應成功")
        } catch {
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: target.path).isEmpty)
        }
    }

    func testBackupRejectsTraversalFilename() async throws {
        let root = try temporaryRoot()
        let service = BackupService()
        do {
            _ = try await service.export(snapshot: LibrarySnapshot(tracks: [Track(title: "不安全", fileName: "../secret")]), root: root)
            XCTFail("不可接受跨目錄音檔路徑")
        } catch { XCTAssertNotNil(error as? BackupService.Failure) }
    }
}
