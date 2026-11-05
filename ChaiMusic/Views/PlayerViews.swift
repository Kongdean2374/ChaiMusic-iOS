import SwiftUI
import UniformTypeIdentifiers

struct PlayerView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var player: PlayerController
    @Environment(\.dismiss) private var dismiss
    @State private var queue = false
    @State private var lyrics = false
    @State private var quality = false
    @State private var adding = false
    @State private var scrubbing = false
    @State private var position = 0.0
    private var track: Track? { store.tracks.first { $0.id == player.currentTrack?.id } ?? player.currentTrack }
    var body: some View {
        NavigationStack {
            ScrollView {
                if let track {
                    VStack(spacing: 24) {
                        AlbumArt(track: track, size: 250).padding(.top, 16)
                        VStack(spacing: 8) {
                            Text(track.title).font(.title.weight(.semibold)).multilineTextAlignment(.center)
                            Text(track.artist).foregroundStyle(Tea.muted)
                            Text(track.album).font(.caption).foregroundStyle(Tea.muted)
                        }
                        HStack {
                            Button { store.toggleFavorite(track.id) } label: { Label(track.isFavorite ? "已收藏" : "收藏", systemImage: track.isFavorite ? "heart.fill" : "heart") }
                            Spacer()
                            Button("加入歌單", systemImage: "text.badge.plus") { adding = true }
                        }.buttonStyle(.borderless)
                        VStack(spacing: 4) {
                            Slider(value: Binding(get: { scrubbing ? position : min(max(0, player.progress), max(1, player.duration)) }, set: { position = $0 }), in: 0...max(1, player.duration)) { editing in
                                scrubbing = editing
                                if !editing { player.seek(to: position) }
                            }.disabled(player.duration <= 0).accessibilityLabel("播放進度").accessibilityValue("\(clockText(scrubbing ? position : player.progress))，共 \(clockText(player.duration))")
                            HStack { Text(clockText(scrubbing ? position : player.progress)); Spacer(); Text(clockText(player.duration)) }.font(.caption.monospacedDigit()).foregroundStyle(Tea.muted)
                        }
                        ViewThatFits(in: .horizontal) {
                            transport(spacious: true)
                            transport(spacious: false)
                        }
                        Button { lyrics = true } label: {
                            VStack(spacing: 8) {
                                Text(activeLine(track) ?? "匯入 LRC，讓歌詞跟著音樂走")
                                    .font(.body).multilineTextAlignment(.center)
                                Label("完整歌詞", systemImage: "quote.bubble").font(.caption)
                            }.frame(maxWidth: .infinity).padding(20).background(Tea.panel, in: RoundedRectangle(cornerRadius: 18))
                        }.buttonStyle(.plain)
                        HStack {
                            Button("音質資訊", systemImage: "waveform") { quality = true }
                            Spacer()
                            Button("播放佇列", systemImage: "list.bullet") { queue = true }
                        }.font(.subheadline)
                    }.padding(24)
                } else { EmptyLibrary(title: "尚未選擇歌曲", subtitle: "從音樂庫開始播放。", symbol: "music.note") }
            }.background(Tea.background)
                .navigationTitle("正在播放").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("收起", systemImage: "chevron.down") { dismiss() } } }
                .sheet(isPresented: $queue) { QueueView() }
                .sheet(isPresented: $lyrics) { LyricsView() }
                .sheet(isPresented: $adding) { if let track { PlaylistPicker(trackID: track.id) } }
                .alert("原始檔案音質", isPresented: $quality) { Button("好", role: .cancel) {} } message: { Text((track?.quality.summary ?? "無法取得音質資訊") + "\n顯示檔案中可讀取的資訊；未知欄位不代表無損音質。") }
        }
    }
    private func activeLine(_ track: Track) -> String? {
        guard let lyrics = track.lyrics, let index = lyrics.activeIndex(at: player.progress) else { return nil }
        return lyrics.lines[index].text
    }
    private func transport(spacious: Bool) -> some View {
        HStack(spacing: spacious ? 24 : 8) {
            Button { player.setShuffle(!player.queue.shuffled) } label: { Image(systemName: "shuffle").foregroundStyle(player.queue.shuffled ? Tea.gold : Tea.muted).frame(minWidth: 44, minHeight: 44) }.accessibilityLabel(player.queue.shuffled ? "關閉洗牌" : "開啟洗牌").accessibilityAddTraits(player.queue.shuffled ? .isSelected : [])
            Button { player.previous() } label: { Image(systemName: "backward.end.fill").font(.title2).frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("上一首")
            Button { player.togglePlay() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title).frame(width: 64, height: 64).background(Tea.gold, in: Circle()).foregroundStyle(Tea.background) }.accessibilityLabel(player.isPlaying ? "暫停" : "播放")
            Button { player.next() } label: { Image(systemName: "forward.end.fill").font(.title2).frame(minWidth: 44, minHeight: 44) }.accessibilityLabel("下一首")
            Menu {
                ForEach(RepeatMode.allCases, id: \.self) { mode in Button(mode.title) { player.setRepeat(mode) } }
            } label: { Image(systemName: player.queue.repeatMode == .one ? "repeat.1" : "repeat").foregroundStyle(player.queue.repeatMode == .off ? Tea.muted : Tea.gold).frame(minWidth: 44, minHeight: 44) }.accessibilityLabel(player.queue.repeatMode.title)
        }
    }
}

