import SwiftUI
import UIKit

enum Tea {
    static let background = Color(red: 0.025, green: 0.055, blue: 0.047)
    static let panel = Color(red: 0.065, green: 0.105, blue: 0.089)
    static let raised = Color(red: 0.10, green: 0.16, blue: 0.13)
    static let gold = Color(red: 0.89, green: 0.77, blue: 0.52)
    static let muted = Color(red: 0.65, green: 0.73, blue: 0.68)
    static let line = Color.white.opacity(0.08)
    static let radius: CGFloat = 22
}

func clockText(_ seconds: Double) -> String {
    let value = seconds.isFinite ? Int(max(0, seconds)) : 0
    return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60)
        : String(format: "%d:%02d", value / 60, value % 60)
}

struct SectionHeading: View {
    let title: String
    var caption: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.weight(.semibold))
            Spacer()
            if let caption { Text(caption).font(.caption).foregroundStyle(Tea.muted) }
        }.padding(.top, 8)
    }
}

struct TeaAction: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.semibold))
            .padding(.horizontal, 18).padding(.vertical, 13)
            .foregroundStyle(prominent ? Tea.background : Tea.gold)
            .background(prominent ? Tea.gold : Tea.raised, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct AlbumArt: View {
    @EnvironmentObject private var store: LibraryStore
    let track: Track?
    var size: CGFloat = 48
    @State private var thumbnail: UIImage?
    private var url: URL? { track.flatMap { store.artworkURL(for: $0) } }
    var body: some View {
        ZStack {
            LinearGradient(colors: [Tea.raised, Tea.panel], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let thumbnail { Image(uiImage: thumbnail).resizable().scaledToFill() }
            else {
                Circle().stroke(Tea.gold.opacity(0.12), lineWidth: max(1, size * 0.015)).padding(size * 0.15)
                Circle().stroke(Tea.gold.opacity(0.08), lineWidth: 1).padding(size * 0.23)
                Image(systemName: "leaf.fill").font(.system(size: size * 0.23, weight: .light)).foregroundStyle(Tea.gold)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: max(8, size * 0.08)))
        .overlay(RoundedRectangle(cornerRadius: max(8, size * 0.08)).stroke(Color.white.opacity(0.08), lineWidth: 1))
        .accessibilityHidden(true)
        .task(id: "\(url?.path ?? "")|\(Int(size))") {
            thumbnail = nil
            guard let url else { return }
            let image = await ArtworkCache.shared.thumbnail(url: url, pixels: Int(size * 3))
            guard !Task.isCancelled else { return }
            thumbnail = image?.image
        }
    }
}

struct ArtworkBackdrop: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    let track: Track?
    @State private var tint = Color(red: 0.18, green: 0.34, blue: 0.25)
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var moving: Bool {
        preferences.animatedArtwork && !reduceMotion && scenePhase == .active && !(preferences.respectLowPower && lowPower)
    }
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 15, paused: !moving)) { timeline in
            let time = moving ? timeline.date.timeIntervalSinceReferenceDate : 0
            Canvas { context, size in
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Tea.background))
                let x = size.width * (0.4 + 0.25 * sin(time / 14))
                let y = size.height * (0.3 + 0.12 * cos(time / 17))
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
                    Gradient(colors: [tint.opacity(0.8), tint.opacity(0.22), .clear]),
                    center: CGPoint(x: x, y: y), startRadius: 0, endRadius: max(size.width, size.height) * 0.8))
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .radialGradient(
                    Gradient(colors: [Tea.gold.opacity(0.12), .clear]),
                    center: CGPoint(x: size.width - x, y: size.height * 0.8), startRadius: 0, endRadius: size.width))
            }
        }
        .overlay(LinearGradient(colors: [.clear, Tea.background.opacity(0.9)], startPoint: .top, endPoint: .bottom))
        .ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
        .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled }
        .task(id: track?.artworkName) {
            if let track, let url = store.artworkURL(for: track), let result = await ArtworkCache.shared.thumbnail(url: url, pixels: 120) {
                tint = Color(uiColor: result.tint)
            } else { tint = Tea.raised }
        }
    }
}

struct EmptyLibrary: View {
    var title = "讓音樂，慢慢回甘"
    var subtitle = "匯入自己的音樂，或連接有權使用的私人音樂庫。"
    var symbol = "leaf"
    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Circle().stroke(Tea.gold.opacity(0.12), lineWidth: 1).frame(width: 106, height: 106)
                Circle().fill(Tea.raised).frame(width: 80, height: 80)
                Image(systemName: symbol).font(.system(size: 32, weight: .light)).foregroundStyle(Tea.gold)
            }
            Text(title).font(.title3.weight(.medium)).multilineTextAlignment(.center)
            Text(subtitle).font(.subheadline).foregroundStyle(Tea.muted).multilineTextAlignment(.center).lineSpacing(4)
        }.padding(28).frame(maxWidth: .infinity, minHeight: 250)
    }
}

