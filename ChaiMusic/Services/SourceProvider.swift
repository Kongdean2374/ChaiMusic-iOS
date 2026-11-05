import Foundation

struct SourceManifest: Codable {
    var identifier: String
    var name: String
    var version: Int
    var authorizationDescription: String
}
struct StreamCandidate {
    var trackID: UUID
    var recordingID: String
    var url: URL
    var quality: AudioQuality
    var alignmentOffset: Double
}
protocol MusicSourceProvider {
    var manifest: SourceManifest { get }
    func search(query: String) async throws -> [Track]
    func stream(for track: Track) async throws -> StreamCandidate
}

enum QualityUpgradeState: Equatable {
    // 首版沒有外部音源或雙播放器切換路徑，不回報虛假的升級成功。
    case unavailable(reason: String)
}
struct LocalMusicSource: MusicSourceProvider {
    let root: URL
    let tracks: [Track]
    var manifest: SourceManifest {
        SourceManifest(identifier: "local", name: "本機音樂庫", version: 1,
                       authorizationDescription: "僅使用使用者自行匯入且有權使用的檔案")
    }
    func search(query: String) async throws -> [Track] {
        tracks.filter { query.isEmpty || "\($0.title) \($0.artist) \($0.album)".localizedCaseInsensitiveContains(query) }
    }
    func stream(for track: Track) async throws -> StreamCandidate {
        let url = root.appendingPathComponent("Audio").appendingPathComponent(track.fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { throw SourceError.fileMissing }
        return StreamCandidate(trackID: track.id, recordingID: track.id.uuidString, url: url,
                               quality: track.quality, alignmentOffset: 0)
    }
    enum SourceError: LocalizedError {
        case fileMissing
        var errorDescription: String? { "找不到音檔，請重新匯入。" }
    }
}
