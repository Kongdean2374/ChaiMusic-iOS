import Foundation
import Combine

@MainActor
final class LibraryStore: ObservableObject {
    @Published var tracks: [Track] = []
    @Published var playlists: [Playlist] = []
    @Published var events: [ListeningEvent] = []
    @Published var errorMessage: String?
    var queue = QueueState()
    let root: URL
    private var canSave = true
    static let tracksDidChange = Notification.Name("ChaiMusic資料庫歌曲異動")
    private var snapshotURL: URL { root.appendingPathComponent("library.json") }

    init() {
        root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ChaiMusic", isDirectory: true)
        do {
            for directory in [root, root.appendingPathComponent("Audio"), root.appendingPathComponent("Artwork")] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            if FileManager.default.fileExists(atPath: snapshotURL.path) {
                let snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: Data(contentsOf: snapshotURL))
                guard snapshot.version == 1 else { throw CocoaError(.fileReadCorruptFile) }
                tracks = snapshot.tracks
                playlists = snapshot.playlists
                events = snapshot.events
                var engine = QueueEngine(state: snapshot.queue)
                engine.reconcile(validIDs: Set(tracks.map(\.id)))
                queue = engine.state
            }
        } catch {
            canSave = false
            errorMessage = "無法讀取資料庫，已保留原始資料並停止寫入。請先備份原始資料庫。"
        }
    }

    func fileURL(for track: Track) -> URL { root.appendingPathComponent("Audio").appendingPathComponent(track.fileName) }
    func artworkURL(for track: Track) -> URL? { track.artworkName.map { root.appendingPathComponent("Artwork").appendingPathComponent($0) } }

    func save() {
        guard canSave else { return }
        do {
            let snapshot = LibrarySnapshot(tracks: tracks, playlists: playlists, queue: queue, events: events)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: snapshotURL, options: .atomic)
        } catch { errorMessage = "無法儲存資料庫，請確認裝置有足夠的儲存空間。" }
    }

    func add(_ additions: [Track]) {
        guard canSave else { return }
        var ids = Set(tracks.map(\.id))
        tracks.append(contentsOf: additions.filter { ids.insert($0.id).inserted })
        save()
        NotificationCenter.default.post(name: Self.tracksDidChange, object: self)
    }

    func deleteTrack(_ id: UUID) {
        guard canSave, let track = tracks.first(where: { $0.id == id }) else { return }
        tracks.removeAll { $0.id == id }
        for index in playlists.indices { playlists[index].trackIDs.removeAll { $0 == id } }
        var engine = QueueEngine(state: queue)
        engine.reconcile(validIDs: Set(tracks.map(\.id)))
        queue = engine.state
        // 先同步播放狀態，再移除播放器可能正在使用的檔案。
        NotificationCenter.default.post(name: Self.tracksDidChange, object: self)
        save()
        do {
            if !tracks.contains(where: { $0.fileName == track.fileName }), FileManager.default.fileExists(atPath: fileURL(for: track).path) {
                try FileManager.default.removeItem(at: fileURL(for: track))
            }
            if let name = track.artworkName, !tracks.contains(where: { $0.artworkName == name }), let url = artworkURL(for: track), FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch { errorMessage = "歌曲已從資料庫移除，但無法移除音訊或封面檔案。" }
    }

    func toggleFavorite(_ id: UUID) {
        guard let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[index].isFavorite.toggle(); save()
        NotificationCenter.default.post(name: Self.tracksDidChange, object: self)
    }
    func createPlaylist(name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        playlists.append(Playlist(name: clean)); save()
    }
    func addToPlaylist(trackID: UUID, playlistID: UUID) {
        guard tracks.contains(where: { $0.id == trackID }), let index = playlists.firstIndex(where: { $0.id == playlistID }), !playlists[index].trackIDs.contains(trackID) else { return }
        playlists[index].trackIDs.append(trackID); save()
    }
    func removeFromPlaylist(trackID: UUID, playlistID: UUID) {
        guard let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].trackIDs.removeAll { $0 == trackID }; save()
    }
    func updateLyrics(trackID: UUID, lyrics: Lyrics) {
        guard let index = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        tracks[index].lyrics = lyrics; save()
        NotificationCenter.default.post(name: Self.tracksDidChange, object: self)
    }
    func clearHistory() { events = []; save() }
    func exportData() throws -> URL {
        let snapshot = LibrarySnapshot(tracks: tracks, playlists: playlists, queue: queue, events: events)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ChaiMusic-\(UUID().uuidString).json")
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        return url
    }
}
