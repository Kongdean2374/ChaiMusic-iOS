import SwiftUI
import UniformTypeIdentifiers

struct LyricsView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var service: LyricsService
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .title) private var lyricSize = 30.0
    @State private var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    @State private var following = true
    @State private var showTranslation = true
    @State private var showDetails = false
    @State private var importing = false
    @State private var importTranslation = false
    @State private var importTrackID: UUID?
    @State private var message: String?
    @State private var reading = false

    private var track: Track? { store.tracks.first { $0.id == player.currentTrack?.id } ?? player.currentTrack }
    private var lyrics: Lyrics? { track?.lyrics }
    private var activeIndex: Int? { lyrics?.activeIndex(at: player.progress) }
    private var restrained: Bool { reduceMotion || (preferences.respectLowPower && lowPower) }
    private var hasTranslation: Bool {
        lyrics?.staticTranslation != nil || lyrics?.lines.contains(where: { $0.translation != nil }) == true
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [Tea.panel, Tea.background, Color.black], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .ignoresSafeArea()
                VStack(spacing: 0) {
                    header
                    if let lyrics, !lyrics.lines.isEmpty {
                        synchronizedLyrics(lyrics)
                    } else if let value = lyrics?.staticText, !value.isEmpty {
                        staticLyrics(value)
                    } else {
                        emptyState
                    }
                    footer
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("收起", systemImage: "chevron.down") { dismiss() }
                        .accessibilityLabel("收起歌詞")
                }
                ToolbarItem(placement: .principal) { Text("字裡，行間").font(.headline).foregroundStyle(Tea.gold) }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("尋找來源歌詞", systemImage: "magnifyingglass") { search() }
                        Button("匯入原文歌詞", systemImage: "doc.badge.plus") { beginImport(translation: false) }
                        Button("匯入繁體中文翻譯", systemImage: "character.bubble") { beginImport(translation: true) }.disabled(lyrics == nil)
                        Toggle("顯示翻譯", isOn: $showTranslation)
                        Button("來源與時間校正", systemImage: "slider.horizontal.3") { showDetails.toggle() }
                    } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                    .disabled(track == nil)
                    .accessibilityLabel("歌詞與翻譯操作")
                }
            }
            .sheet(isPresented: $showDetails) { details }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .data]) { result in
                readImport(result)
            }
            .overlay {
                if reading { ProgressView("正在讀取歌詞…").padding(24).background(Tea.panel, in: RoundedRectangle(cornerRadius: 18)) }
            }
            .alert("歌詞提示", isPresented: Binding(get: { message != nil || service.errorMessage != nil }, set: { if !$0 { message = nil; service.errorMessage = nil } })) {
                Button("好", role: .cancel) { message = nil; service.errorMessage = nil }
            } message: { Text(message ?? service.errorMessage ?? "") }
            .onReceive(NotificationCenter.default.publisher(for: .NSProcessInfoPowerStateDidChange)) { _ in
                lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
            }
            .onChange(of: track?.id) { _, _ in following = true }
            .task(id: track?.id) {
                service.cancel()
                if let track, track.lyrics == nil, track.recordingID != nil, preferences.networkPlayback {
                    await service.load(for: track, store: store)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(track?.title ?? "尚未選擇歌曲").font(.title3.weight(.semibold)).lineLimit(2)
            HStack(alignment: .firstTextBaseline) {
                Text(track?.artist ?? "從音樂庫開始聆聽").font(.subheadline).foregroundStyle(Tea.muted).lineLimit(1)
                Spacer(minLength: 8)
                if let lyrics {
                    Label(lyrics.lines.isEmpty ? "靜態" : (lyrics.lines.contains(where: { !$0.words.isEmpty }) ? "逐字同步" : "逐行同步"), systemImage: "waveform")
                        .font(.caption.weight(.medium)).foregroundStyle(Tea.gold)
                }
            }
            if showTranslation && lyrics != nil && !hasTranslation {
                Button { beginImport(translation: true) } label: {
                    Label("尚無翻譯 · 加入您提供的翻譯", systemImage: "character.bubble")
                        .font(.caption).foregroundStyle(Tea.muted)
                }.buttonStyle(.plain).padding(.top, 4)
            }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 26).padding(.top, 10).padding(.bottom, 18)
    }

    private func synchronizedLyrics(_ lyrics: Lyrics) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 32) {
                    Color.clear.frame(height: 20)
                    ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { item in
                        let selected = activeIndex == item.offset
                        Button {
                            player.seek(to: max(0, item.element.time + lyrics.offset))
                            following = true
                        } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                if item.element.text.isEmpty {
                                    Image(systemName: "ellipsis").font(.title2).foregroundStyle(Tea.muted).padding(.vertical, 6)
                                } else if selected && !item.element.words.isEmpty && !restrained {
                                    TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !player.isPlaying)) { _ in
                                        wordLine(item.element, nextLine: item.offset + 1 < lyrics.lines.count ? lyrics.lines[item.offset + 1].time : player.duration, offset: lyrics.offset)
                                    }
                                } else {
                                    Text(item.element.text)
                                        .font(.system(size: lyricSize, weight: selected ? .bold : .semibold, design: .rounded))
                                        .foregroundStyle(selected ? Tea.gold : Tea.muted.opacity(0.7))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if showTranslation, let value = item.element.translation {
                                    Text(value).font(.body.weight(.medium)).foregroundStyle(selected ? Color.white.opacity(0.9) : Tea.muted.opacity(0.7))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, selected ? 8 : 0)
                            .contentShape(Rectangle())
                            .animation(restrained ? nil : .easeInOut(duration: 0.28), value: selected)
                        }
                        .buttonStyle(.plain)
                        .id(item.offset)
                        .accessibilityLabel(item.element.text.isEmpty ? "間奏" : item.element.text)
                        .accessibilityValue(selected ? "目前歌詞" : "")
                        .accessibilityHint("點兩下跳至 \(clockText(item.element.time + lyrics.offset))")
                    }
                    Color.clear.frame(height: 180)
                }.padding(.horizontal, 26)
            }
            .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in following = false })
            .onAppear { if let activeIndex { proxy.scrollTo(activeIndex, anchor: .center) } }
            .onChange(of: activeIndex) { _, value in
                guard following, let value else { return }
                scroll(proxy, to: value)
            }
            .onChange(of: following) { _, value in
                if value, let activeIndex { scroll(proxy, to: activeIndex) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !following {
                    Button { following = true } label: { Label("回到目前歌詞", systemImage: "location.fill").font(.caption.weight(.semibold)) }
                        .buttonStyle(.borderedProminent).tint(Tea.gold).foregroundStyle(Tea.background)
                        .padding(20)
                }
            }
        }
    }

    private func wordLine(_ line: LyricLine, nextLine: Double, offset: Double) -> some View {
        let time = player.lyricPlaybackTime - offset
        return LyricFlowLayout(spacing: 0, lineSpacing: 6) {
            ForEach(Array(line.words.enumerated()), id: \.offset) { item in
                let end = item.offset + 1 < line.words.count ? line.words[item.offset + 1].time : max(item.element.time + 0.5, nextLine)
                let fraction = min(1, max(0, (time - item.element.time) / max(0.05, end - item.element.time)))
                KaraokeWord(text: item.element.text, fraction: fraction, size: lyricSize)
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel(line.text)
    }

    private func staticLyrics(_ text: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("這份歌詞沒有時間標記").font(.caption).foregroundStyle(Tea.muted)
                Text(text).font(.system(size: lyricSize * 0.83, weight: .medium, design: .rounded)).lineSpacing(12)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                if showTranslation, let value = lyrics?.staticTranslation {
                    Divider().overlay(Tea.muted.opacity(0.25))
                    Label("您提供的翻譯", systemImage: "character.bubble").font(.caption).foregroundStyle(Tea.gold)
                    Text(value).font(.body).lineSpacing(9).foregroundStyle(Tea.muted).textSelection(.enabled)
                }
            }.padding(26)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "quote.opening").font(.system(size: 56, weight: .ultraLight)).foregroundStyle(Tea.gold.opacity(0.8))
            Text("讓聲音，成為文字。").font(.title2.weight(.medium))
            Text("可尋找已設定來源的授權歌詞，\n或匯入您有權使用的 LRC 與純文字。").font(.subheadline).multilineTextAlignment(.center).foregroundStyle(Tea.muted)
            Button("尋找來源歌詞", systemImage: "magnifyingglass") { search() }
                .buttonStyle(.borderedProminent).tint(Tea.gold).foregroundStyle(Tea.background).disabled(track == nil || service.loading)
            Button("匯入歌詞檔案") { beginImport(translation: false) }.disabled(track == nil)
            Text(service.state).font(.caption).foregroundStyle(Tea.muted).multilineTextAlignment(.center).padding(.horizontal)
            Spacer()
        }.frame(maxWidth: .infinity).padding(24)
    }

    private var footer: some View {
        VStack(spacing: 10) {
            if service.loading {
                HStack { ProgressView(); Text(service.state).font(.caption); Spacer(); Button("取消") { service.cancel() } }.padding(.horizontal, 26)
            }
            HStack(spacing: 16) {
                Button { player.togglePlay() } label: { Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").frame(width: 44, height: 44) }
                    .accessibilityLabel(player.isPlaying ? "暫停" : "播放")
                Text(clockText(player.progress)).font(.caption.monospacedDigit()).foregroundStyle(Tea.muted)
                Spacer()
                Button { showDetails = true } label: {
                    Label(lyrics?.source ?? "歌詞來源與校正", systemImage: "info.circle").font(.caption).lineLimit(1)
                }.foregroundStyle(Tea.muted)
            }.padding(.horizontal, 20)
        }.padding(.vertical, 8).background(Tea.background.opacity(0.9))
    }

    private var details: some View {
        NavigationStack {
            Form {
                Section("歌詞來源") {
                    LabeledContent("來源", value: lyrics?.source ?? "尚未取得")
                    LabeledContent("語言", value: lyrics?.language ?? "未知")
                    Text(lyrics?.confidence ?? "來源搜尋只接受完全相符的錄音識別。無法核對時，請自行匯入對應版本。").font(.caption)
                    Text(service.state).font(.caption).foregroundStyle(Tea.muted)
                    Button("尋找已授權來源") { search() }.disabled(track == nil || service.loading)
                }
                if let lyrics, !lyrics.lines.isEmpty {
                    Section("時間校正") {
                        Stepper(value: Binding(get: { self.lyrics?.offset ?? 0 }, set: { value in
                            guard let track, var updated = track.lyrics else { return }
                            updated.offset = value
                            store.updateLyrics(trackID: track.id, lyrics: updated)
                        }), in: -60...60, step: 0.1) {
                            Text("歌詞延遲 \(lyrics.offset, specifier: "%.1f") 秒").monospacedDigit()
                        }
                        Text("正值較晚顯示，負值較早顯示。只調整歌詞，不改變播放進度。").font(.caption)
                        Button("重設為零") {
                            guard let track, var updated = track.lyrics else { return }
                            updated.offset = 0; store.updateLyrics(trackID: track.id, lyrics: updated)
                        }
                    }
                }
                Section("原文與翻譯") {
                    Toggle("顯示翻譯", isOn: $showTranslation)
                    Text(hasTranslation ? "翻譯可用。內容由來源或您提供。" : "找不到翻譯。可匯入逐行對應的繁體中文文字或翻譯 LRC；此版本不會自動呼叫外部翻譯服務。")
                        .font(.caption)
                    Button("匯入原文") { beginImport(translation: false) }.disabled(track == nil)
                    Button("匯入翻譯") { beginImport(translation: true) }.disabled(lyrics == nil)
                    Text("重新匯入原文會取代該曲目前歌詞與翻譯。請只匯入您有權使用的內容。").font(.caption)
                }
            }.navigationTitle("歌詞與翻譯").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showDetails = false } } }
        }.presentationDetents([.large])
    }

    private func scroll(_ proxy: ScrollViewProxy, to value: Int) {
        if restrained { proxy.scrollTo(value, anchor: .center) }
        else { withAnimation(.easeInOut(duration: 0.42)) { proxy.scrollTo(value, anchor: .center) } }
    }
    private func search() {
        guard preferences.networkPlayback else { message = "目前已關閉網路播放。若要尋找遠端歌詞，請先在設定開啟網路存取。"; return }
        guard let track else { return }
        Task { await service.load(for: track, store: store) }
    }
    private func beginImport(translation: Bool) {
        importTranslation = translation
        importTrackID = track?.id
        showDetails = false
        importing = true
    }
    private func readImport(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { message = "無法開啟所選檔案，請確認檔案仍可存取。"; return }
        let targetID = importTrackID
        let translation = importTranslation
        reading = true
        Task {
            defer { reading = false }
            do {
                let text = try await Task.detached(priority: .userInitiated) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 2_000_000 else { throw LyricsService.ImportError.tooLarge }
                    let data = try Data(contentsOf: url, options: .mappedIfSafe)
                    guard data.count <= 2_000_000 else { throw LyricsService.ImportError.tooLarge }
                    guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .utf16) else { throw LyricsService.ImportError.unreadable }
                    return text
                }.value
                guard let selected = store.tracks.first(where: { $0.id == targetID }) else { message = "原先選取的歌曲已不存在。"; return }
                if translation { try service.importTranslation(text: text, track: selected, store: store) }
                else { try service.importLyrics(text: text, track: selected, store: store) }
            } catch let error as LyricsService.ImportError { message = error.localizedDescription }
            catch let error as TranslationMappingError { message = error.localizedDescription }
            catch { message = "讀取歌詞失敗，請確認檔案完整且有存取權限。" }
        }
    }
}

