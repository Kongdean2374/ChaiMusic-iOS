import Foundation

struct AudioQuality: Codable, Equatable {
    var source = "本機檔案"
    var container: String = "未知"
    var codec: String = "未知"
    var bitRate: Double? = nil
    var sampleRate: Double? = nil
    var bitDepth: Int? = nil
    var summary: String {
        let rate = bitRate.map { "\(Int($0 / 1000)) kbps（估計）" } ?? "位元率未知"
        let sample = sampleRate.map { String(format: "%.1f kHz", $0 / 1000) } ?? "取樣率未知"
        let depth = bitDepth.map { "\($0) bit" } ?? "位元深度未知"
        return "\(source) · \(container) / \(codec) · \(rate) · \(sample) · \(depth)"
    }
}
struct LyricWord: Codable, Equatable { var time: Double; var text: String }
struct LyricLine: Codable, Identifiable, Equatable {
    var id = UUID(); var time: Double; var text: String
    var words: [LyricWord] = []; var translation: String? = nil
}
struct Lyrics: Codable, Equatable {
    var lines: [LyricLine] = []; var offset: Double = 0
    var language = "未知"; var source = "使用者匯入"; var version = 1
    var staticText: String? = nil
    var staticTranslation: String? = nil
    var recordingID: String? = nil
    var confidence: String = "使用者提供，未核對錄音版本"
    func activeIndex(at time: Double) -> Int? { lines.lastIndex { $0.time <= time - offset } }
}
struct Track: Codable, Identifiable, Equatable {
    var id = UUID(); var title: String; var artist = "未知演出者"; var album = "未知專輯"
    var fileName: String; var artworkName: String? = nil; var duration: Double = 0
    var quality = AudioQuality(); var isFavorite = false; var importedAt = Date()
    var lyrics: Lyrics? = nil
    var variants: [SourceVariant]? = nil
    var recordingID: String? = nil
}
struct Playlist: Codable, Identifiable, Equatable {
    var id = UUID(); var name: String; var trackIDs: [UUID] = []
}
enum RepeatMode: String, Codable, CaseIterable { case off, all, one
    var title: String { switch self { case .off: return "不循環"; case .all: return "循環歌單"; case .one: return "循環單曲" } }
}
struct QueueState: Codable, Equatable {
    var sourceIDs: [UUID] = []; var order: [UUID] = []; var index = 0
    var pending: [UUID] = []; var history: [UUID] = []; var currentID: UUID? = nil
    var progress: Double = 0; var repeatMode: RepeatMode = .off; var shuffled = false
    var playlistID: UUID? = nil
}
struct ListeningEvent: Codable, Identifiable {
    var id = UUID(); var trackID: UUID; var playlistID: UUID? = nil; var date = Date()
    var seconds: Double = 0; var duration: Double = 0
    var completed = false; var skipped = false; var manual = false; var replay = false
    var completionRatio: Double { duration > 0 ? min(1, seconds / duration) : 0 }
}
struct LibrarySnapshot: Codable {
    var version = 1; var tracks: [Track] = []; var playlists: [Playlist] = []
    var queue = QueueState(); var events: [ListeningEvent] = []
}
