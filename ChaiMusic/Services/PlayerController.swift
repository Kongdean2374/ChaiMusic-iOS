import Foundation
import Combine
import AVFoundation
import MediaPlayer
import UIKit

@MainActor
final class PlayerController: ObservableObject {
    @Published var currentTrack: Track?
    @Published var isPlaying = false
    @Published var progress: Double = 0
    @Published var duration: Double = 0
    @Published var errorMessage: String?
    @Published var queue: QueueState
    private let store: LibraryStore
    private let player = AVPlayer()
    private var engine: QueueEngine
    private var timeObserver: Any?
    private var cachedArtworkName: String?
    private var cachedArtworkImage: UIImage?
    private var observers: [NSObjectProtocol] = []
    private var itemStatus: NSKeyValueObservation?
    private var eventID: UUID?
    private var eventPrepared = false
    private var eventManual = false
    private var eventReplay = false
    private var lastMediaTime: Double?
    private var lastUptime: TimeInterval?
    private var lastSaved: TimeInterval = 0
    private var seeking = false
    private var seekGeneration = 0
    private var shouldResumeAfterInterruption = false
    var upcomingIDs: [UUID] { engine.upcomingIDs }

    init(store: LibraryStore) {
        self.store = store
        engine = QueueEngine(state: store.queue)
        queue = store.queue
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        } catch { errorMessage = "無法設定背景音訊，請重新啟動應用程式。" }
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: LibraryStore.tracksDidChange, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.libraryChanged() }
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
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor in
                guard let self, let rawType, let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
                if type == .began {
                    self.shouldResumeAfterInterruption = self.isPlaying
                    self.pause()
                } else if self.shouldResumeAfterInterruption, AVAudioSession.InterruptionOptions(rawValue: rawOptions).contains(.shouldResume) {
                    self.shouldResumeAfterInterruption = false
                    self.resume()
                } else { self.shouldResumeAfterInterruption = false }
            }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
                Task { @MainActor in self?.pause() }
            }
        })
        for name in [UIApplication.didEnterBackgroundNotification, UIApplication.willTerminateNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.persist() }
            })
        }
        configureRemoteCommands()
        loadCurrent(autoplay: false, manual: false)
    }

    func play(ids: [UUID], startID: UUID? = nil, shuffle: Bool = false, playlistID: UUID? = nil) {
        let previousID = currentTrack?.id
        finishEvent(skipped: true)
        let valid = Set(store.tracks.map(\.id))
        engine.start(ids: ids.filter { valid.contains($0) }, startID: startID, shuffle: shuffle, playlistID: playlistID)
        loadCurrent(autoplay: true, manual: true, replay: previousID != nil && engine.state.currentID == previousID)
    }
    func togglePlay() { isPlaying ? pause() : resume() }
    func pause() {
        tick(); player.pause(); isPlaying = false
        resetSample(); persist(); updateNowPlaying()
    }
    private func resume() {
        guard currentTrack != nil, player.currentItem != nil else { return }
        do { try AVAudioSession.sharedInstance().setActive(true) }
        catch { errorMessage = "無法啟動音訊播放，請確認音訊輸出裝置後再試。"; return }
        if !eventPrepared { beginEvent(manual: true, replay: false) }
        resetSample(); player.play(); isPlaying = true; updateNowPlaying()
    }
    func next() {
        finishEvent(skipped: true)
        _ = engine.advance()
        loadCurrent(autoplay: true, manual: true)
    }
    func previous() {
        if progress > 3 { seek(to: 0); return }
        finishEvent(skipped: true)
        _ = engine.previous()
        loadCurrent(autoplay: true, manual: true, replay: true)
    }
    func seek(to seconds: Double) {
        guard seconds.isFinite, currentTrack != nil else { return }
        tick()
        seekGeneration += 1
        let generation = seekGeneration
        seeking = true; resetSample()
        let target = max(0, min(seconds, duration > 0 ? duration : seconds))
        progress = target; engine.state.progress = target
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                guard let self, generation == self.seekGeneration else { return }
                self.seeking = false; self.resetSample(); self.persist(); self.updateNowPlaying()
            }
        }
        publishQueue()
    }
    func insertNext(_ id: UUID) {
        guard store.tracks.contains(where: { $0.id == id }) else { return }
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

    private func libraryChanged() {
        let oldID = currentTrack?.id
        let wasPlaying = isPlaying
        engine.reconcile(validIDs: Set(store.tracks.map(\.id)))
        if oldID != engine.state.currentID {
            finishEvent(skipped: true)
            engine.state.progress = 0
            loadCurrent(autoplay: wasPlaying, manual: false)
        } else {
            currentTrack = store.tracks.first { $0.id == oldID }
            publishQueue(); updateNowPlaying()
        }
    }

    private func loadCurrent(autoplay: Bool, manual: Bool, replay: Bool = false) {
        player.pause(); isPlaying = false
        itemStatus = nil
        seekGeneration += 1; seeking = false; resetSample()
        currentTrack = store.tracks.first { $0.id == engine.state.currentID }
        progress = max(0, engine.state.progress.isFinite ? engine.state.progress : 0)
        duration = currentTrack?.duration ?? 0
        guard let track = currentTrack else {
            player.replaceCurrentItem(with: nil); progress = 0; duration = 0
            persist(); MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        let url = store.fileURL(for: track)
        guard FileManager.default.fileExists(atPath: url.path) else {
            player.replaceCurrentItem(with: nil)
            errorMessage = "找不到歌曲檔案：\(track.title)"
            persist(); updateNowPlaying(); return
        }
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        itemStatus = item.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
            Task { @MainActor in
                guard let self, observed === self.player.currentItem else { return }
                if observed.status == .failed {
                    self.errorMessage = "無法播放歌曲，檔案可能損毀或格式不受支援。"
                    self.pause()
                }
            }
        }
        if progress > 0 { seek(to: duration > 0 ? min(progress, duration) : progress) }
        if autoplay { beginEvent(manual: manual, replay: replay); resume() }
        persist(); updateNowPlaying()
    }

    private func beginEvent(manual: Bool, replay: Bool) {
        eventPrepared = true
        eventManual = manual
        eventReplay = replay
    }
    private func recordListening(seconds: Double) {
        guard let track = currentTrack, seconds > 0 else { return }
        if let eventID, !store.events.contains(where: { $0.id == eventID }) { self.eventID = nil }
        if eventID == nil {
            let event = ListeningEvent(trackID: track.id, playlistID: engine.state.playlistID, duration: duration, manual: eventManual, replay: eventReplay)
            store.events.append(event)
            eventID = event.id
        }
        if let eventID, let index = store.events.firstIndex(where: { $0.id == eventID }) {
            store.events[index].seconds += seconds
            store.events[index].duration = duration
        }
    }
    private func finishEvent(completed: Bool = false, skipped: Bool = false) {
        tick()
        if let eventID, let index = store.events.firstIndex(where: { $0.id == eventID }) {
            store.events[index].completed = completed
            store.events[index].skipped = skipped
            store.events[index].duration = duration
            if store.events[index].seconds <= 0 { store.events.remove(at: index) }
        }
        eventID = nil; eventPrepared = false; resetSample()
    }
    private func resetSample() { lastMediaTime = nil; lastUptime = nil }
    private func tick() {
        guard currentTrack != nil else { return }
        let mediaTime = player.currentTime().seconds
        let uptime = ProcessInfo.processInfo.systemUptime
        let itemDuration = player.currentItem?.duration.seconds ?? 0
        if itemDuration.isFinite, itemDuration > 0 { duration = itemDuration }
        if !seeking, mediaTime.isFinite {
            if player.timeControlStatus == .playing, let previous = lastMediaTime, let priorUptime = lastUptime {
                let delta = mediaTime - previous
                let elapsed = uptime - priorUptime
                // 只計入實際前進且受經過時間限制的播放秒數，跳轉不算收聽。
                if delta > 0, elapsed > 0, delta <= elapsed + 0.25 {
                    recordListening(seconds: min(delta, elapsed))
                }
            }
            progress = max(0, mediaTime)
            engine.state.progress = progress
            lastMediaTime = mediaTime; lastUptime = uptime
        }
        isPlaying = player.rate > 0 && player.error == nil
        publishQueue(); updateNowPlaying()
        if uptime - lastSaved >= 10 { persist() }
    }

    private func updateNowPlaying() {
        guard let track = currentTrack else { return }
        var info: [String: Any] = [MPMediaItemPropertyTitle: track.title, MPMediaItemPropertyArtist: track.artist, MPMediaItemPropertyAlbumTitle: track.album, MPMediaItemPropertyPlaybackDuration: duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: progress, MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0]
        if cachedArtworkName != track.artworkName {
            cachedArtworkName = track.artworkName
            cachedArtworkImage = store.artworkURL(for: track).flatMap { UIImage(contentsOfFile: $0.path) }
        }
        if let image = cachedArtworkImage {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }
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
            Task { @MainActor in self?.seek(to: position) }
            return .success
        }
    }
}
