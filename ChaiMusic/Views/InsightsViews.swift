import SwiftUI

struct ListeningView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var period = Period.week
    enum Period: String, CaseIterable {
        case day = "日", week = "週", month = "月", year = "年"
        var component: Calendar.Component {
            switch self { case .day: return .day; case .week: return .weekOfYear; case .month: return .month; case .year: return .year }
        }
    }
    private var events: [ListeningEvent] {
        guard let interval = Calendar.current.dateInterval(of: period.component, for: Date()) else { return [] }
        return store.events.filter { interval.contains($0.date) }
    }
    private var total: Double { events.reduce(0) { $0 + $1.seconds } }
    private var ranking: [(id: UUID, seconds: Double)] {
        Dictionary(grouping: events, by: \.trackID)
            .map { (id: $0.key, seconds: $0.value.reduce(0) { $0 + $1.seconds }) }
            .sorted { $0.seconds > $1.seconds }
    }
    var body: some View {
        List {
            Section {
                Picker("統計期間", selection: $period) { ForEach(Period.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                Text(periodLabel).font(.caption).foregroundStyle(Tea.muted)
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(Int(total / 60))").font(.system(.largeTitle, design: .rounded).weight(.semibold)).foregroundStyle(Tea.gold)
                    Text("分鐘 · 本\(period.rawValue)聆聽時間").foregroundStyle(Tea.muted)
                }.padding(.vertical, 10)
                metric("聽過的歌曲", value: "\(Set(events.map(\.trackID)).count) 首")
                metric("播放紀錄", value: "\(events.count) 次")
                metric("抵達曲尾", value: "\(events.filter(\.completed).count) 次")
                metric("略過", value: "\(events.filter(\.skipped).count) 次")
                metric("重播", value: "\(events.filter(\.replay).count) 次")
                metric("手動選曲", value: "\(events.filter(\.manual).count) 次")
                metric("平均播放比例", value: events.isEmpty ? "—" : "\(Int(events.reduce(0) { $0 + $1.completionRatio } / Double(events.count) * 100))%")
            }
            if events.isEmpty { EmptyLibrary(title: "這段時間，尚無足跡", subtitle: "開始播放本機歌曲後，聆聽紀錄會保存在裝置。", symbol: "chart.bar") }
            else {
                Section("本\(period.rawValue)最常聽") {
                    ForEach(Array(ranking.prefix(8)), id: \.id) { item in
                        if let track = store.tracks.first(where: { $0.id == item.id }) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack { Text(track.title); Spacer(); Text("\(Int(item.seconds / 60)) 分鐘").font(.caption).foregroundStyle(Tea.muted) }
                                ProgressView(value: item.seconds, total: max(1, ranking.first?.seconds ?? 1)).tint(Tea.gold)
                                    .accessibilityLabel("\(track.title)，聆聽 \(Int(item.seconds)) 秒")
                            }.padding(.vertical, 4)
                        }
                    }
                }
            }
            Section("歌單聆聽") {
                if store.playlists.isEmpty { Text("建立歌單並從歌單播放後，這裡會顯示各歌單的紀錄。 ").foregroundStyle(Tea.muted) }
                ForEach(store.playlists) { playlist in
                    let records = events.filter { $0.playlistID == playlist.id }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(playlist.name).font(.headline)
                        Text("\(Int(records.reduce(0) { $0 + $1.seconds } / 60)) 分鐘 · \(records.count) 次播放 · \(records.filter(\.completed).count) 次抵達曲尾")
                            .font(.caption).foregroundStyle(Tea.muted)
                    }.padding(.vertical, 4)
                }
            }
            Section { Text("以裝置時區的日、週、月、年計算；聆聽時間來自實際播放紀錄，暫停與拖曳不計入。播放中的紀錄會在播放器儲存時更新。 ").font(.caption).foregroundStyle(Tea.muted) }
        }.scrollContentBackground(.hidden).navigationTitle("聆聽足跡")
    }
    private var periodLabel: String {
        guard let interval = Calendar.current.dateInterval(of: period.component, for: Date()) else { return "" }
        return "\(interval.start.formatted(date: .abbreviated, time: .omitted)) — \(interval.end.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted))"
    }
    private func metric(_ title: String, value: String) -> some View {
        LabeledContent(title) { Text(value).foregroundStyle(Tea.gold) }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var player: PlayerController
    @State private var exported: URL?
    @State private var error: String?
    @State private var clearing = false
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label("CHAI MUSIC", systemImage: "leaf.fill").font(.title2.weight(.semibold)).foregroundStyle(Tea.gold)
                    Text("音樂在身邊，聆聽留給自己。 ").foregroundStyle(Tea.muted)
                }.padding(.vertical, 12)
            }.listRowBackground(Tea.panel)
            Section("音樂來源") {
                NavigationLink { SourcesView() } label: { Label("管理來源與支援狀態", systemImage: "externaldrive") }
                LabeledContent("本機歌曲", value: "\(store.tracks.count) 首")
                Text("右上角「匯入音樂」可從「檔案」選擇音訊。歌曲複製至 App 私人空間，之後可離線播放。 ").font(.caption).foregroundStyle(Tea.muted)
            }
            Section("資料與隱私") {
                Button("匯出資料", systemImage: "square.and.arrow.up") {
                    do { player.persist(); exported = try store.exportData() }
                    catch { self.error = "無法匯出資料，請確認裝置儲存空間。" }
                }
                if let exported { ShareLink(item: exported) { Label("分享匯出的資料檔", systemImage: "doc") } }
                Text("匯出音樂庫中繼資料、歌單、歌詞、佇列與聆聽紀錄；不含音訊與封面原始檔案。 ").font(.caption).foregroundStyle(Tea.muted)
                Button("清除聆聽紀錄", systemImage: "trash", role: .destructive) { clearing = true }
            }
            Section("關於這一版") {
                Text("原生離線音樂播放器").font(.headline)
                Text("無帳號登入。音訊、歌詞與聆聽資料保存在本機。支援匯入的實際格式及播放能力依 iOS 解碼器而定，匯入失敗會列出原因。 ").font(.subheadline).foregroundStyle(Tea.muted)
                Text("音質資訊顯示來源檔案可取得的資料，不作為外接 DAC 輸出或位元完美播放保證。 ").font(.caption).foregroundStyle(Tea.muted)
            }
        }.scrollContentBackground(.hidden).navigationTitle("設定")
        .confirmationDialog("清除所有聆聽紀錄？此操作無法復原。", isPresented: $clearing, titleVisibility: .visible) {
            Button("清除紀錄", role: .destructive) { player.pause(); store.clearHistory() }
            Button("取消", role: .cancel) {}
        } message: { Text("統計將歸零。執行前會暫停播放，歌曲、歌單與收藏會保留。 ") }
        .alert("無法匯出", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
    }
}

