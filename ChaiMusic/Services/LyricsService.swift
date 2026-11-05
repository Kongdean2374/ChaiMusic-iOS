import Foundation
import Combine

@MainActor
final class LyricsService: ObservableObject {
    @Published var state = "尚未尋找歌詞"
    @Published var errorMessage: String?
    @Published var loading = false
    private let sources: SourceManager
    private var generation = UUID()
    private var activeTrackID: UUID?

    init(sources: SourceManager) { self.sources = sources }

    func load(for track: Track, store: LibraryStore) async {
        let request = UUID()
        generation = request
        activeTrackID = track.id
        errorMessage = nil
        guard let identity = track.recordingID, !identity.isEmpty else {
            loading = false
            state = "缺少錄音識別，請匯入對應版本的歌詞"
            return
        }
        loading = true
        state = "正在比對已授權來源的錄音版本…"
        defer { if generation == request { loading = false } }
        do {
            let candidates = try await sources.fetchLyrics(for: track)
            try Task.checkCancellation()
            guard generation == request, activeTrackID == track.id else { return }
            guard let best = LyricsSelection.best(candidates, recordingID: identity) else {
                state = "找不到相符錄音的授權歌詞"
                return
            }
            // 使用者手動匯入具有優先權；不偷偷覆蓋其偏移、翻譯或指定版本。
            let existing = store.tracks.first { $0.id == track.id }?.lyrics
            if let existing, existing.source.hasPrefix("使用者匯入") {
                state = "已找到來源歌詞；保留您匯入的版本"
                return
            }
            var selected = best
            if let existing, existing.recordingID == best.recordingID {
                selected.offset = existing.offset
                if let translated = existing.staticTranslation { selected.staticTranslation = translated }
                for index in selected.lines.indices {
                    if let line = existing.lines.first(where: { abs($0.time - selected.lines[index].time) < 0.01 && $0.text == selected.lines[index].text }) {
                        selected.lines[index].translation = line.translation
                    }
                }
            }
            store.updateLyrics(trackID: track.id, lyrics: selected)
            state = selected.lines.contains(where: { !$0.words.isEmpty }) ? "逐字歌詞可用" : (selected.lines.isEmpty ? "靜態歌詞可用" : "逐行歌詞可用")
        } catch is CancellationError {
            if generation == request { state = "已取消歌詞搜尋" }
        } catch {
            guard generation == request else { return }
            state = "取得歌詞失敗"
            errorMessage = "無法取得歌詞，請至音樂來源確認連線、授權與錄音識別。原有歌詞已保留。"
        }
    }

    func cancel() {
        generation = UUID()
        activeTrackID = nil
        loading = false
        state = "已取消歌詞搜尋"
    }

    func importTranslation(text: String, track: Track, store: LibraryStore) throws {
        guard text.utf8.count <= 2_000_000 else { throw ImportError.tooLarge }
        guard let original = store.tracks.first(where: { $0.id == track.id })?.lyrics else { throw TranslationMappingError.missingOriginal }
        do {
            let translated = try TranslationMapper.apply(text, to: original)
            store.updateLyrics(trackID: track.id, lyrics: translated)
            errorMessage = nil
            state = "使用者提供的翻譯已匯入"
        } catch {
            state = "翻譯匯入失敗"
            throw error
        }
    }

    func importLyrics(text: String, track: Track, store: LibraryStore) throws {
        guard text.utf8.count <= 2_000_000 else { throw ImportError.tooLarge }
        var lyrics = LRCParser.parse(text)
        guard !lyrics.lines.isEmpty || !(lyrics.staticText ?? "").isEmpty else { throw ImportError.empty }
        lyrics.recordingID = track.recordingID
        lyrics.source = "使用者匯入"
        lyrics.confidence = "由您選定錄音版本；可調整時間偏移"
        generation = UUID()
        loading = false
        errorMessage = nil
        store.updateLyrics(trackID: track.id, lyrics: lyrics)
        state = lyrics.lines.isEmpty ? "靜態歌詞已匯入" : "同步歌詞已匯入"
    }

    enum ImportError: LocalizedError {
        case tooLarge, empty, unreadable
        var errorDescription: String? {
            switch self {
            case .tooLarge: return "歌詞檔案超過 2 MB，請選擇較小的文字檔。"
            case .empty: return "檔案沒有可用歌詞，請確認內容不是只有資訊標籤。"
            case .unreadable: return "無法讀取文字，請提供 UTF-8 或 UTF-16 編碼的檔案。"
            }
        }
    }
}