struct TrackRow: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var player: PlayerController
    let track: Track
    let context: [UUID]
    var playlistID: UUID? = nil
    @State private var adding = false
    @State private var deleting = false
    var body: some View {
        HStack(spacing: 10) {
            Button {
                player.play(ids: context, startID: track.id, playlistID: playlistID)
            } label: {
                HStack(spacing: 13) {
                    AlbumArt(track: track, size: 52)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(track.title).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                        HStack(spacing: 5) {
                            if track.fileName.isEmpty { Image(systemName: "network").font(.caption2) }
                            Text(track.artist).font(.subheadline).lineLimit(1)
                        }.foregroundStyle(Tea.muted)
                    }
                    Spacer(minLength: 3)
                    if player.currentTrack?.id == track.id {
                        Image(systemName: player.isPlaying ? "waveform" : "pause.fill").foregroundStyle(Tea.gold)
                    } else { Text(clockText(track.duration)).font(.caption.monospacedDigit()).foregroundStyle(Tea.muted) }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("播放 \(track.title)，\(track.artist)")
            Menu {
                Button(track.isFavorite ? "取消收藏" : "收藏", systemImage: track.isFavorite ? "heart.slash" : "heart") { store.toggleFavorite(track.id) }
                Button("接著播放", systemImage: "text.line.first.and.arrowtriangle.forward") { player.insertNext(track.id) }
                Button("加入歌單", systemImage: "text.badge.plus") { adding = true }
                if let playlistID { Button("從歌單移除", systemImage: "minus.circle", role: .destructive) { store.removeFromPlaylist(trackID: track.id, playlistID: playlistID) } }
                Button("刪除歌曲", systemImage: "trash", role: .destructive) { deleting = true }
            } label: { Image(systemName: "ellipsis").foregroundStyle(Tea.muted).frame(width: 44, height: 44) }
            .accessibilityLabel("\(track.title)的更多操作")
        }.padding(.vertical, 5)
            .sheet(isPresented: $adding) { PlaylistPicker(trackIDs: [track.id]) }
            .confirmationDialog("從音樂庫及歌單刪除這首歌曲？", isPresented: $deleting, titleVisibility: .visible) {
                Button("刪除歌曲與本機副本", role: .destructive) { store.deleteTrack(track.id) }
                Button("取消", role: .cancel) {}
            }
    }
}

struct PlaylistPicker: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let trackIDs: [UUID]
    @State private var name = ""
    var body: some View {
        NavigationStack {
            List {
                Section("建立歌單並加入 \(trackIDs.count) 首") {
                    TextField("歌單名稱", text: $name)
                    Button("建立並加入") {
                        store.createPlaylist(name: name)
                        if let last = store.playlists.last { store.addTracks(trackIDs, to: last.id) }
                        dismiss()
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section("選擇歌單") {
                    ForEach(store.playlists) { playlist in
                        Button { store.addTracks(trackIDs, to: playlist.id); dismiss() } label: {
                            HStack { Label(playlist.name, systemImage: "music.note.list"); Spacer(); Text("\(playlist.trackIDs.count) 首").foregroundStyle(Tea.muted) }
                        }
                    }
                }
            }.scrollContentBackground(.hidden).background(Tea.background)
                .navigationTitle("加入歌單")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}

struct TrackCollection: View {
    @EnvironmentObject private var player: PlayerController
    let title: String
    let tracks: [Track]
    var playlistID: UUID? = nil
    var body: some View {
        let ids = tracks.map(\.id)
        List {
            Section {
                CollectionHeader(title: title, tracks: tracks, playlistID: playlistID)
            }.listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 12, leading: 0, bottom: 20, trailing: 0))
            if tracks.isEmpty { EmptyLibrary(title: "還沒有歌曲", subtitle: "從音樂庫或來源加入歌曲。") }
            ForEach(tracks) { TrackRow(track: $0, context: ids, playlistID: playlistID).listRowBackground(Color.clear) }
        }.listStyle(.plain).scrollContentBackground(.hidden).background(Tea.background)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
}

struct CollectionHeader: View {
    @EnvironmentObject private var player: PlayerController
    let title: String
    let tracks: [Track]
    var playlistID: UUID? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .bottom, spacing: 18) {
                AlbumArt(track: tracks.first, size: 106)
                VStack(alignment: .leading, spacing: 10) {
                    Text("CHAI COLLECTION").font(.caption2.weight(.semibold)).tracking(2).foregroundStyle(Tea.gold)
                    Text(title).font(.title2.weight(.semibold)).lineLimit(3)
                    Text("\(tracks.count) 首 · \(clockText(tracks.reduce(0) { $0 + $1.duration }))").font(.caption).foregroundStyle(Tea.muted)
                }
            }
            HStack(spacing: 12) {
                Button("播放", systemImage: "play.fill") { player.play(ids: tracks.map(\.id), playlistID: playlistID) }.buttonStyle(TeaAction(prominent: true))
                Button("完整隨機", systemImage: "shuffle") { player.play(ids: tracks.map(\.id), shuffle: true, playlistID: playlistID) }.buttonStyle(TeaAction())
            }.disabled(tracks.isEmpty)
        }.padding(.horizontal, 20)
    }
}
