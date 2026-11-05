import Foundation
import Combine

@MainActor
final class LibraryStore: ObservableObject {
    @Published var tracks: [Track] = [] {
        didSet { rebuildIndex(); scheduleSave() }
    }
    @Published var playlists: [Playlist] = [] { didSet { scheduleSave() } }
    @Published var events: [ListeningEvent] = [] {
        didSet {
            if events.count != oldValue.count { rebuildEventIndex() }
            scheduleSave()
        }
    }
    @Published var errorMessage: String?
    @Published private(set) var restoring = false
    private(set) var trackByID: [UUID: Track] = [:]
    private var eventIndex: [UUID: Int] = [:]
    var queue = QueueState()
    let root: URL
    private var database: LibraryDatabase?
    private var canSave = false
    private var suppressSave = true
    private let backupService = BackupService()
    static let tracksDidChange = Notification.Name("ChaiMusic資料庫歌曲異動")
    static let didRestoreBackup = Notification.Name("ChaiMusic音樂庫已還原")

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ChaiMusic", isDirectory: true)
        do {
            for directory in [self.root, self.root.appendingPathComponent("Audio"), self.root.appendingPathComponent("Artwork")] {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            let database = try LibraryDatabase(root: self.root)
            self.database = database
            let snapshot = try database.load()
            guard Set(snapshot.tracks.map(\.id)).count == snapshot.tracks.count else { throw LibraryDatabase.Failure.damaged }
            apply(snapshot)
            canSave = true
            suppressSave = false
        } catch {
            errorMessage = "無法讀取音樂庫，已保留資料庫及舊版 JSON 並停止寫入。請先備份 App 資料後再處理。"
        }
    }
    func fileURL(for track: Track) -> URL { root.appendingPathComponent("Audio").appendingPathComponent(track.fileName) }
    func artworkURL(for track: Track) -> URL? { track.artworkName.map { root.appendingPathComponent("Artwork").appendingPathComponent($0) } }
    private func rebuildIndex() {
        var index: [UUID: Track] = [:]
        for track in tracks { index[track.id] = track }
        trackByID = index
    }
    private func rebuildEventIndex() {
        eventIndex = Dictionary(events.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
    }
    private func snapshot() -> LibrarySnapshot { LibrarySnapshot(version: 2, tracks: tracks, playlists: playlists, queue: queue, events: events) }
    func save() { scheduleSave() }
    private func scheduleSave() {
        guard canSave, !suppressSave, !restoring, let database else { return }
        database.schedule(snapshot()) { [weak self] error in
            guard error != nil else { return }
            Task { @MainActor in self?.errorMessage = "音樂庫寫入失敗，變更仍留在記憶體。請釋出儲存空間並匯出備份。" }
        }
    }
    func flush() async {
        save()
        do { try await database?.flush() }
        catch { errorMessage = "尚未完成資料寫入，請確認儲存空間。" }
    }
    private func changedTracks() { NotificationCenter.default.post(name: Self.tracksDidChange, object: self) }
    func add(_ additions: [Track]) {
        guard canSave, !restoring else { return }
        var ids = Set(tracks.map(\.id))
        tracks.append(contentsOf: additions.filter { ids.insert($0.id).inserted })
        changedTracks()
    }
    func deleteTrack(_ id: UUID) {
        guard canSave, !restoring, let track = trackByID[id] else { return }
        tracks.removeAll { $0.id == id }
        for index in playlists.indices { playlists[index].trackIDs.removeAll { $0 == id } }
        var engine = QueueEngine(state: queue)
        engine.reconcile(validIDs: Set(trackByID.keys)); queue = engine.state
        changedTracks(); save()
        let remainingNames = Set(tracks.flatMap { item in ([item.fileName] + (item.variants ?? []).compactMap(\.localFileName)).filter { !$0.isEmpty } })
        let candidates = ([track.fileName] + (track.variants ?? []).compactMap(\.localFileName)).filter { !$0.isEmpty && !remainingNames.contains($0) }
        let artwork = track.artworkName.flatMap { name in tracks.contains(where: { $0.artworkName == name }) ? nil : name }
        let root = self.root
        let database = self.database
        Task.detached(priority: .utility) {
            // 先落盤刪除的索引，避免強制終止後資料庫仍指向已刪除音檔。
            do { try await database?.flush() } catch { return }
            for name in candidates { try? FileManager.default.removeItem(at: root.appendingPathComponent("Audio").appendingPathComponent(name)) }
            if let artwork { try? FileManager.default.removeItem(at: root.appendingPathComponent("Artwork").appendingPathComponent(artwork)) }
        }
    }
    func toggleFavorite(_ id: UUID) {
        guard canSave, !restoring, let index = tracks.firstIndex(where: { $0.id == id }) else { return }
        tracks[index].isFavorite.toggle(); changedTracks()
    }
    func createPlaylist(name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSave, !restoring, !clean.isEmpty else { return }
        playlists.append(Playlist(name: String(clean.prefix(200))))
    }
    func renamePlaylist(_ id: UUID, name: String) {
        let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSave, !restoring, !value.isEmpty, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        playlists[index].name = String(value.prefix(200))
    }
    func deletePlaylist(_ id: UUID) {
        guard canSave, !restoring else { return }
        playlists.removeAll { $0.id == id }
        if queue.playlistID == id { queue.playlistID = nil; save() }
    }
    func addToPlaylist(trackID: UUID, playlistID: UUID) { addTracks([trackID], to: playlistID) }
    func removeFromPlaylist(trackID: UUID, playlistID: UUID) { removeTracks([trackID], from: playlistID) }
    func addTracks(_ ids: [UUID], to playlistID: UUID) {
        guard canSave, !restoring, let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        var existing = Set(playlists[index].trackIDs)
        playlists[index].trackIDs.append(contentsOf: ids.filter { trackByID[$0] != nil && existing.insert($0).inserted })
    }
    func removeTracks(_ ids: Set<UUID>, from playlistID: UUID) {
        guard canSave, !restoring, let index = playlists.firstIndex(where: { $0.id == playlistID }) else { return }
        playlists[index].trackIDs.removeAll { ids.contains($0) }
    }
    func movePlaylistTracks(_ id: UUID, from offsets: IndexSet, to destination: Int) {
        guard canSave, !restoring, let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        let list = playlists[index].trackIDs
        let indices = offsets.sorted().filter { list.indices.contains($0) }
        let moved = indices.map { list[$0] }
        var result = list.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let insertion = max(0, min(result.count, destination - indices.filter { $0 < destination }.count))
        result.insert(contentsOf: moved, at: insertion); playlists[index].trackIDs = result
    }
    func updateLyrics(trackID: UUID, lyrics: Lyrics) {
        guard canSave, !restoring, let index = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        tracks[index].lyrics = lyrics; changedTracks()
    }
    func upsertRemote(_ additions: [Track]) {
        guard canSave, !restoring else { return }
        var result = tracks
        var indices = Dictionary(uniqueKeysWithValues: result.enumerated().map { ($0.element.id, $0.offset) })
        for incoming in additions {
            if let index = indices[incoming.id] {
                var updated = incoming
                let old = result[index]
                updated.isFavorite = old.isFavorite
                updated.lyrics = old.lyrics ?? incoming.lyrics
                updated.importedAt = old.importedAt
                if !old.fileName.isEmpty { updated.fileName = old.fileName }
                updated.artworkName = old.artworkName ?? incoming.artworkName
                var variants = incoming.variants ?? []
                let ids = Set(variants.map(\.id))
                variants.append(contentsOf: (old.variants ?? []).filter { !ids.contains($0.id) })
                updated.variants = variants
                result[index] = updated
            } else { indices[incoming.id] = result.count; result.append(incoming) }
        }
        tracks = result; changedTracks()
    }
    func linkVariant(trackID: UUID, variant: SourceVariant) {
        guard canSave, !restoring, let index = tracks.firstIndex(where: { $0.id == trackID }) else { return }
        var variants = tracks[index].variants ?? []
        if let existing = variants.firstIndex(where: { $0.id == variant.id }) { variants[existing] = variant }
        else { variants.append(variant) }
        tracks[index].variants = variants; changedTracks()
    }
    func recordListening(trackID: UUID, playlistID: UUID?, seconds: Double, at date: Date, duration: Double, manual: Bool, replay: Bool, eventID: UUID) {
        guard canSave, !restoring, seconds.isFinite, seconds > 0, duration.isFinite else { return }
        if let index = eventIndex[eventID], events.indices.contains(index) { events[index].seconds += seconds; events[index].duration = duration }
        else { events.append(ListeningEvent(id: eventID, trackID: trackID, playlistID: playlistID, date: date, seconds: seconds, duration: duration, manual: manual, replay: replay)) }
    }
    func clearHistory() { guard canSave, !restoring else { return }; events = [] }
    func exportData() throws -> URL {
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("ChaiMusic-metadata-\(UUID().uuidString).json")
        try JSONEncoder().encode(BackupService.sanitized(snapshot())).write(to: destination, options: .atomic)
        return destination
    }
    func exportBackup() async throws -> URL {
        guard let database, canSave, !restoring else { throw LibraryDatabase.Failure.database }
        save(); try await database.flush()
        return try await backupService.export(snapshot: snapshot(), root: root)
    }
    func importBackup(from url: URL) async throws {
        guard let database, canSave, !restoring else { throw LibraryDatabase.Failure.database }
        save(); try await database.flush()
        restoring = true
        defer { restoring = false }
        let recovery = root.appendingPathComponent("Recovery").appendingPathComponent("before-restore-\(UUID().uuidString).sqlite")
        try await database.backup(to: recovery)
        let restored = try await backupService.restore(from: url, into: root)
        do {
            try await database.replace(with: restored.snapshot)
            suppressSave = true; apply(restored.snapshot); suppressSave = false
            NotificationCenter.default.post(name: Self.didRestoreBackup, object: self)
        } catch {
            for file in restored.installedFiles { try? FileManager.default.removeItem(at: file) }
            throw error
        }
    }
    private func apply(_ snapshot: LibrarySnapshot) {
        tracks = snapshot.tracks; playlists = snapshot.playlists; events = snapshot.events
        rebuildEventIndex()
        var engine = QueueEngine(state: snapshot.queue)
        engine.reconcile(validIDs: Set(trackByID.keys)); queue = engine.state
    }
}
