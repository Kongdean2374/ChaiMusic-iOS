import SwiftUI

// 茶金與墨綠共同構成全站視覺；文字採系統字體支援動態字級。
enum Tea {
    static let background = Color(red: 0.035, green: 0.075, blue: 0.065)
    static let panel = Color(red: 0.075, green: 0.13, blue: 0.11)
    static let gold = Color(red: 0.88, green: 0.75, blue: 0.48)
    static let muted = Color(red: 0.66, green: 0.75, blue: 0.69)
}

func clockText(_ seconds: Double) -> String {
    let value = seconds.isFinite ? Int(max(0, seconds)) : 0
    return String(format: "%d:%02d", value / 60, value % 60)
}

struct AlbumArt: View {
    @EnvironmentObject private var store: LibraryStore
    let track: Track?
    var size: CGFloat = 48
    var body: some View {
        Group {
            if let track, let url = store.artworkURL(for: track),
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    LinearGradient(colors: [Tea.panel, Color(red: 0.19, green: 0.30, blue: 0.22)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: "leaf.fill").font(.system(size: size * 0.35)).foregroundStyle(Tea.gold)
                }
            }
        }
        .frame(width: size, height: size).clipShape(RoundedRectangle(cornerRadius: size * 0.18))
        .accessibilityHidden(true)
    }
}

struct EmptyLibrary: View {
    var title = "讓音樂，慢慢回甘"
    var subtitle = "點選右上角匯入，將自己的音訊檔案收藏在這裡。"
    var symbol = "leaf"
    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: { Text(subtitle) }
        .foregroundStyle(Tea.muted)
        .frame(maxWidth: .infinity, minHeight: 220)
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
        HStack(spacing: 12) {
            Button {
                player.play(ids: context, startID: track.id, playlistID: playlistID)
            } label: {
                HStack(spacing: 12) {
                    AlbumArt(track: track)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title).font(.body.weight(.medium)).foregroundStyle(.primary)
                        Text(track.artist).font(.subheadline).foregroundStyle(Tea.muted)
                    }
                    Spacer(minLength: 4)
                    if player.currentTrack?.id == track.id {
                        Image(systemName: player.isPlaying ? "speaker.wave.2.fill" : "pause.fill").foregroundStyle(Tea.gold)
                    }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("播放 \(track.title)，\(track.artist)")
            Menu {
                Button(track.isFavorite ? "取消收藏" : "收藏", systemImage: track.isFavorite ? "heart.slash" : "heart") { store.toggleFavorite(track.id) }
                Button("接著播放", systemImage: "text.line.first.and.arrowtriangle.forward") { player.insertNext(track.id) }
                Button("加入歌單", systemImage: "text.badge.plus") { adding = true }
                Button("刪除歌曲", systemImage: "trash", role: .destructive) { deleting = true }
                if let playlistID {
                    Button("從歌單移除", systemImage: "minus.circle", role: .destructive) { store.removeFromPlaylist(trackID: track.id, playlistID: playlistID) }
                }
            } label: { Image(systemName: "ellipsis").frame(minWidth: 44, minHeight: 44) }
            .accessibilityLabel("\(track.title)的更多操作")
        }
        .padding(.vertical, 4)
        .sheet(isPresented: $adding) { PlaylistPicker(trackID: track.id) }
        .confirmationDialog("從音樂庫及所有歌單刪除這首歌曲？", isPresented: $deleting, titleVisibility: .visible) {
            Button("刪除歌曲與本機副本", role: .destructive) { store.deleteTrack(track.id) }
            Button("取消", role: .cancel) {}
        }
    }
}

struct PlaylistPicker: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let trackID: UUID
    @State private var name = ""
    var body: some View {
        NavigationStack {
            List {
                Section("新增歌單") {
                    TextField("歌單名稱", text: $name)
                    Button("建立並加入") {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return }
                        store.createPlaylist(name: trimmed)
                        if let playlist = store.playlists.last { store.addToPlaylist(trackID: trackID, playlistID: playlist.id) }
                        dismiss()
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section("選擇歌單") {
                    ForEach(store.playlists) { playlist in
                        Button {
                            store.addToPlaylist(trackID: trackID, playlistID: playlist.id)
                            dismiss()
                        } label: {
                            HStack { Text(playlist.name); Spacer(); if playlist.trackIDs.contains(trackID) { Image(systemName: "checkmark") } }
                        }
                    }
                }
            }
            .navigationTitle("加入歌單")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}

struct TrackCollection: View {
    @EnvironmentObject private var store: LibraryStore
    let title: String
    let tracks: [Track]
    var playlistID: UUID? = nil
    @EnvironmentObject private var player: PlayerController
    var body: some View {
        List {
            if tracks.isEmpty { EmptyLibrary(title: "還沒有歌曲", subtitle: "匯入音訊或從音樂庫加入歌曲。") }
            else {
                Section {
                    Text("\(tracks.count) 首 · 完整集合").font(.caption).foregroundStyle(Tea.muted)
                    if let playlistID {
                        DisclosureGroup("歌單聆聽摘要") {
                            let records = store.events.filter { $0.playlistID == playlistID }
                            Text("聆聽 \(Int(records.reduce(0) { $0 + $1.seconds })) 秒 · \(records.count) 次紀錄")
                                .font(.caption).foregroundStyle(Tea.muted)
                        }
                    }
                    HStack {
                        Button("播放全部", systemImage: "play.fill") { player.play(ids: tracks.map(\.id), playlistID: playlistID) }
                        Spacer()
                        Button("洗牌", systemImage: "shuffle") { player.play(ids: tracks.map(\.id), shuffle: true, playlistID: playlistID) }
                    }.buttonStyle(.bordered)
                }
                ForEach(tracks) { track in TrackRow(track: track, context: tracks.map(\.id), playlistID: playlistID) }
            }
        }
        .scrollContentBackground(.hidden).background(Tea.background)
        .navigationTitle(title)
    }
}
