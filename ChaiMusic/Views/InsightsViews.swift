import SwiftUI
import Charts
import UniformTypeIdentifiers

struct ListeningView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var period = Period.week
    @State private var playlistID: UUID?
    @State private var rankingMode = Ranking.time
    @ScaledMetric(relativeTo: .largeTitle) private var summarySize: CGFloat = 64
    enum Period: String, CaseIterable { case day = "今日", week = "7 天", month = "30 天", year = "今年" }
    enum Ranking: String, CaseIterable { case time = "常聽", replay = "重播", manual = "點播" }
    private var start: Date {
        let calendar = Calendar.current
        switch period {
        case .day: return calendar.startOfDay(for: Date())
        case .week: return calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: Date())) ?? Date()
        case .month: return calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: Date())) ?? Date()
        case .year: return calendar.dateInterval(of: .year, for: Date())?.start ?? Date()
        }
    }
    private var events: [ListeningEvent] {
        let beginning = start
        return store.events.filter { $0.date >= beginning && $0.date <= Date() && (playlistID == nil || $0.playlistID == playlistID) }
    }
    private var ranked: [(id: UUID, value: Double)] {
        Dictionary(grouping: events, by: \.trackID).map { id, values in
            let score: Double
            switch rankingMode { case .time: score = values.reduce(0) { $0 + $1.seconds }; case .replay: score = Double(values.filter(\.replay).count); case .manual: score = Double(values.filter(\.manual).count) }
            return (id: id, value: score)
        }.filter { $0.value > 0 }.sorted { $0.value > $1.value }
    }
    private var buckets: [(date: Date, seconds: Double)] {
        let component: Calendar.Component = period == .day ? .hour : period == .year ? .month : .day
        let grouped = Dictionary(grouping: events) { Calendar.current.dateInterval(of: component, for: $0.date)?.start ?? $0.date }
        return grouped.keys.sorted().map { date in (date: date, seconds: grouped[date, default: []].reduce(0) { $0 + $1.seconds }) }
    }
    var body: some View {
        let records = events
        let seconds = records.reduce(0) { $0 + $1.seconds }
        let ranking = ranked
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                Picker("聆聽期間", selection: $period) { ForEach(Period.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                Menu {
                    Button("全音樂庫") { playlistID = nil }
                    ForEach(store.playlists) { playlist in Button(playlist.name) { playlistID = playlist.id } }
                } label: { HStack { Label(playlistID.flatMap { id in store.playlists.first { $0.id == id }?.name } ?? "全音樂庫", systemImage: "line.3.horizontal.decrease"); Image(systemName: "chevron.down").font(.caption2) }.font(.subheadline).foregroundStyle(Tea.muted) }
                VStack(alignment: .leading, spacing: 9) {
                    Text("音樂陪你的時間").font(.caption.weight(.medium)).foregroundStyle(Tea.muted)
                    HStack(alignment: .firstTextBaseline, spacing: 8) { Text("\(Int(seconds / 60))").font(.system(size: summarySize, weight: .light, design: .rounded)).minimumScaleFactor(0.6).foregroundStyle(Tea.gold); Text("分鐘").font(.title3).foregroundStyle(Tea.muted) }
                    Text("實際 \(clockText(seconds)) · \(Set(records.map(\.trackID)).count) 首歌曲").font(.caption.monospacedDigit()).foregroundStyle(Tea.muted)
                }
                if records.isEmpty { EmptyLibrary(title: "這段時間，尚無足跡", subtitle: "歌曲真正開始播放後，才會留下聆聽時間。", symbol: "chart.bar.xaxis") }
                else {
                    Chart(buckets, id: \.date) { item in
                        BarMark(x: .value("日期", item.date, unit: period == .day ? .hour : period == .year ? .month : .day), y: .value("分鐘", item.seconds / 60))
                            .foregroundStyle(LinearGradient(colors: [Tea.gold, Tea.gold.opacity(0.25)], startPoint: .top, endPoint: .bottom)).cornerRadius(4)
                    }.frame(height: 145).chartYAxis(.hidden).chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { AxisValueLabel().foregroundStyle(Tea.muted) } }
                        .accessibilityLabel("\(period.rawValue)聆聽時間圖表，合計 \(Int(seconds)) 秒")
                    HStack(spacing: 12) {
                        metric("手動點播", value: "\(records.filter(\.manual).count)")
                        metric("重播", value: "\(records.filter(\.replay).count)")
                        metric("略過", value: "\(records.filter(\.skipped).count)")
                    }
                    VStack(spacing: 12) {
                        LabeledContent("平均實際播放比例", value: "\(Int(records.reduce(0) { $0 + $1.completionRatio } / Double(records.count) * 100))%")
                        LabeledContent("抵達曲尾", value: "\(records.filter(\.completed).count) 次")
                    }.font(.subheadline).foregroundStyle(Tea.muted)
                    HStack { SectionHeading(title: "聽見你的偏愛"); Spacer(); Picker("排行方式", selection: $rankingMode) { ForEach(Ranking.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.menu).tint(Tea.gold) }
                    ForEach(Array(ranking.prefix(10).enumerated()), id: \.element.id) { item in
                        if let track = store.trackByID[item.element.id] {
                            HStack(spacing: 13) {
                                Text(String(format: "%02d", item.offset + 1)).font(.caption.monospacedDigit()).foregroundStyle(Tea.muted).frame(width: 24)
                                AlbumArt(track: track, size: 48)
                                VStack(alignment: .leading, spacing: 5) { Text(track.title).font(.subheadline.weight(.medium)); Text(track.artist).font(.caption).foregroundStyle(Tea.muted) }
                                Spacer()
                                Text(rankingMode == .time ? clockText(item.element.value) : "\(Int(item.element.value)) 次").font(.caption.monospacedDigit()).foregroundStyle(Tea.gold)
                            }
                        }
                    }
                    SectionHeading(title: "最近的足跡")
                    ForEach(Array(records.sorted { $0.date > $1.date }.prefix(12))) { event in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 5) { Text(store.trackByID[event.trackID]?.title ?? "已移除的歌曲").font(.subheadline); Text(event.date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(Tea.muted) }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 5) { Text(clockText(event.seconds)).font(.caption.monospacedDigit()).foregroundStyle(Tea.gold); Text(event.skipped ? "略過" : event.completed ? "抵達曲尾" : "聆聽中／已暫停").font(.caption2).foregroundStyle(Tea.muted) }
                        }
                    }
                }
                Text("依裝置時區統計。暫停、拖曳與音源升級不增加聆聽時間；抵達曲尾與完整聽完不同，請搭配實際播放比例查看。 ").font(.caption).foregroundStyle(Tea.muted).lineSpacing(4)
            }.padding(22)
        }.background(Tea.background).navigationTitle("聆聽足跡")
    }
    private func metric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) { Text(value).font(.title2.monospacedDigit().weight(.medium)); Text(title).font(.caption).foregroundStyle(Tea.muted) }.frame(maxWidth: .infinity, alignment: .leading).padding(15).background(Tea.panel, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var preferences: AppPreferences
    @State private var exported: URL?
    @State private var busy = false
    @State private var importing = false
    @State private var restoring = false
    @State private var restoreURL: URL?
    @State private var message: String?
    @State private var clearing = false
    var body: some View {
        List {
            Section {
                HStack(spacing: 17) {
                    Image(systemName: "leaf.fill").font(.system(size: 30, weight: .light)).foregroundStyle(Tea.gold).frame(width: 60, height: 60).background(Tea.raised, in: RoundedRectangle(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 6) { Text("ChaiMusic").font(.title2.weight(.medium)); Text("私藏音樂，自在聆聽。 ").font(.caption).foregroundStyle(Tea.muted) }
                }.padding(.vertical, 8)
            }.listRowBackground(Color.clear)
            Section("一般") {
                NavigationLink { SourcesView() } label: { Label("來源管理與優先順序", systemImage: "network") }
                Toggle("允許遠端音訊下載與播放", isOn: $preferences.networkPlayback)
                    .onChange(of: preferences.networkPlayback) { _, allowed in if !allowed { player.cancelUpgrade() } }
                Toggle("封面流動背景", isOn: $preferences.animatedArtwork)
                Toggle("低耗電時減少動態", isOn: $preferences.respectLowPower)
                Text("減少動態效果會優先遵循 iOS 無障礙設定。遠端音訊停用後，不會開始新的遠端播放；已在播放的音訊可繼續。 ").font(.caption).foregroundStyle(Tea.muted)
            }.listRowBackground(Tea.panel)
            Section("音訊實驗室") {
                Toggle("自動尋找更高音質", isOn: $preferences.autoUpgrade)
                    .onChange(of: preferences.autoUpgrade) { _, enabled in if !enabled { player.cancelUpgrade() } }
                Toggle("優先驗證無損候選", isOn: $preferences.preferLossless)
                NavigationLink { AudioDiagnosticsView() } label: { Label("播放管線與音質診斷", systemImage: "waveform.path") }
                Text("FLAC／ALAC 是否可播放依系統解碼能力而定。候選經實際讀取、錄音比對、對齊與緩衝後才切換，不因來源宣告而標示成功。 ").font(.caption).foregroundStyle(Tea.muted)
            }.listRowBackground(Tea.panel)
            Section("歌詞與翻譯") {
                if player.currentTrack != nil { NavigationLink { LyricsView() } label: { Label("目前歌曲的歌詞與翻譯", systemImage: "quote.bubble") } }
                Text("支援來源提供的授權歌詞、手動 LRC／逐字／純文字及使用者翻譯。播放頁可開啟歌詞、調整偏移與匯入翻譯；沒有設定外部機器翻譯服務。 ").font(.caption).foregroundStyle(Tea.muted)
            }.listRowBackground(Tea.panel)
            Section("資料與備份") {
                LabeledContent("音樂庫", value: "\(store.tracks.count) 首 · \(store.playlists.count) 張歌單")
                Button("匯出完整備份", systemImage: "square.and.arrow.up") {
                    busy = true; player.persist()
                    Task {
                        do { exported = try await store.exportBackup(); message = "備份已建立，可使用下方分享按鈕儲存至檔案。" }
                        catch { message = sourceErrorText(error) }
                        busy = false
                    }
                }.disabled(busy || store.restoring)
                if let exported { ShareLink(item: exported) { Label("儲存或分享備份", systemImage: "doc.zipper") } }
                Button("從備份還原", systemImage: "square.and.arrow.down") { importing = true }.disabled(busy || store.restoring)
                if busy || store.restoring { ProgressView(store.restoring ? "正在安全還原…" : "正在建立完整備份…") }
                Text("備份包含音樂檔案、封面、歌詞、歌單、佇列與歷史，可能很大。來源密碼不包含在內；備份屬私人資料，請選擇可信任的儲存位置。 ").font(.caption).foregroundStyle(Tea.muted)
                Button("清除聆聽紀錄", systemImage: "trash", role: .destructive) { clearing = true }.disabled(busy || store.restoring)
            }.listRowBackground(Tea.panel)
            Section("隱私與能力") {
                Text("資料預設保留在裝置，不加入追蹤。只有您設定的來源會在查詢、同步或下載時連線。原生鎖定畫面支援基本曲目、封面與控制，不宣稱提供第三方受保護的動態封面。 ").font(.caption).foregroundStyle(Tea.muted)
                Text("1.0 · 原創原生播放器").font(.caption2).foregroundStyle(Tea.muted)
            }.listRowBackground(Color.clear)
        }.scrollContentBackground(.hidden).background(Tea.background).navigationTitle("設定")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
                switch result { case .success(let url): restoreURL = url; restoring = true
                case .failure: message = "無法取得備份檔案，請確認檔案供應商可存取。" }
            }
            .confirmationDialog("還原會取代目前音樂庫、歌單與紀錄。建議先建立備份。", isPresented: $restoring, titleVisibility: .visible) {
                Button("確認取代並還原", role: .destructive) {
                    guard let url = restoreURL else { return }
                    player.pause(); player.cancelUpgrade(); busy = true
                    Task {
                        let scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() }; busy = false; restoreURL = nil }
                        do { try await store.importBackup(from: url); message = "備份已還原。遠端來源如需授權，請重新設定連線。" }
                        catch { message = sourceErrorText(error) }
                    }
                }
                Button("取消", role: .cancel) { restoreURL = nil }
            }
            .confirmationDialog("清除全部聆聽紀錄？此操作無法復原。", isPresented: $clearing, titleVisibility: .visible) {
                Button("清除紀錄", role: .destructive) { player.pause(); store.clearHistory() }
                Button("取消", role: .cancel) {}
            }
            .alert("資料處理", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("好") { message = nil } } message: { Text(message ?? "") }
    }
}
