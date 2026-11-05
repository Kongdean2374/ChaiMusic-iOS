import Foundation

enum SourceKind: String, Codable, CaseIterable { case webDAV, httpPlugin
    var title: String { self == .webDAV ? "WebDAV 私人音樂庫" : "HTTPS 音源外掛" }
}
struct SourceConfiguration: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var kind: SourceKind
    var baseURL: URL
    var enabled = true
    var priority = 0
}
struct SourceVariant: Identifiable, Codable, Equatable {
    var id = UUID()
    var sourceID: UUID? = nil
    var remoteID: String? = nil
    var url: URL? = nil
    var localFileName: String? = nil
    var recordingID: String? = nil
    var sourceName: String
    var declaredQuality: AudioQuality? = nil
    var alignmentOffset: Double = 0
}
struct PreparedAudio {
    var url: URL
    var quality: AudioQuality
    var duration: Double
    var variantID: UUID? = nil
    var recordingID: String? = nil
}
struct RemoteEntry: Identifiable {
    var id: String
    var title: String
    var artist = "未知演出者"
    var album = "未知專輯"
    var url: URL
    var isDirectory = false
    var duration: Double = 0
    var recordingID: String? = nil
    var variants: [SourceVariant] = []
}
struct SourceSyncStatus {
    var phase: String
    var completed: Bool
    var knownCount: Int
    var message: String? = nil
}