private struct KaraokeWord: View {
    let text: String
    let fraction: Double
    let size: Double
    var body: some View {
        Text(text).font(.system(size: size, weight: .bold, design: .rounded)).foregroundStyle(Tea.muted.opacity(0.65))
            .overlay(alignment: .leading) {
                Text(text).font(.system(size: size, weight: .bold, design: .rounded)).foregroundStyle(Tea.gold)
                    .mask { GeometryReader { geometry in Rectangle().frame(width: geometry.size.width * fraction).frame(maxWidth: .infinity, alignment: .leading) } }
            }
    }
}

private struct LyricFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(width: proposal.width ?? 320, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = layout(width: bounds.width, subviews: subviews)
        for (index, position) in arrangement.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: ProposedViewSize(width: arrangement.widths[index], height: nil))
        }
    }
    private func layout(width: CGFloat, subviews: Subviews) -> (size: CGSize, positions: [CGPoint], widths: [CGFloat]) {
        let available = max(1, width)
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        var positions: [CGPoint] = [], widths: [CGFloat] = []
        for subview in subviews {
            let natural = subview.sizeThatFits(.unspecified)
            let actualWidth = min(available, natural.width)
            let size = subview.sizeThatFits(ProposedViewSize(width: actualWidth, height: nil))
            if x > 0, x + actualWidth > available { x = 0; y += rowHeight + lineSpacing; rowHeight = 0 }
            positions.append(CGPoint(x: x, y: y)); widths.append(actualWidth)
            x += actualWidth + spacing; rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: available, height: y + rowHeight), positions, widths)
    }
}
