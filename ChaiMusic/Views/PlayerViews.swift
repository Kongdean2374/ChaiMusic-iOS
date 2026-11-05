import SwiftUI
import AVFoundation

struct PlayerView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var lyricsService: LyricsService
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var queue = false
    @State private var lyrics = false
    @State private var diagnostics = false
    @State private var adding = false
    @State private var scrubbing = false
    @State private var position = 0.0
    private var track: Track? { player.currentTrack.flatMap { store.trackByID[$0.id] } ?? player.currentTrack }
    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ZStack {
                    ArtworkBackdrop(track: track)
                    ScrollView {
                        if let track {
                            VStack(spacing: 25) {
                                AlbumArt(track: track, size: max(180, min(geometry.size.width - 64, 330)))
                                    .shadow(color: .black.opacity(0.35), radius: 25, y: 16)
                                    .scaleEffect(player.isPlaying ? 1 : 0.96)
                                    .animation(reduceMotion ? nil : .spring(response: 0.6, dampingFraction: 0.85), value: player.isPlaying)
                                    .padding(.top, 16)
                                    .gesture(DragGesture(minimumDistance: 45).onEnded { value in
                                        guard abs(value.translation.width) > 90, abs(value.translation.height) < 60 else { return }
                                        value.translation.width < 0 ? player.next() : player.previous()
                                    })
                                HStack(alignment: .top, spacing: 14) {
                                    VStack(alignment: .leading, spacing: 7) {
                                        Text(track.title).font(.title.weight(.semibold)).tracking(-0.5).fixedSize(horizontal: false, vertical: true)
                                        Text(track.artist).font(.title3).foregroundStyle(Tea.muted)
                                        Text(track.album).font(.caption).foregroundStyle(Tea.muted)
                                    }
                                    Spacer(minLength: 0)
                                    Button { store.toggleFavorite(track.id) } label: { Image(systemName: track.isFavorite ? "heart.fill" : "heart").font(.title2).foregroundStyle(track.isFavorite ? Tea.gold : Tea.muted).frame(width: 44, height: 44) }.accessibilityLabel(track.isFavorite ? "取消收藏" : "收藏")
                                }
                                VStack(spacing: 8) {
                                    Slider(value: Binding(get: { scrubbing ? position : min(max(0, player.progress), max(1, player.duration)) }, set: { position = $0 }), in: 0...max(1, player.duration)) { editing in
                                        if editing { position = player.progress }
                                        scrubbing = editing
                                        if !editing { player.seek(to: position) }
                                    }.disabled(player.duration <= 0 || player.loading)
                                        .accessibilityLabel("播放進度").accessibilityValue("\(clockText(player.progress))，共 \(clockText(player.duration))")
                                    HStack { Text(clockText(scrubbing ? position : player.progress)); Spacer(); Text(clockText(player.duration)) }.font(.caption.monospacedDigit()).foregroundStyle(Tea.muted)
                                    Button { lyrics = true } label: {
                                        VStack(spacing: 5) {
                                            Text(activeLine(track) ?? (track.lyrics?.staticText?.isEmpty == false ? "已提供文字歌詞" : "讓歌詞，陪你聽見每個字"))
                                                .font(.subheadline.weight(.medium)).lineLimit(2).multilineTextAlignment(.center)
                                            Image(systemName: "chevron.down").font(.caption2).foregroundStyle(Tea.muted)
                                        }.frame(maxWidth: .infinity, minHeight: 56)
                                    }.buttonStyle(.plain).accessibilityLabel("開啟完整歌詞，\(activeLine(track) ?? "尚無同步歌詞")")
                                }
                                ViewThatFits(in: .horizontal) { transport(spacing: 25); transport(spacing: 10) }
                                Button { diagnostics = true } label: {
                                    VStack(spacing: 9) {
                                        HStack(spacing: 8) {
                                            Image(systemName: player.isUpgrading ? "arrow.triangle.2.circlepath" : "waveform.path").foregroundStyle(Tea.gold)
                                            Text(qualityTitle).font(.caption.weight(.semibold)).lineLimit(2)
                                            Spacer(); Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Tea.muted)
                                        }
                                        HStack { Text(player.loading ? "正在下載並驗證音訊…" : player.upgradeStatus).font(.caption2).foregroundStyle(Tea.muted).multilineTextAlignment(.leading); Spacer() }
                                    }.padding(16).background(Tea.panel.opacity(0.75), in: RoundedRectangle(cornerRadius: 18))
                                }.buttonStyle(.plain).accessibilityLabel("音質與播放管線診斷，\(qualityTitle)")
                                HStack {
                                    Button("加入歌單", systemImage: "text.badge.plus") { adding = true }
                                    Spacer()
                                    Button("佇列 \(player.upcomingIDs.count)", systemImage: "list.bullet") { queue = true }
                                }.font(.subheadline).foregroundStyle(Tea.muted)
                            }.padding(.horizontal, 28).padding(.bottom, 28)
                        } else { EmptyLibrary(title: "下一段旋律，等你選擇", subtitle: "從音樂庫或遠端來源開始聆聽。", symbol: "music.note") }
                    }
                }
            }.navigationTitle("正在聆聽").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("收起", systemImage: "chevron.down") { dismiss() } } }
                .sheet(isPresented: $queue) { QueueView() }
                .sheet(isPresented: $lyrics) { LyricsView() }
                .sheet(isPresented: $diagnostics) { AudioDiagnosticsView() }
                .sheet(isPresented: $adding) { if let track { PlaylistPicker(trackIDs: [track.id]) } }
                .task(id: track?.id) { if let track, track.lyrics == nil { await lyricsService.load(for: track, store: store) } }
        }
    }
    private var qualityTitle: String {
        guard let quality = player.actualQuality else { return "尚未取得正在播放的音質" }
        let rate = quality.sampleRate.map { String(format: "%.1f kHz", $0 / 1000) } ?? "取樣率未知"
        return "\(quality.source) · \(quality.codec) · \(rate)"
    }
    private func activeLine(_ track: Track) -> String? {
        guard let value = track.lyrics, let index = value.activeIndex(at: player.progress) else { return nil }
        return value.lines[index].text
    }
    private func transport(spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            Button { player.setShuffle(!player.queue.shuffled) } label: { Image(systemName: "shuffle").foregroundStyle(player.queue.shuffled ? Tea.gold : Tea.muted).frame(width: 44, height: 44) }.accessibilityLabel(player.queue.shuffled ? "關閉洗牌" : "完整洗牌").accessibilityAddTraits(player.queue.shuffled ? .isSelected : [])
            Button { player.previous() } label: { Image(systemName: "backward.end.fill").font(.title2).frame(width: 44, height: 44) }.accessibilityLabel("上一首")
            Button { player.togglePlay() } label: {
                ZStack { Circle().fill(Tea.gold); if player.loading { ProgressView().tint(Tea.background) } else { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 28, weight: .semibold)).foregroundStyle(Tea.background) } }.frame(width: 70, height: 70)
            }.disabled(player.loading).accessibilityLabel(player.loading ? "正在準備音訊" : player.isPlaying ? "暫停" : "播放")
            Button { player.next() } label: { Image(systemName: "forward.end.fill").font(.title2).frame(width: 44, height: 44) }.accessibilityLabel("下一首")
            Menu {
                ForEach(RepeatMode.allCases, id: \.self) { value in Button(value.title) { player.setRepeat(value) } }
            } label: { Image(systemName: player.queue.repeatMode == .one ? "repeat.1" : "repeat").foregroundStyle(player.queue.repeatMode == .off ? Tea.muted : Tea.gold).frame(width: 44, height: 44) }.accessibilityLabel(player.queue.repeatMode.title)
        }
    }
}

