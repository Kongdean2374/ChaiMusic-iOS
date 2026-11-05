import Foundation
import XCTest
@testable import ChaiMusicCore

final class SourceContractIntegrationTests: XCTestCase {
    func testPublishedFixtureMatchesRealClientSchema() throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = project.appendingPathComponent("fixtures/demo")
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("manifest.json").path) else {
            throw XCTSkip("需先以 generate_fixtures.py --publish-demo fixtures/demo 產生原創素材。")
        }
        let decoder = JSONDecoder()
        func decode<T: Decodable>(_ type: T.Type, _ path: String) throws -> T {
            try decoder.decode(type, from: Data(contentsOf: root.appendingPathComponent(path)))
        }
        let manifest = try decode(PluginManifest.self, "manifest.json")
        try manifest.validate()
        let health = try decode(PluginHealth.self, manifest.health)
        XCTAssertTrue(health.ok)
        let page = try decode(PluginPage.self, manifest.catalog)
        XCTAssertTrue(page.complete)
        XCTAssertNil(page.nextCursor)
        XCTAssertEqual(page.items.count, 2)
        let first = try XCTUnwrap(page.items.first)
        let recordingID = try XCTUnwrap(first.recordingID)
        let variants = try XCTUnwrap(first.variants)
        XCTAssertEqual(variants.count, 2)
        XCTAssertTrue(variants.allSatisfy { $0.recordingID == recordingID })
        for variant in variants {
            let response = try decode(PluginStream.self, "stream/\(variant.id).json")
            XCTAssertEqual(response.recordingID, recordingID)
            XCTAssertEqual(response.url.scheme, "https")
            XCTAssertFalse(response.authorization.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(response.url.lastPathComponent).path))
        }
        let lyrics = try decode(PluginLyricsResponse.self, "lyrics/\(recordingID).json")
        XCTAssertEqual(lyrics.recordingID, recordingID)
        XCTAssertFalse(lyrics.authorization.isEmpty)
        XCTAssertFalse(LRCParser.parse(try XCTUnwrap(lyrics.lrc)).lines.isEmpty)
        XCTAssertFalse(LRCParser.parse(try XCTUnwrap(lyrics.translationLRC)).lines.isEmpty)
        let candidates = try decode(PluginCandidatesResponse.self, "candidates/\(recordingID).json")
        XCTAssertEqual(candidates.recordingID, recordingID)
        XCTAssertEqual(candidates.variants.map(\.id), variants.map(\.id))
        XCTAssertNotEqual(page.items.last?.recordingID, recordingID)
    }

    func testUnversionedOrUnlicensedManifestIsRejected() throws {
        let json = #"{"schemaVersion":99,"id":"test","name":"test","authorization":"","health":"health","catalog":"catalog","search":"search","stream":"stream"}"#
        let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(json.utf8))
        XCTAssertThrowsError(try manifest.validate())
    }
}
