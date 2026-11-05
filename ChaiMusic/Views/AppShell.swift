import SwiftUI
import UniformTypeIdentifiers

struct AppShell: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var sources: SourceManager
    @State private var importing = false
    @State private var busy = false
    @State private var message: String?
    @State private var showingPlayer = false
    var body: some View {
        TabView {
            navigation { HomeView(openPlayer: { showingPlayer = true }) }.tabItem { Label("聽音樂", systemImage: "leaf") }
            navigation { LibraryView() }.tabItem { Label("音樂庫", systemImage: "square.stack") }
            navigation { SourcesView() }.tabItem { Label("來源", systemImage: "network") }
            navigation { ListeningView() }.tabItem { Label("足跡", systemImage: "chart.bar.xaxis") }
            navigation { SettingsView() }.tabItem { Label("設定", systemImage: "slider.horizontal.3") }
        }
        .disabled(store.restoring)
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
            case .failure: message = "無法讀取選取的檔案，請確認來源仍可存取。"
            }
        }
        .overlay(alignment: .top) {
            if busy { HStack { ProgressView(); Text("正在讀取音樂與封面…").font(.subheadline) }.padding(16).background(Tea.panel, in: Capsule()).padding(.top, 8).accessibilityAddTraits(.updatesFrequently) }
        }
        .alert("提示", isPresented: Binding(get: { activeMessage != nil }, set: { if !$0 { clearMessage() } })) {
            Button("好") { clearMessage() }
        } message: { Text(activeMessage ?? "") }
    }
    private var activeMessage: String? { message ?? store.errorMessage ?? player.errorMessage ?? sources.errorMessage }
    private func clearMessage() { message = nil; store.errorMessage = nil; player.errorMessage = nil; sources.errorMessage = nil }
    private func navigation<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        NavigationStack {
            content().background(Tea.background)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if player.currentTrack != nil { MiniPlayer(open: { showingPlayer = true }) }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { importing = true } label: { Image(systemName: "plus.circle").font(.title3).frame(width: 44, height: 44) }
                            .disabled(busy).accessibilityLabel("從檔案匯入音樂，包含已連接的 SMB 伺服器")
                    }
                }
        }
    }
}

struct MiniPlayer: View {
    @EnvironmentObject private var player: PlayerController
    let open: () -> Void
    var body: some View {
        VStack(spacing: 0) {
            ProgressView(value: min(player.progress, max(1, player.duration)), total: max(1, player.duration)).tint(Tea.gold).accessibilityHidden(true)
            HStack(spacing: 8) {
                Button(action: open) {
                    HStack(spacing: 12) {
                        AlbumArt(track: player.currentTrack, size: 42)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(player.currentTrack?.title ?? "").font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text(player.loading ? "正在下載並準備音訊…" : player.currentTrack?.artist ?? "").font(.caption).foregroundStyle(Tea.muted).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel("展開播放器")
                if player.loading { ProgressView().frame(width: 44, height: 44) }
                else { Button { player.togglePlay() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 44, height: 44) }.accessibilityLabel(player.isPlaying ? "暫停" : "播放") }
                Button { player.next() } label: { Image(systemName: "forward.end.fill").frame(width: 44, height: 44) }.accessibilityLabel("下一首")
            }.padding(.horizontal, 14).padding(.vertical, 9)
        }.background(Tea.panel).overlay(alignment: .top) { Rectangle().fill(Tea.line).frame(height: 0.5) }
    }
}