struct QueueView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var player: PlayerController
    @Environment(\.dismiss) private var dismiss
    @State private var restoring = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 0) {
                        count("來源完整集合", number: player.queue.sourceIDs.count)
                        count("已播紀錄", number: player.queue.history.count)
                        count("接著播放", number: player.upcomingIDs.count)
                    }.padding(.vertical, 8)
                    Label(player.queue.shuffled ? "完整隨機 · 每輪自動曲目不重複" : "依目前順序播放", systemImage: player.queue.shuffled ? "shuffle" : "list.number").font(.caption).foregroundStyle(Tea.gold)
                    Text("手動插隊可重複指定歌曲。完整排列、已播位置與待播會保存在裝置，重新開啟後可繼續。 ").font(.caption).foregroundStyle(Tea.muted)
                }.listRowBackground(Tea.panel)
                if let current = player.currentTrack {
                    Section("正在聆聽") { HStack(spacing: 14) { AlbumArt(track: current, size: 58); VStack(alignment: .leading, spacing: 5) { Text(current.title).font(.headline); Text(current.artist).font(.caption).foregroundStyle(Tea.muted) }; Spacer(); Image(systemName: "waveform").foregroundStyle(Tea.gold) }.padding(.vertical, 4).listRowBackground(Color.clear) }
                }
                Section("待播 · \(player.upcomingIDs.count) 首") {
                    if player.upcomingIDs.isEmpty { Text("待播已走完。可從歌曲選單插隊，或重新載入來源佇列。 ").font(.subheadline).foregroundStyle(Tea.muted) }
                    ForEach(Array(player.upcomingIDs.enumerated()), id: \.offset) { item in
                        if let track = store.trackByID[item.element] {
                            HStack(spacing: 12) {
                                Text("\(item.offset + 1)").font(.caption.monospacedDigit()).foregroundStyle(Tea.muted).frame(minWidth: 22)
                                AlbumArt(track: track, size: 42)
                                VStack(alignment: .leading, spacing: 4) { Text(track.title); Text(track.artist).font(.caption).foregroundStyle(Tea.muted) }
                            }.listRowBackground(Color.clear)
                        }
                    }.onDelete { player.removeUpcoming(at: $0) }.onMove { player.moveUpcoming(from: $0, to: $1) }
                }
                Section {
                    Button("重新載入來源佇列", systemImage: "arrow.counterclockwise") { restoring = true }.disabled(player.queue.sourceIDs.isEmpty)
                    Text("會以來源完整集合重新建立順序，取代目前插隊與編輯結果。 ").font(.caption).foregroundStyle(Tea.muted)
                }.listRowBackground(Color.clear)
            }.scrollContentBackground(.hidden).background(Tea.background).navigationTitle("播放佇列")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }; ToolbarItem(placement: .primaryAction) { EditButton() } }
                .confirmationDialog("重新建立完整來源佇列？", isPresented: $restoring, titleVisibility: .visible) {
                    Button("重新載入並播放") { player.play(ids: player.queue.sourceIDs, startID: player.currentTrack?.id, shuffle: player.queue.shuffled, playlistID: player.queue.playlistID) }
                    Button("取消", role: .cancel) {}
                }
        }
    }
    private func count(_ title: String, number: Int) -> some View {
        VStack(spacing: 6) { Text("\(number)").font(.title2.monospacedDigit().weight(.semibold)).foregroundStyle(Tea.gold); Text(title).font(.caption2).foregroundStyle(Tea.muted) }.frame(maxWidth: .infinity)
    }
}