struct QueueView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var player: PlayerController
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if let current = player.currentTrack {
                    Section("正在播放") { HStack { AlbumArt(track: current); Text(current.title); Spacer(); Image(systemName: "speaker.wave.2.fill").foregroundStyle(Tea.gold) } }
                }
                Section("接著播放 · \(player.upcomingIDs.count) 首") {
                    if player.upcomingIDs.isEmpty { Text("佇列已播放完畢。可從歌曲選單加入「接著播放」。").foregroundStyle(Tea.muted) }
                    ForEach(Array(player.upcomingIDs.enumerated()), id: \.offset) { item in
                        if let track = store.tracks.first(where: { $0.id == item.element }) {
                            HStack { AlbumArt(track: track, size: 36); VStack(alignment: .leading) { Text(track.title); Text(track.artist).font(.caption).foregroundStyle(Tea.muted) } }
                        }
                    }.onDelete { player.removeUpcoming(at: $0) }.onMove { player.moveUpcoming(from: $0, to: $1) }
                }
                Section { Text("點選「編輯」可刪除或拖曳調整接續順序。循環會沿用播放器設定。 ").font(.caption).foregroundStyle(Tea.muted) }
            }.scrollContentBackground(.hidden).background(Tea.background)
                .navigationTitle("播放佇列")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) { EditButton() }
                }
        }
    }
}

struct LyricsView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var player: PlayerController
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var importing = false
    @State private var error: String?
    @State private var translation = false
    private var track: Track? { store.tracks.first { $0.id == player.currentTrack?.id } }
    private var lyrics: Lyrics? { track?.lyrics }
    private var active: Int? { lyrics?.activeIndex(at: player.progress) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let lyrics, !lyrics.lines.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(lyrics.confidence).font(.caption).foregroundStyle(Tea.muted)
                        Stepper(value: Binding(get: { self.lyrics?.offset ?? 0 }, set: { value in
                            guard let track, var updated = track.lyrics else { return }
                            updated.offset = value
                            store.updateLyrics(trackID: track.id, lyrics: updated)
                        }), in: -60...60, step: 0.1) {
                            Text("歌詞延遲 \(lyrics.offset, specifier: "%.1f") 秒").font(.subheadline.monospacedDigit())
                        }
                        Text("正值讓歌詞較晚出現；點選任一句可跳至該處。").font(.caption).foregroundStyle(Tea.muted)
                        Toggle("顯示翻譯", isOn: $translation)
                        if translation && !lyrics.lines.contains(where: { $0.translation != nil }) {
                            Text("這份歌詞沒有提供翻譯，目前不提供自動翻譯。 ").font(.caption).foregroundStyle(Tea.gold)
                        }
                    }.padding()
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 28) {
                                ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { item in
                                    Button {
                                        player.seek(to: max(0, item.element.time + lyrics.offset))
                                    } label: {
                                        VStack(alignment: .leading, spacing: 8) {
                                            lyricText(item.element, isActive: active == item.offset, offset: lyrics.offset)
                                                .font(.title2.weight(active == item.offset ? .bold : .medium))
                                            if translation, let value = item.element.translation { Text(value).font(.body).foregroundStyle(Tea.muted) }
                                        }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                                    }.buttonStyle(.plain).id(item.offset)
                                        .accessibilityLabel("\(item.element.text)，跳至 \(clockText(item.element.time + lyrics.offset))")
                                }
                            }.padding(24)
                        }
                        .onChange(of: active) { _, value in
                            guard let value else { return }
                            if reduceMotion { proxy.scrollTo(value, anchor: .center) }
                            else { withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(value, anchor: .center) } }
                        }
                    }
                } else { EmptyLibrary(title: "還沒有這首歌的歌詞", subtitle: "匯入對應版本的 LRC 歌詞檔。支援時間標記與逐字時間標記。", symbol: "quote.bubble") }
            }
            .background(Tea.background).navigationTitle("歌詞").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("匯入 LRC") { importing = true }.disabled(track == nil) }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .data]) { result in
                do {
                    let url = try result.get()
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let data = try Data(contentsOf: url)
                    guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else {
                        error = "無法讀取編碼，請提供 UTF-8 或 UTF-16 的 LRC 檔案。"; return
                    }
                    let parsed = LRCParser.parse(text)
                    guard !parsed.lines.isEmpty else { error = "未找到有效的時間標記歌詞，請檢查 LRC 內容。"; return }
                    if let track { store.updateLyrics(trackID: track.id, lyrics: parsed) }
                } catch { self.error = "無法讀取歌詞檔案，請確認檔案權限與內容。" }
            }
            .alert("無法匯入歌詞", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
        }
    }
    private func lyricText(_ line: LyricLine, isActive: Bool, offset: Double) -> Text {
        guard isActive, !line.words.isEmpty else { return Text(line.text).foregroundColor(isActive ? Tea.gold : Tea.muted) }
        return line.words.reduce(Text("")) { text, word in
            text + Text(word.text).foregroundColor(player.progress >= word.time + offset ? Tea.gold : Tea.muted)
        }
    }
}
