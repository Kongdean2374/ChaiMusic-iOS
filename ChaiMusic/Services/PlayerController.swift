import Foundation
import Combine
import AVFoundation
import MediaPlayer
import UIKit

@MainActor
private final class PlaybackOperationResult { var value: Bool? }

@MainActor
final class PlayerController: ObservableObject {
    @Published var currentTrack: Track?
    @Published var isPlaying = false
    @Published var progress: Double = 0
    @Published var duration: Double = 0
    @Published var errorMessage: String?
    @Published var queue: QueueState
    @Published var upgradeStatus = "尚未尋找更高音質"
    @Published var isUpgrading = false
    @Published var diagnostics: [String] = []
    @Published var actualQuality: AudioQuality?
    @Published var loading = false

    private let store: LibraryStore
    private let sources: SourceManager
    private let preferences: AppPreferences
    private let matcher = AudioUpgradeCoordinator()
    private var player = AVPlayer()
    private var standby: AVPlayer?
    private var prepared: PreparedAudio?
    private var engine: QueueEngine
    private var timeObserver: Any?
    private var observedPlayer: AVPlayer?
    private var cachedArtworkName: String?
    private var cachedArtworkImage: UIImage?
    private var observers: [NSObjectProtocol] = []
    private var itemStatus: NSKeyValueObservation?
    private var loadTask: Task<Void, Never>?
    private var upgradeTask: Task<Void, Never>?
    private var generation = 0
    private var upgradeGeneration = 0
    private var activeOffset: Double = 0
    private var activeGain: Float = 1
    private var playbackWanted = false
    private var seeking = false
    private var seekGeneration = 0
    private var lastMediaTime: Double?
    private var lastUptime: TimeInterval?
    private var lastSaved: TimeInterval = 0
    private var lastNowPlayingUpdate: TimeInterval = 0
    private var eventID: UUID?
    private var eventDay: Date?
    private var segmentIDs: [UUID] = []
    private var sessionSeconds: Double = 0
    private var eventManual = false
    private var eventReplay = false
    private var shouldResumeAfterInterruption = false
    var upcomingIDs: [UUID] { engine.upcomingIDs }
    var lyricPlaybackTime: Double {
        guard !seeking, !loading, player.currentItem != nil else { return progress }
        let time = player.currentTime().seconds - activeOffset
        return time.isFinite ? max(progress, min(duration, max(0, time))) : progress
    }

