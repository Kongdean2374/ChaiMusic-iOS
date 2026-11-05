import SwiftUI
import UniformTypeIdentifiers

struct AppShell: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var player: PlayerController
    @State private var importing = false
    @State private var busy = false
    @State private var message: String?
    @State private var showingPlayer = false

    var body: some View {
        TabView {
            navigation { HomeView() }.tabItem { Label("聽音樂", systemImage: "leaf") }
            navigation { LibraryView() }.tabItem { Label("音樂庫", systemImage: "square.stack") }
            navigation { PlaylistsView() }.tabItem { Label("歌單", systemImage: "music.note.list") }
            navigation { ListeningView() }.tabItem { Label("聆聽", systemImage: "chart.bar") }
            navigation { SettingsView() }.tabItem { Label("設定", systemImage: "slider.horizontal.3") }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let track = player.currentTrack {
                HStack(spacing: 12) {
                    Button { showingPlayer = true } label: {
                        HStack {
                            AlbumArt(track: track, size: 40)
                            VStack(alignment: .leading) {
                                Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                                Text(track.artist).font(.caption).foregroundStyle(Tea.muted).lineLimit(1)
                            }
                            Spacer()
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel("開啟播放器，\(track.title)")
                    Button { player.togglePlay() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 44, height: 44) }.accessibilityLabel(player.isPlaying ? "暫停" : "播放")
                    Button { player.next() } label: { Image(systemName: "forward.end.fill").frame(width: 44, height: 44) }.accessibilityLabel("下一首")
                }.padding(.horizontal).padding(.vertical, 8).background(Tea.panel)
            }
        }
        .sheet(isPresented: $showingPlayer) { PlayerView() }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                busy = true
                Task {
                    let imported = await MediaImporter(root: store.root).importAudio(urls: urls)
                    store.add(imported.tracks)
                    busy = false
                    message = "已匯入 \(imported.tracks.count) 首歌曲。" + (imported.failures.isEmpty ? "" : "\n" + imported.failures.joined(separator: "\n"))
                }
            case .failure: message = "無法讀取選取的檔案，請確認檔案仍可存取。"
            }
        }
        .overlay { if busy { ProgressView("正在匯入音樂…").padding(24).background(Tea.panel, in: RoundedRectangle(cornerRadius: 20)) } }
        .alert("提示", isPresented: Binding(get: { message != nil || store.errorMessage != nil || player.errorMessage != nil }, set: { if !$0 { message = nil; store.errorMessage = nil; player.errorMessage = nil } })) {
            Button("好") { message = nil; store.errorMessage = nil; player.errorMessage = nil }
        } message: { Text(message ?? store.errorMessage ?? player.errorMessage ?? "") }
    }

    private func navigation<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content()
                .background(Tea.background)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { importing = true } label: { Label("匯入音樂", systemImage: "plus.circle") }.disabled(busy)
                    }
                }
        }
    }
}