struct SourcesView: View {
    var body: some View {
        List {
            Section("目前可用") {
                Label("本機檔案", systemImage: "checkmark.circle.fill").foregroundStyle(Tea.gold)
                Text("使用右上角匯入按鈕，透過 iOS「檔案」選擇音訊。可以選取「我的 iPhone」、iCloud Drive 或已在「檔案」中設定的提供者。匯入完成後使用本機副本播放。 ").foregroundStyle(Tea.muted)
            }
            Section("尚未支援") {
                status("WebDAV", detail: "這一版沒有內建 WebDAV 連線或遠端瀏覽功能。")
                status("SMB / NAS", detail: "這一版沒有內建 SMB 連線。若伺服器已掛載到 iOS「檔案」，可嘗試由系統選取器匯入可讀取的檔案。")
                status("線上串流服務", detail: "不支援串流服務帳號、網址串流或受 DRM 保護的訂閱歌曲。")
                status("播放中升級音質", detail: "尚未實作同一錄音的候選搜尋、時間對齊與無縫切換。首版持續播放匯入的原始音源。")
            }
        }.scrollContentBackground(.hidden).background(Tea.background).navigationTitle("音樂來源")
    }
    private func status(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack { Text(title).font(.headline); Spacer(); Text("尚未支援").font(.caption).foregroundStyle(Tea.muted) }
            Text(detail).font(.subheadline).foregroundStyle(Tea.muted)
        }.padding(.vertical, 6)
    }
}