    init(store: LibraryStore, sources: SourceManager, preferences: AppPreferences) {
        self.store = store
        self.sources = sources
        self.preferences = preferences
        engine = QueueEngine(state: store.queue)
        queue = engine.state
        do { try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default) }
        catch { errorMessage = "無法設定背景音訊，請重新啟動應用程式。" }
        installObservers()
        configureRemoteCommands()
        loadCurrent(autoplay: false, manual: false)
    }

    func play(ids: [UUID], startID: UUID? = nil, shuffle: Bool = false, playlistID: UUID? = nil) {
        let oldID = currentTrack?.id
        finishEvent(skipped: true)
        engine.start(ids: ids.filter { store.trackByID[$0] != nil }, startID: startID, shuffle: shuffle, playlistID: playlistID)
        loadCurrent(autoplay: true, manual: true, replay: oldID != nil && oldID == engine.state.currentID)
    }
    func togglePlay() { playbackWanted || isPlaying ? pause() : resume() }
    func pause() {
        tick()
        playbackWanted = false
        cancelUpgrade()
        player.pause(); isPlaying = false
        resetSample(); persist(); updateNowPlaying()
    }
    private func resume() {
        guard currentTrack != nil else { return }
        playbackWanted = true
        if loading { return }
        guard player.currentItem != nil else { loadCurrent(autoplay: true, manual: true); return }
        do { try AVAudioSession.sharedInstance().setActive(true) }
        catch { errorMessage = "無法啟動音訊播放，請確認音訊輸出裝置後再試。"; playbackWanted = false; return }
        resetSample(); player.play(); isPlaying = true
        updateNowPlaying()
        if preferences.autoUpgrade { requestUpgrade() }
    }
    func next() {
        finishEvent(skipped: true)
        _ = engine.advance()
        loadCurrent(autoplay: true, manual: true)
    }
    func previous() {
        if progress > 3 {
            finishEvent(skipped: false)
            eventReplay = true; eventManual = true
            seek(to: 0)
            return
        }
        finishEvent(skipped: true)
        _ = engine.previous()
        loadCurrent(autoplay: true, manual: true, replay: true)
    }
    func seek(to seconds: Double) {
        guard seconds.isFinite, currentTrack != nil else { return }
        tick(); cancelUpgrade()
        seekGeneration += 1
        let seekToken = seekGeneration
        seeking = true; resetSample()
        let target = max(0, min(seconds, max(0, duration)))
        progress = target; engine.state.progress = target
        guard let item = player.currentItem else { seeking = false; persist(); return }
        item.cancelPendingSeeks()
        player.seek(to: CMTime(seconds: target + activeOffset, preferredTimescale: 48_000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] success in
            Task { @MainActor in
                guard let self, seekToken == self.seekGeneration else { return }
                self.seeking = false; self.resetSample(); self.persist(); self.updateNowPlaying()
                if !success { self.errorMessage = "這次時間跳轉未完成，請再試一次。" }
                else if self.preferences.autoUpgrade && self.isPlaying { self.requestUpgrade() }
            }
        }
        publishQueue()
    }
    func insertNext(_ id: UUID) {
        guard store.trackByID[id] != nil else { return }
        engine.insertNext(id); persist()
    }
    func removeUpcoming(at offsets: IndexSet) { engine.removeUpcoming(at: offsets); persist() }
    func moveUpcoming(from: IndexSet, to: Int) { engine.moveUpcoming(from: from, to: to); persist() }
    func setRepeat(_ mode: RepeatMode) { engine.state.repeatMode = mode; persist() }
    func setShuffle(_ enabled: Bool) { engine.setShuffle(enabled); persist() }
    func persist() {
        engine.state.progress = progress.isFinite ? progress : 0
        publishQueue(); store.save()
        lastSaved = ProcessInfo.processInfo.systemUptime
    }
    private func publishQueue() { queue = engine.state; store.queue = engine.state }

    func linkAlternate(_ alternate: Track) {
        guard let track = currentTrack, alternate.id != track.id else { return }
        var variants = alternate.variants ?? []
        if !alternate.fileName.isEmpty {
            variants.insert(SourceVariant(localFileName: alternate.fileName, recordingID: track.recordingID,
                                          sourceName: "使用者連結的本機版本", declaredQuality: alternate.quality), at: 0)
        }
        guard !variants.isEmpty else { errorMessage = "所選歌曲沒有可用的音訊版本。"; return }
        for var variant in variants {
            variant.recordingID = track.recordingID
            store.linkVariant(trackID: track.id, variant: variant)
        }
        log("已連結候選；仍需比對實際音訊，尚未切換。")
        requestUpgrade()
    }

    func requestUpgrade() {
        guard !isUpgrading, !loading, !seeking, isPlaying,
              let track = currentTrack, let original = prepared else {
            if !isPlaying { upgradeStatus = "播放歌曲後可比對並升級" }
            return
        }
        upgradeGeneration += 1
        let token = upgradeGeneration
        let songGeneration = generation
        isUpgrading = true; upgradeStatus = "尋找同一錄音的候選"
        upgradeTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if token == self.upgradeGeneration { self.isUpgrading = false; self.upgradeTask = nil }
            }
            let candidates = await self.sources.candidates(for: track)
            var attempted = 0
            for variant in candidates.prefix(6) {
                if Task.isCancelled || token != self.upgradeGeneration || songGeneration != self.generation { return }
                if variant.id == original.variantID { continue }
                if !self.preferences.networkPlayback && variant.localFileName == nil { continue }
                attempted += 1
                self.upgradeStatus = "下載與檢查候選音訊"
                do {
                    let candidate = try await self.sources.prepare(track: track, variant: variant)
                    try self.ensureUpgrade(token, songGeneration)
                    if candidate.url == original.url { continue }
                    guard AudioUpgradeCoordinator.improves(candidate.quality, over: original.quality, preferLossless: self.preferences.preferLossless) else {
                        throw UpgradeError.noImprovement
                    }
                    self.upgradeStatus = "比對錄音版本與時間軸"
                    let match = try await self.matcher.match(original: original, candidate: candidate)
                    try self.ensureUpgrade(token, songGeneration)
                    self.log(String(format: "三段聲學比對通過：最低相關 %.3f，偏移 %.4f 秒；增益僅作安全衰減。", match.correlation, match.offset))
                    try await self.crossfade(to: candidate, match: match, token: token, songGeneration: songGeneration)
                    self.upgradeStatus = "已升級 · \(candidate.quality.codec)"
                    self.log("候選已實際接手播放，音質資訊已更新；不保證樣本級無縫。")
                    return
                } catch is CancellationError { return }
                catch {
                    guard token == self.upgradeGeneration, songGeneration == self.generation else { return }
                    self.standby?.pause(); self.standby = nil
                    self.player.volume = self.activeGain
                    let detail = (error as? UpgradeError)?.errorDescription ?? "候選下載或解碼失敗，保留原音源。"
                    self.log(detail)
                }
            }
            if token == self.upgradeGeneration {
                self.upgradeStatus = attempted == 0 ? "沒有可用的更高品質候選" : "未安全升級，原音源繼續播放"
            }
        }
    }

    func cancelUpgrade() {
        let wasActive = isUpgrading
        upgradeGeneration += 1
        upgradeTask?.cancel(); upgradeTask = nil
        standby?.cancelPendingPrerolls(); standby?.currentItem?.cancelPendingSeeks(); standby?.pause(); standby = nil
        player.volume = activeGain
        isUpgrading = false
        if wasActive { upgradeStatus = "已取消升級，保留原音源"; log(upgradeStatus) }
    }

    private func ensureUpgrade(_ token: Int, _ songGeneration: Int) throws {
        try Task.checkCancellation()
        guard token == upgradeGeneration, songGeneration == generation, playbackWanted, !seeking else { throw UpgradeError.cancelled }
    }

    private func crossfade(to candidate: PreparedAudio, match: RecordingMatch, token: Int, songGeneration: Int) async throws {
        let originalPlayer = player
        let replacement = AVPlayer(playerItem: AVPlayerItem(url: candidate.url))
        replacement.volume = 0
        replacement.automaticallyWaitsToMinimizeStalling = true
        standby = replacement
        upgradeStatus = "候選預先解碼與緩衝"
        let deadline = ProcessInfo.processInfo.systemUptime + 12
        while replacement.currentItem?.status != .readyToPlay {
            try ensureUpgrade(token, songGeneration)
            if replacement.currentItem?.status == .failed || ProcessInfo.processInfo.systemUptime >= deadline { throw UpgradeError.timeout }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let initialTarget = max(0, originalPlayer.currentTime().seconds + match.offset)
        let seekResult = PlaybackOperationResult()
        replacement.seek(to: CMTime(seconds: initialTarget, preferredTimescale: 48_000), toleranceBefore: .zero, toleranceAfter: .zero) { result in
            Task { @MainActor in seekResult.value = result }
        }
        try await waitFor(seekResult, deadline: deadline, token: token, songGeneration: songGeneration)
        let preroll = PlaybackOperationResult()
        replacement.preroll(atRate: 1) { result in Task { @MainActor in preroll.value = result } }
        try await waitFor(preroll, deadline: deadline, token: token, songGeneration: songGeneration)
        try ensureUpgrade(token, songGeneration)
        guard originalPlayer.timeControlStatus == .playing, duration - progress > 1.5 else { throw UpgradeError.alignment }
        // 以共同 host clock 排定候選，避免預載完成時間差被誤認為音訊偏移。
        let delay = 0.08
        let host = CMTimeAdd(CMClockGetTime(CMClockGetHostTimeClock()), CMTime(seconds: delay, preferredTimescale: 1_000_000_000))
        let target = originalPlayer.currentTime().seconds + match.offset + delay
        replacement.setRate(1, time: CMTime(seconds: target, preferredTimescale: 48_000), atHostTime: host)
        try await Task.sleep(nanoseconds: 180_000_000)
        try ensureUpgrade(token, songGeneration)
        let difference = replacement.currentTime().seconds - originalPlayer.currentTime().seconds - match.offset
        guard difference.isFinite, abs(difference) <= 0.04, replacement.timeControlStatus == .playing else { throw UpgradeError.alignment }
        upgradeStatus = "升級中 · 時間軸已對齊"
        let targetGain = min(1, activeGain * match.gain)
        for step in 1...12 {
            try ensureUpgrade(token, songGeneration)
            guard replacement.timeControlStatus == .playing, originalPlayer.timeControlStatus == .playing else { throw UpgradeError.alignment }
            let amount = Float(step) / 12
            originalPlayer.volume = activeGain * (1 - amount)
            replacement.volume = targetGain * amount
            try await Task.sleep(nanoseconds: 15_000_000)
        }
        try ensureUpgrade(token, songGeneration)
        tick()
        detachTimeObserver()
        originalPlayer.pause()
        player = replacement; standby = nil
        activeOffset += match.offset; activeGain = targetGain
        prepared = candidate; actualQuality = candidate.quality
        resetSample(); attachTimeObserver(); observeItem()
        persist(); updateNowPlaying()
    }

    private func waitFor(_ result: PlaybackOperationResult, deadline: Double, token: Int, songGeneration: Int) async throws {
        while result.value == nil {
            try ensureUpgrade(token, songGeneration)
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw UpgradeError.timeout }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        guard result.value == true else { throw UpgradeError.alignment }
    }

    private func libraryChanged() {
        let oldID = currentTrack?.id
        let wasPlaying = playbackWanted
        engine.reconcile(validIDs: Set(store.trackByID.keys))
        if let playlistID = engine.state.playlistID, !store.playlists.contains(where: { $0.id == playlistID }) { engine.state.playlistID = nil }
        if oldID != engine.state.currentID {
            finishEvent(skipped: true)
            engine.state.progress = 0
            loadCurrent(autoplay: wasPlaying, manual: false)
        } else {
            currentTrack = oldID.flatMap { store.trackByID[$0] }
            publishQueue(); updateNowPlaying()
        }
    }

    private func loadCurrent(autoplay: Bool, manual: Bool, replay: Bool = false) {
        cancelUpgrade(); loadTask?.cancel(); generation += 1
        let token = generation
        playbackWanted = autoplay
        player.pause(); isPlaying = false
        detachTimeObserver(); itemStatus = nil; player.replaceCurrentItem(with: nil)
        activeOffset = 0; activeGain = 1; player.volume = 1; prepared = nil; actualQuality = nil
        seekGeneration += 1; seeking = false; resetSample()
        eventManual = manual; eventReplay = replay
        currentTrack = engine.state.currentID.flatMap { store.trackByID[$0] }
        progress = max(0, engine.state.progress.isFinite ? engine.state.progress : 0)
        duration = currentTrack?.duration ?? 0
        loading = false; upgradeStatus = "尚未尋找更高音質"
        guard let track = currentTrack else {
            progress = 0; duration = 0; persist(); MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return
        }
        persist(); updateNowPlaying()
        // 重開 App 只恢復佇列，不在未按播放前下載遠端音訊。
        if !autoplay && track.fileName.isEmpty { return }
        if track.fileName.isEmpty && !preferences.networkPlayback {
            errorMessage = "網路播放已關閉，可在設定啟用或改播本機音檔。"; playbackWanted = false; return
        }
        loading = true
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let audio = try await self.sources.prepare(track: track)
                guard !Task.isCancelled, token == self.generation else { return }
                self.prepared = audio; self.actualQuality = audio.quality; self.duration = audio.duration
                self.progress = min(self.progress, audio.duration)
                self.player.replaceCurrentItem(with: AVPlayerItem(url: audio.url))
                self.observeItem(); self.attachTimeObserver()
                self.loading = false
                if self.progress > 0 { self.seek(to: min(self.progress, self.duration)) }
                if self.playbackWanted { self.resume() }
                self.log("實際來源：\(audio.quality.source)；\(audio.quality.codec)，未知欄位維持未知。")
                let session = AVAudioSession.sharedInstance()
                self.log(String(format: "系統輸出取樣率 %.0f Hz；輸出聲道 %ld；輸出位元深度未知。", session.sampleRate, session.outputNumberOfChannels))
                self.persist()
            } catch {
                guard !Task.isCancelled, token == self.generation else { return }
                self.loading = false; self.playbackWanted = false
                self.errorMessage = "無法取得或解碼這首歌的音訊。請檢查來源連線與授權，或改用另一個檔案。"
                self.log("播放準備失敗；沒有變更佇列或宣稱音質成功。")
            }
        }
    }

    private func recordListening(seconds: Double, endingAt date: Date) {
        guard let track = currentTrack, seconds > 0 else { return }
        let calendar = Calendar.current
        for slice in ListeningMath.split(seconds: seconds, endingAt: date, calendar: calendar) {
            let day = calendar.startOfDay(for: slice.start)
            if eventDay != day || eventID == nil || store.events.isEmpty {
                eventID = UUID(); eventDay = day
                if let id = eventID { segmentIDs.append(id) }
            }
            guard let id = eventID else { continue }
            store.recordListening(trackID: track.id, playlistID: engine.state.playlistID, seconds: slice.seconds,
                                  at: slice.start, duration: duration, manual: eventManual && segmentIDs.count == 1,
                                  replay: eventReplay && segmentIDs.count == 1, eventID: id)
            sessionSeconds += slice.seconds
        }
    }
    private func finishEvent(completed: Bool = false, skipped: Bool = false) {
        tick()
        if let id = eventID, let index = store.events.firstIndex(where: { $0.id == id }) {
            store.events[index].completed = completed && duration > 0 && sessionSeconds / duration >= 0.9
            store.events[index].skipped = skipped
        }
        eventID = nil; eventDay = nil; segmentIDs = []; sessionSeconds = 0; resetSample()
    }
    private func resetSample() { lastMediaTime = nil; lastUptime = nil }
    private func tick() {
        guard currentTrack != nil, !loading, player.currentItem != nil else { return }
        let mediaTime = player.currentTime().seconds - activeOffset
        let uptime = ProcessInfo.processInfo.systemUptime
        if !seeking, mediaTime.isFinite {
            if let previous = lastMediaTime, let priorUptime = lastUptime {
                let seconds = ListeningMath.audibleSeconds(mediaDelta: mediaTime - previous, wallDelta: uptime - priorUptime,
                                                           playing: player.timeControlStatus == .playing, seeking: seeking)
                recordListening(seconds: seconds, endingAt: Date())
            }
            progress = max(progress, max(0, min(duration, mediaTime))); engine.state.progress = progress
            lastMediaTime = mediaTime; lastUptime = uptime
        }
        isPlaying = player.rate > 0 && player.error == nil
        publishQueue()
        if uptime - lastNowPlayingUpdate >= 1 { updateNowPlaying(); lastNowPlayingUpdate = uptime }
        if uptime - lastSaved >= 5 { persist() }
    }

    private func attachTimeObserver() {
        detachTimeObserver()
        observedPlayer = player
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }
    private func detachTimeObserver() {
        if let token = timeObserver { observedPlayer?.removeTimeObserver(token) }
        timeObserver = nil; observedPlayer = nil
    }
    private func observeItem() {
        itemStatus = player.currentItem?.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, item === self.player.currentItem, item.status == .failed else { return }
                self.pause(); self.errorMessage = "音訊解碼失敗，請重新匯入或檢查來源檔案。"
            }
        }
    }
    private func log(_ message: String) {
        diagnostics.append("\(Date().formatted(date: .omitted, time: .standard))　\(message)")
        if diagnostics.count > 80 { diagnostics.removeFirst(diagnostics.count - 80) }
    }

    private func installObservers() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: LibraryStore.tracksDidChange, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.libraryChanged() }
        })
        observers.append(center.addObserver(forName: LibraryStore.didRestoreBackup, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.eventID = nil; self.eventDay = nil; self.segmentIDs = []; self.sessionSeconds = 0
                self.resetSample(); self.engine = QueueEngine(state: self.store.queue)
                self.loadCurrent(autoplay: false, manual: false)
            }
        })
        observers.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] notification in
            Task { @MainActor in
                guard let self, let item = notification.object as? AVPlayerItem, item === self.player.currentItem else { return }
                self.finishEvent(completed: true)
                _ = self.engine.advance(automatic: true)
                self.loadCurrent(autoplay: true, manual: false, replay: self.queue.repeatMode == .one)
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                guard let self, let rawType, let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
                if type == .began { self.shouldResumeAfterInterruption = self.playbackWanted; self.pause() }
                else {
                    let resume = self.shouldResumeAfterInterruption && AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
                    self.shouldResumeAfterInterruption = false
                    if resume { self.resume() }
                }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue { Task { @MainActor in self?.pause() } }
        })
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.persist() } })
        }
    }
    private func updateNowPlaying() {
        guard let track = currentTrack else { return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: track.title, MPMediaItemPropertyArtist: track.artist,
                                  MPMediaItemPropertyAlbumTitle: track.album, MPMediaItemPropertyPlaybackDuration: duration,
                                  MPNowPlayingInfoPropertyElapsedPlaybackTime: progress, MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0]
        if cachedArtworkName != track.artworkName {
            cachedArtworkName = track.artworkName
            cachedArtworkImage = store.artworkURL(for: track).flatMap { UIImage(contentsOfFile: $0.path) }
        }
        if let image = cachedArtworkImage { info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image } }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
    private func configureRemoteCommands() {
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        commands.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        commands.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.togglePlay() }; return .success }
        commands.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }
        commands.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let position = event.positionTime
            Task { @MainActor in self?.seek(to: position) }; return .success
        }
    }
}
