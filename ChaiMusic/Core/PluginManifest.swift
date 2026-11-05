import Foundation

/// 外掛必須明確宣告音訊提供權限；宣告不是平台的授權保證。
struct PluginManifest: Codable {
    var schemaVersion: Int
    var id: String
    var name: String
    var authorization: String
    var health: String
    var catalog: String
    var search: String
    var stream: String
    var lyrics: String?
    var candidates: String?

    func validate() throws {
        guard schemaVersion == 1, !id.isEmpty, id.count <= 128, !name.isEmpty,
              !authorization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              [health, catalog, search, stream].allSatisfy({ !$0.isEmpty }) else {
            throw SourceFailure.invalidManifest
        }
    }
}
struct PluginTrack: Codable {
    var id: String
    var title: String
    var artist: String?
    var album: String?
    var duration: Double?
    var recordingID: String?
    var variants: [PluginVariant]?
}
struct PluginVariant: Codable {
    var id: String
    var recordingID: String
    var quality: AudioQuality?
    var alignmentOffset: Double?
}
struct PluginPage: Codable {
    var items: [PluginTrack]
    var nextCursor: String?
    var complete: Bool
}
struct PluginStream: Codable {
    var url: URL
    var recordingID: String
    var authorization: String
    var expiresAt: Date?
}
struct PluginLyricsResponse: Codable {
    var recordingID: String
    var authorization: String
    var language: String?
    var lrc: String?
    var text: String?
    var translationLRC: String?
}
struct PluginCandidatesResponse: Codable {
    var recordingID: String
    var variants: [PluginVariant]
}
struct PluginHealth: Codable { var ok: Bool }

enum SourceFailure: LocalizedError {
    case invalidURL, invalidManifest, missingSource, credentials, unauthorized, forbidden
    case network, redirect, invalidResponse, tooLarge, tooManyItems, incomplete, cancelled
    case fileMissing, unsupportedAudio, identityMismatch, permissionMissing, emptyResult
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "請使用有效的 HTTPS 正式網址；來源根網址不能包含帳密、查詢參數或片段。"
        case .invalidManifest: return "外掛 manifest 欄位或版本不相容，需 ChaiMusic 協定第 1 版。"
        case .missingSource: return "這個來源已移除或停用，請先到音樂來源設定。"
        case .credentials: return "無法讀取安全儲存的來源憑證，請重新加入來源。"
        case .unauthorized: return "來源認證失敗，請確認帳號與密碼。"
        case .forbidden: return "來源拒絕讀取，請確認您有檔案存取權限。"
        case .network: return "無法連線來源，請確認網路、網址與伺服器狀態。"
        case .redirect: return "來源要求重新導向；為保護認證資料，請改用伺服器的最終 HTTPS 網址。"
        case .invalidResponse: return "來源回應不符合協定或內容無效。"
        case .tooLarge: return "來源檔案超過首版安全上限（音訊 512 MB；清單 8 MB）。"
        case .tooManyItems: return "來源超過首版同步上限，請選較小的資料夾；舊索引已保留。"
        case .incomplete: return "來源沒有完整完成同步；保留既有完整索引，未把部分結果當成完整曲庫。"
        case .cancelled: return "來源操作已取消。"
        case .fileMissing: return "找不到本機音檔，請重新匯入。"
        case .unsupportedAudio: return "音訊無法由系統解碼，或含有受保護內容。"
        case .identityMismatch: return "來源回傳不同錄音版本，已拒絕使用。"
        case .permissionMissing: return "來源未提供音訊或歌詞權利說明，已拒絕讀取。"
        case .emptyResult: return "找不到符合的來源內容。"
        }
    }
}