struct AudioDiagnosticsView: View {
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.dismiss) private var dismiss
    @State private var linking = false
    var body: some View {
        NavigationStack {
            List {
                Section("正在播放的來源") {
                    if let quality = player.actualQuality {
                        LabeledContent("來源", value: quality.source)
                        LabeledContent("容器／Codec", value: "\(quality.container) / \(quality.codec)")
                        LabeledContent("估計位元率", value: quality.bitRate.map { "\(Int($0 / 1000)) kbps" } ?? "未知")
                        LabeledContent("取樣率", value: quality.sampleRate.map { String(format: "%.1f kHz", $0 / 1000) } ?? "未知")
                        LabeledContent("位元深度", value: quality.bitDepth.map { "\($0) bit" } ?? "未知")
                    } else { Text("尚未完成解碼驗證，音質欄位不採用來源宣告代替。 ").foregroundStyle(Tea.muted) }
                }
                Section("播放中升級") {
                    Text(player.upgradeStatus).font(.headline).foregroundStyle(Tea.gold)
                    if player.isUpgrading { ProgressView("比對錄音、準備緩衝或切換中…"); Button("取消升級", role: .cancel) { player.cancelUpgrade() } }
                    else { Button("尋找並驗證更高音質", systemImage: "waveform.badge.magnifyingglass") { player.requestUpgrade() }.disabled(player.currentTrack == nil || player.loading) }
                    Button("連結音樂庫中的另一個版本", systemImage: "link") { linking = true }.disabled(player.currentTrack == nil)
                    Text("只有錄音比對、時間對齊與品質檢查成功才嘗試短交叉淡入淡出。失敗保留原音訊；此管線不保證樣本級無縫。 ").font(.caption).foregroundStyle(Tea.muted)
                }
                Section("系統輸出") {
                    LabeledContent("目前輸出", value: AVAudioSession.sharedInstance().currentRoute.outputs.map(\.portName).joined(separator: "、"))
                    LabeledContent("音訊工作階段取樣率", value: String(format: "%.1f kHz", AVAudioSession.sharedInstance().sampleRate / 1000))
                    Text("系統取樣率不代表檔案格式、外接 DAC 的實際位元深度或位元完美輸出；這些資訊未經驗證。 ").font(.caption).foregroundStyle(Tea.muted)
                }
                Section("本次管線紀錄") {
                    if player.diagnostics.isEmpty { Text("尚無管線紀錄。 ").foregroundStyle(Tea.muted) }
                    ForEach(Array(player.diagnostics.enumerated()), id: \.offset) { item in Text(item.element).font(.caption.monospaced()).textSelection(.enabled) }
                }
            }.scrollContentBackground(.hidden).background(Tea.background).navigationTitle("音訊管線")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
                .sheet(isPresented: $linking) { AlternateVersionPicker() }
        }
    }
}

struct AlternateVersionPicker: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var player: PlayerController
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    var body: some View {
        let tracks = store.tracks.filter { $0.id != player.currentTrack?.id && (query.isEmpty || "\($0.title) \($0.artist)".localizedStandardContains(query)) }
        NavigationStack {
            List {
                Section { Text("選擇您確認屬於同一錄音的另一個檔案。連結不代表立即切換；播放器仍會實際解碼與比對聲音。 ").font(.caption).foregroundStyle(Tea.muted) }
                ForEach(tracks) { track in
                    Button { player.linkAlternate(track); dismiss() } label: { HStack(spacing: 13) { AlbumArt(track: track, size: 46); VStack(alignment: .leading, spacing: 5) { Text(track.title); Text("\(track.artist) · \(clockText(track.duration))").font(.caption).foregroundStyle(Tea.muted) } } }
                }
                if tracks.isEmpty { EmptyLibrary(title: "沒有可連結的版本", subtitle: "先匯入同一錄音的另一個音質版本。", symbol: "link") }
            }.scrollContentBackground(.hidden).background(Tea.background).navigationTitle("連結錄音版本")
                .searchable(text: $query, prompt: "搜尋另一個版本")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}
