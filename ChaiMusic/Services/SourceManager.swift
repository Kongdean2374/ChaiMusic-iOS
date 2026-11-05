import Foundation
import Combine
import AVFoundation
import AudioToolbox

@MainActor
final class SourceManager: ObservableObject {
    @Published private(set) var configurations: [SourceConfiguration] = []
    @Published private(set) var statuses: [UUID: SourceSyncStatus] = [:]
    @Published var errorMessage: String?
    private let root: URL
    private let transport = SourceTransport()
    private var manifests: [UUID: HTTPPluginSource] = [:]
    private var indexes: [UUID: [RemoteEntry]] = [:]
    private var syncing = Set<UUID>()
    private var configurationWritable = true
    private var configURL: URL { root.appendingPathComponent("sources.json") }
    private var cacheRoot: URL { root.appendingPathComponent("SourceCache", isDirectory: true) }

    init(root: URL) {
        self.root = root
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: configURL.path) {
                configurations = try JSONDecoder().decode([SourceConfiguration].self, from: Data(contentsOf: configURL))
                for source in configurations {
                    try SourceTransport.validateHTTPS(source.baseURL, root: true)
                    if let data = try? Data(contentsOf: indexURL(source.id)),
                       let cached = try? JSONDecoder().decode([EntrySnapshot].self, from: data) {
                        indexes[source.id] = cached.map(\.entry)
                        statuses[source.id] = SourceSyncStatus(phase: "已載入本機索引", completed: true, knownCount: cached.count,
                                                              message: "顯示上次完整同步快照；可手動更新來源。")
                    }
                }
            }
        } catch {
            configurationWritable = false
            errorMessage = "來源設定無法讀取，已保留原檔並停止覆寫。請先匯出資料，再處理來源設定檔。"
        }
    }

    func add(name: String, kind: SourceKind, url: URL, username: String, password: String) async throws {
        guard configurationWritable else { throw SourceFailure.invalidResponse }
        try SourceTransport.validateHTTPS(url, root: true)
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw SourceFailure.invalidManifest }
        let source = SourceConfiguration(name: clean, kind: kind, baseURL: url, priority: configurations.count)
        let credential = SourceCredential(username: username, password: password)
        try CredentialStore.save(credential, id: source.id)
        do {
            if kind == .webDAV {
                _ = try await WebDAVSource(configuration: source, credential: credential, transport: transport).browse()
            } else {
                let plugin = try await HTTPPluginSource.load(configuration: source, credential: credential, transport: transport)
                try await plugin.verify()
                manifests[source.id] = plugin
            }
            configurations.append(source)
            try saveConfiguration()
            statuses[source.id] = SourceSyncStatus(phase: "連線正常", completed: false, knownCount: 0, message: "請瀏覽加入歌曲，或執行完整同步。")
        } catch {
            configurations.removeAll { $0.id == source.id }
            manifests[source.id] = nil
            CredentialStore.remove(id: source.id)
            throw error
        }
    }
    func remove(_ id: UUID) {
        guard configurationWritable else { return }
        configurations.removeAll { $0.id == id }
        statuses[id] = nil; indexes[id] = nil; manifests[id] = nil
        CredentialStore.remove(id: id)
        try? FileManager.default.removeItem(at: indexURL(id))
        do { try saveConfiguration() } catch { errorMessage = "無法儲存來源設定。" }
    }
    func setEnabled(_ id: UUID, enabled: Bool) {
        guard configurationWritable, let index = configurations.firstIndex(where: { $0.id == id }) else { return }
        configurations[index].enabled = enabled
        do { try saveConfiguration() } catch { errorMessage = "無法儲存來源設定。" }
    }
    func move(from offsets: IndexSet, to destination: Int) {
        guard configurationWritable else { return }
        let selected = offsets.sorted().filter { configurations.indices.contains($0) }
        let moving = selected.map { configurations[$0] }
        var remaining = configurations.enumerated().filter { !offsets.contains($0.offset) }.map(\.element)
        let insertion = max(0, min(remaining.count, destination - selected.filter { $0 < destination }.count))
        remaining.insert(contentsOf: moving, at: insertion)
        for index in remaining.indices { remaining[index].priority = index }
        configurations = remaining
        do { try saveConfiguration() } catch { errorMessage = "無法儲存來源順序。" }
    }
    func verify(_ id: UUID) async throws {
        let source = try configuration(id)
        statuses[id] = SourceSyncStatus(phase: "正在驗證連線", completed: false, knownCount: indexes[id]?.count ?? 0)
        do {
            if source.kind == .webDAV { _ = try await dav(source).browse() }
            else { let provider = try await plugin(source, refresh: true); try await provider.verify() }
            statuses[id] = SourceSyncStatus(phase: "連線正常", completed: indexes[id] != nil, knownCount: indexes[id]?.count ?? 0)
        } catch { recordFailure(id, error: error); throw error }
    }
    func browse(sourceID: UUID, url: URL? = nil) async throws -> [RemoteEntry] {
        let source = try configuration(sourceID)
        if source.kind == .webDAV { return try await dav(source).browse(url) }
        return try await plugin(source).catalog()
    }
    func search(sourceID: UUID, query: String) async throws -> [RemoteEntry] {
        let source = try configuration(sourceID)
        if source.kind == .httpPlugin { return try await plugin(source).catalog(query: query) }
        guard let entries = indexes[sourceID] else { throw SourceFailure.incomplete }
        return entries.filter { query.isEmpty || "\($0.title) \($0.artist) \($0.album)".localizedCaseInsensitiveContains(query) }
    }
    func sync(sourceID: UUID, store: LibraryStore) async throws {
        guard !syncing.contains(sourceID) else { return }
        let source = try configuration(sourceID)
        syncing.insert(sourceID)
        defer { syncing.remove(sourceID) }
        statuses[sourceID] = SourceSyncStatus(phase: "完整同步中", completed: false, knownCount: indexes[sourceID]?.count ?? 0,
                                             message: "既有快照仍可播放；所有目錄／頁面完成後才替換完整索引。")
        do {
            let entries: [RemoteEntry]
            if source.kind == .webDAV { entries = try await dav(source).allEntries() }
            else { entries = try await plugin(source).catalog() }
            try Task.checkCancellation()
            _ = try configuration(sourceID)
            let snapshot = entries.map(EntrySnapshot.init)
            let data = try JSONEncoder().encode(snapshot)
            let destination = indexURL(sourceID)
            try await Task.detached(priority: .utility) { try data.write(to: destination, options: .atomic) }.value
            indexes[sourceID] = entries
            importEntries(entries, sourceID: sourceID, store: store)
            statuses[sourceID] = SourceSyncStatus(phase: "完整同步完成", completed: true, knownCount: entries.count,
                                                  message: "所有已同步歌曲皆可加入完整洗牌。")
        } catch { recordFailure(sourceID, error: error); throw error }
    }
    func importEntries(_ entries: [RemoteEntry], sourceID: UUID, store: LibraryStore) {
        guard let source = configurations.first(where: { $0.id == sourceID && $0.enabled }) else { return }
        let tracks = entries.filter { !$0.isDirectory }.map { entry -> Track in
            var track = Track(id: StableSourceID.make(sourceID.uuidString + ":" + entry.id), title: entry.title,
                              artist: entry.artist, album: entry.album, fileName: "", duration: entry.duration)
            track.quality.source = source.name
            track.variants = entry.variants
            track.recordingID = entry.recordingID
            return track
        }
        store.upsertRemote(tracks)
    }
    func prepare(track: Track, variant: SourceVariant? = nil) async throws -> PreparedAudio {
        try Task.checkCancellation()
        if let local = variant?.localFileName, !local.isEmpty {
            return try await inspect(url: localFile(local), sourceName: variant?.sourceName ?? "本機檔案", variant: variant, recordingID: variant?.recordingID ?? track.recordingID)
        }
        if variant == nil, !track.fileName.isEmpty {
            return try await inspect(url: localFile(track.fileName), sourceName: "本機檔案", variant: nil, recordingID: track.recordingID)
        }
        guard let selected = variant ?? track.variants?.first(where: { candidate in
            candidate.sourceID.map { id in configurations.contains { $0.id == id && $0.enabled } } ?? false
        }), let sourceID = selected.sourceID else { throw SourceFailure.missingSource }
        let source = try configuration(sourceID)
        let cached = cacheRoot.appendingPathComponent(selected.id.uuidString + ".audio")
        if FileManager.default.fileExists(atPath: cached.path) {
            return try await inspect(url: cached, sourceName: source.name, variant: selected, recordingID: selected.recordingID ?? track.recordingID)
        }
        let url: URL
        if source.kind == .webDAV {
            guard let direct = selected.url, SourceTransport.sameOrigin(direct, source.baseURL), WebDAVSource.contained(direct, in: source.baseURL) else { throw SourceFailure.invalidURL }
            url = direct
        } else { url = try await plugin(source).resolve(selected) }
        try await transport.download(url: url, origin: source.baseURL, credential: CredentialStore.load(id: sourceID), destination: cached)
        do {
            return try await inspect(url: cached, sourceName: source.name, variant: selected, recordingID: selected.recordingID ?? track.recordingID)
        } catch {
            try? FileManager.default.removeItem(at: cached)
            throw error
        }
    }
    func candidates(for track: Track) async -> [SourceVariant] {
        var result = track.variants ?? []
        if let recordingID = track.recordingID, !recordingID.isEmpty {
            for source in configurations.filter({ $0.enabled && $0.kind == .httpPlugin }).sorted(by: { $0.priority < $1.priority }) {
                do { result += try await plugin(source).candidates(recordingID: recordingID) }
                catch is CancellationError { return [] }
                catch { errorMessage = "部分來源無法取得升級候選，會繼續播放目前音訊。" }
            }
        }
        var seen = Set<UUID>()
        return result.filter { item in
            let enabled = item.sourceID.map { id in configurations.contains { $0.id == id && $0.enabled } } ?? (item.localFileName != nil)
            return enabled && seen.insert(item.id).inserted
        }.sorted { left, right in
            let lp = configurations.first { $0.id == left.sourceID }?.priority ?? -1
            let rp = configurations.first { $0.id == right.sourceID }?.priority ?? -1
            return lp < rp
        }
    }
    func fetchLyrics(for track: Track) async throws -> [Lyrics] {
        guard let recordingID = track.recordingID, !recordingID.isEmpty else { return [] }
        var result: [Lyrics] = [], firstError: Error?
        for source in configurations.filter({ $0.enabled && $0.kind == .httpPlugin }).sorted(by: { $0.priority < $1.priority }) {
            do { result += try await plugin(source).lyrics(recordingID: recordingID) }
            catch is CancellationError { throw CancellationError() }
            catch { if firstError == nil { firstError = error } }
        }
        if result.isEmpty, let firstError { throw firstError }
        return result
    }

    private func configuration(_ id: UUID) throws -> SourceConfiguration {
        guard let source = configurations.first(where: { $0.id == id && $0.enabled }) else { throw SourceFailure.missingSource }
        return source
    }
    private func plugin(_ source: SourceConfiguration, refresh: Bool = false) async throws -> HTTPPluginSource {
        if !refresh, let cached = manifests[source.id] { return cached }
        let provider = try await HTTPPluginSource.load(configuration: source, credential: CredentialStore.load(id: source.id), transport: transport)
        manifests[source.id] = provider
        return provider
    }
    private func dav(_ source: SourceConfiguration) throws -> WebDAVSource {
        WebDAVSource(configuration: source, credential: try CredentialStore.load(id: source.id), transport: transport)
    }
    private func saveConfiguration() throws {
        guard configurationWritable else { throw SourceFailure.invalidResponse }
        try JSONEncoder().encode(configurations).write(to: configURL, options: .atomic)
    }
    private func indexURL(_ id: UUID) -> URL { root.appendingPathComponent("source-index-\(id.uuidString).json") }
    private func recordFailure(_ id: UUID, error: Error) {
        let message = (error as? SourceFailure)?.errorDescription ?? (error is CancellationError ? "同步已取消。" : "來源操作失敗，舊索引已保留。")
        statuses[id] = SourceSyncStatus(phase: "需要注意", completed: false, knownCount: indexes[id]?.count ?? 0, message: message)
    }
    private func localFile(_ name: String) throws -> URL {
        guard name == (name as NSString).lastPathComponent, !name.isEmpty else { throw SourceFailure.fileMissing }
        return root.appendingPathComponent("Audio", isDirectory: true).appendingPathComponent(name)
    }
    private func inspect(url: URL, sourceName: String, variant: SourceVariant?, recordingID: String?) async throws -> PreparedAudio {
        do { return try await inspectAsset(url: url, sourceName: sourceName, variant: variant, recordingID: recordingID) }
        catch is CancellationError { throw CancellationError() }
        catch let error as SourceFailure { throw error }
        catch { throw SourceFailure.unsupportedAudio }
    }
    private func inspectAsset(url: URL, sourceName: String, variant: SourceVariant?, recordingID: String?) async throws -> PreparedAudio {
        guard FileManager.default.fileExists(atPath: url.path) else { throw SourceFailure.fileMissing }
        let asset = AVURLAsset(url: url)
        let playable = try await asset.load(.isPlayable)
        let protected = try await asset.load(.hasProtectedContent)
        guard playable, !protected, let stream = try await asset.loadTracks(withMediaType: .audio).first else { throw SourceFailure.unsupportedAudio }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw SourceFailure.unsupportedAudio }
        var quality = AudioQuality(source: sourceName)
        var audioFile: AudioFileID?
        if AudioFileOpenURL(url as CFURL, .readPermission, 0, &audioFile) == noErr, let audioFile {
            defer { AudioFileClose(audioFile) }
            var format: AudioFileTypeID = 0
            var size = UInt32(MemoryLayout<AudioFileTypeID>.size)
            if AudioFileGetProperty(audioFile, kAudioFilePropertyFileFormat, &size, &format) == noErr {
                switch format {
                case kAudioFileM4AType: quality.container = "M4A"
                case kAudioFileMPEG4Type: quality.container = "MP4"
                case kAudioFileMP3Type: quality.container = "MP3"
                case kAudioFileAAC_ADTSType: quality.container = "ADTS"
                case kAudioFileWAVEType: quality.container = "WAV"
                case kAudioFileAIFFType, kAudioFileAIFCType: quality.container = "AIFF"
                case kAudioFileCAFType: quality.container = "CAF"
                case kAudioFileFLACType: quality.container = "FLAC"
                default: break
                }
            }
        }
        if let rate = try? await stream.load(.estimatedDataRate), rate > 0 { quality.bitRate = Double(rate) }
        if let formats = try? await stream.load(.formatDescriptions), let first = formats.first,
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(first)?.pointee {
            quality.sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : nil
            quality.bitDepth = asbd.mBitsPerChannel > 0 ? Int(asbd.mBitsPerChannel) : nil
            switch asbd.mFormatID {
            case kAudioFormatMPEG4AAC: quality.codec = "AAC"
            case kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2: quality.codec = "HE-AAC"
            case kAudioFormatMPEGLayer3: quality.codec = "MP3"
            case kAudioFormatAppleLossless: quality.codec = "ALAC"
            case kAudioFormatFLAC: quality.codec = "FLAC"
            case kAudioFormatLinearPCM: quality.codec = "PCM"
            default: quality.codec = "未知"
            }
        }
        try Task.checkCancellation()
        return PreparedAudio(url: url, quality: quality, duration: duration, variantID: variant?.id, recordingID: recordingID)
    }
}

private struct EntrySnapshot: Codable {
    var id: String; var title: String; var artist: String; var album: String; var url: URL
    var duration: Double; var recordingID: String?; var variants: [SourceVariant]
    init(_ entry: RemoteEntry) {
        id = entry.id; title = entry.title; artist = entry.artist; album = entry.album; url = entry.url
        duration = entry.duration; recordingID = entry.recordingID; variants = entry.variants
    }
    var entry: RemoteEntry {
        RemoteEntry(id: id, title: title, artist: artist, album: album, url: url, duration: duration, recordingID: recordingID, variants: variants)
    }
}
