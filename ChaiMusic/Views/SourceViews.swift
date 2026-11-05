import SwiftUI
import UniformTypeIdentifiers

func sourceErrorText(_ error: Error) -> String {
    if error is CancellationError { return "操作已取消。" }
    return (error as? SourceFailure)?.errorDescription
        ?? (error as? BackupService.Failure)?.errorDescription
        ?? (error as? LibraryDatabase.Failure)?.errorDescription
        ?? "無法完成操作，請確認連線、檔案內容與儲存空間。"
}

struct SourcesView: View {
    @EnvironmentObject private var sources: SourceManager
    @EnvironmentObject private var store: LibraryStore
    @State private var adding = false
    @State private var files = false
    @State private var importing = false
    @State private var message: String?
    @State private var deleting: UUID?
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("音樂，自有來處。").font(.title2.weight(.medium))
                    Text("連接私人音樂庫與有權使用的音源，索引保留在這部 iPhone。 ").font(.subheadline).foregroundStyle(Tea.muted).lineSpacing(4)
                    Button("新增來源", systemImage: "plus") { adding = true }.buttonStyle(TeaAction(prominent: true))
                }.padding(.vertical, 12)
            }.listRowBackground(Color.clear).listRowSeparator(.hidden)
            Section("遠端來源 · 由上而下優先") {
                if sources.configurations.isEmpty { Text("尚未連接遠端來源。可新增 HTTPS WebDAV，或相容的合法音源外掛。 ").font(.subheadline).foregroundStyle(Tea.muted).padding(.vertical, 8) }
                ForEach(sources.configurations) { source in
                    NavigationLink { SourceDetailView(sourceID: source.id) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: source.kind == .webDAV ? "externaldrive.connected.to.line.below" : "puzzlepiece.extension")
                                .font(.title2).foregroundStyle(source.enabled ? Tea.gold : Tea.muted).frame(width: 40)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(source.name).font(.headline)
                                Text(source.kind.title).font(.caption).foregroundStyle(Tea.muted)
                                if let state = sources.statuses[source.id] {
                                    Text("\(state.phase) · \(state.knownCount) 首\(state.completed ? " · 完整" : " · 尚未完整")").font(.caption2).foregroundStyle(state.completed ? Tea.muted : Tea.gold)
                                } else { Text("尚未同步").font(.caption2).foregroundStyle(Tea.muted) }
                            }
                            Spacer(minLength: 0)
                            if !source.enabled { Text("已停用").font(.caption2).foregroundStyle(Tea.muted) }
                        }.padding(.vertical, 7)
                    }.swipeActions { Button("移除", role: .destructive) { deleting = source.id } }
                }.onMove { sources.move(from: $0, to: $1) }
            }.listRowBackground(Tea.panel)
            Section("本機與檔案供應商") {
                Button { files = true } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "folder").font(.title2).foregroundStyle(Tea.gold)
                        VStack(alignment: .leading, spacing: 6) { Text("從「檔案」匯入").font(.headline); Text("我的 iPhone · iCloud · SMB 伺服器").font(.caption).foregroundStyle(Tea.muted) }
                    }.padding(.vertical, 8)
                }.disabled(importing)
                Text("SMB 透過 iOS「檔案」提供：先在「檔案」的瀏覽頁選擇「連接伺服器」，再回來匯入可讀取音訊。本 App 不冒充原生 SMB 客戶端。 ").font(.caption).foregroundStyle(Tea.muted)
                if importing { ProgressView("正在匯入音樂…") }
            }.listRowBackground(Tea.panel)
            Section("授權與播放方式") {
                Text("WebDAV 與外掛只使用您有權存取的內容。遠端歌曲首次播放會先安全下載並檢查格式，完成後使用快取；不是即時串流。 ").font(.caption).foregroundStyle(Tea.muted)
                Text("Apple Music、Spotify、YouTube Music 的訂閱不提供可任意取用的音訊檔，本版不連接這些服務，也不繞過 DRM。 ").font(.caption).foregroundStyle(Tea.muted)
            }.listRowBackground(Color.clear)
        }.scrollContentBackground(.hidden).background(Tea.background).navigationTitle("音樂來源")
            .toolbar { ToolbarItem(placement: .topBarLeading) { EditButton() } }
            .sheet(isPresented: $adding) { AddSourceView() }
            .fileImporter(isPresented: $files, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls):
                    importing = true
                    Task { let result = await MediaImporter(root: store.root).importAudio(urls: urls); store.add(result.tracks); importing = false; message = "已匯入 \(result.tracks.count) 首。\n" + result.failures.joined(separator: "\n") }
                case .failure: message = "無法存取選取的檔案，請確認檔案供應商連線。"
                }
            }
            .alert("匯入結果", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) { Button("好") { message = nil } } message: { Text(message ?? "") }
            .confirmationDialog("移除這個來源及儲存的連線憑證？", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("移除來源", role: .destructive) { if let deleting { sources.remove(deleting) }; deleting = nil }
                Button("取消", role: .cancel) { deleting = nil }
            }
    }
}

struct AddSourceView: View {
    @EnvironmentObject private var sources: SourceManager
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind = SourceKind.webDAV
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("填入原創測試音源", systemImage: "waveform") {
                        name = "ChaiMusic 原創音訊測試"; kind = .httpPlugin
                        address = "https://raw.githubusercontent.com/Kongdean2374/ChaiMusic-iOS/feat/chaimusic-first-build/fixtures/demo/manifest.json"
                        username = ""; password = ""
                    }
                    Text("提供同一段原創錄音的兩種音質與不相符版本，供真實播放及升級比對。仍需按下驗證並加入。 ").font(.caption).foregroundStyle(Tea.muted)
                }
                Section("連線設定") {
                    TextField("來源名稱", text: $name)
                    Picker("來源類型", selection: $kind) { ForEach(SourceKind.allCases, id: \.self) { Text($0.title).tag($0) } }
                    TextField(kind == .webDAV ? "https://音樂庫網址/" : "https://外掛網址/manifest.json", text: $address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                }
                Section("授權（來源需要時填寫）") {
                    TextField("使用者名稱", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.username)
                    SecureField("密碼", text: $password).textContentType(.password)
                    Text("憑證只保存在這部裝置的 Keychain，不寫入公開儲存庫或備份。請勿把 Token、帳號、密碼放在網址中。 ").font(.caption).foregroundStyle(Tea.muted)
                }
                Section {
                    Text("連線必須使用 HTTPS，且不接受重新導向。請輸入最終服務網址；外掛需符合 ChaiMusic 的 manifest 協定與授權內容要求。 ").font(.caption).foregroundStyle(Tea.muted)
                    if let error { Label(error, systemImage: "exclamationmark.circle").font(.subheadline).foregroundStyle(Tea.gold) }
                    if busy { ProgressView("正在驗證來源…") }
                }
            }.scrollContentBackground(.hidden).background(Tea.background).navigationTitle("新增音樂來源")
                .interactiveDismissDisabled(busy)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(busy) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("驗證並加入") {
                            guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme?.lowercased() == "https" else { error = "請輸入有效的 HTTPS 網址。"; return }
                            busy = true; error = nil
                            Task {
                                do { try await sources.add(name: name, kind: kind, url: url, username: username, password: password); password = ""; dismiss() }
                                catch { self.error = sourceErrorText(error) }
                                busy = false
                            }
                        }.disabled(busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || address.isEmpty)
                    }
                }
        }
    }
}

struct SourceDetailView: View {
    @EnvironmentObject private var sources: SourceManager
    @EnvironmentObject private var store: LibraryStore
    let sourceID: UUID
    @State private var busy = false
    @State private var result: String?
    private var source: SourceConfiguration? { sources.configurations.first { $0.id == sourceID } }
    var body: some View {
        List {
            if let source {
                Section {
                    Label(source.kind.title, systemImage: source.kind == .webDAV ? "externaldrive" : "puzzlepiece.extension").font(.headline)
                    Text(source.baseURL.host ?? "來源網址").font(.caption).foregroundStyle(Tea.muted)
                    Toggle("啟用此來源", isOn: Binding(get: { self.source?.enabled ?? false }, set: { sources.setEnabled(sourceID, enabled: $0) }))
                }
                Section("音樂索引") {
                    NavigationLink { RemoteBrowserView(sourceID: sourceID, url: nil, title: source.name) } label: { Label("瀏覽與搜尋歌曲", systemImage: "magnifyingglass") }
                    Button("完整同步至音樂庫", systemImage: "arrow.triangle.2.circlepath") { run(sync: true) }.disabled(busy || !source.enabled)
                    Button("檢查連線", systemImage: "checkmark.shield") { run(sync: false) }.disabled(busy)
                    if busy { ProgressView("正在處理，既有音樂仍可使用…") }
                    if let status = sources.statuses[sourceID] {
                        LabeledContent("狀態", value: status.phase)
                        LabeledContent("已知曲數", value: "\(status.knownCount) 首")
                        Text(status.completed ? "完整同步已完成，可對已同步的全部歌曲建立完整洗牌。" : "尚未完成完整同步。已知歌曲可播放，但不代表整個遠端曲庫。")
                            .font(.caption).foregroundStyle(status.completed ? Tea.muted : Tea.gold)
                        if let message = status.message { Text(message).font(.caption).foregroundStyle(Tea.muted) }
                    }
                }
                Section { Text("完整同步先建立新的索引，全部成功後才更新；網路失敗時保留既有快照。首次播放會先下載至快取。若變更網址或憑證，請移除來源後重新新增。 ").font(.caption).foregroundStyle(Tea.muted) }
                if let result { Section("本次結果") { Text(result).font(.subheadline) } }
            } else { EmptyLibrary(title: "來源已移除", subtitle: "回到來源頁新增連線。", symbol: "network") }
        }.scrollContentBackground(.hidden).background(Tea.background).navigationTitle(source?.name ?? "音樂來源")
    }
    private func run(sync: Bool) {
        busy = true; result = nil
        Task {
            do {
                if sync { try await sources.sync(sourceID: sourceID, store: store); result = "索引同步完成。" }
                else { try await sources.verify(sourceID); result = "連線與協定驗證成功。" }
            } catch { result = sourceErrorText(error) }
            busy = false
        }
    }
}

struct RemoteBrowserView: View {
    @EnvironmentObject private var sources: SourceManager
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var player: PlayerController
    let sourceID: UUID
    let url: URL?
    let title: String
    @State private var entries: [RemoteEntry] = []
    @State private var selected = Set<String>()
    @State private var query = ""
    @State private var busy = false
    @State private var error: String?
    @State private var message: String?
    @State private var request: Task<Void, Never>?
    var body: some View {
        List {
            Section {
                Text("瀏覽結果不是完整曲庫。可挑選歌曲加入，或返回來源頁執行完整同步。 ").font(.caption).foregroundStyle(Tea.muted)
                if busy { ProgressView("正在載入來源…") }
                if let error { Text(error).font(.subheadline).foregroundStyle(Tea.gold); Button("重試") { load() } }
                if let message { Text(message).font(.caption).foregroundStyle(Tea.gold) }
            }.listRowBackground(Color.clear)
            ForEach(entries) { entry in
                if entry.isDirectory {
                    NavigationLink { RemoteBrowserView(sourceID: sourceID, url: entry.url, title: entry.title) } label: { Label(entry.title, systemImage: "folder").padding(.vertical, 8) }.listRowBackground(Tea.panel)
                } else {
                    HStack(spacing: 12) {
                        Button { if selected.contains(entry.id) { selected.remove(entry.id) } else { selected.insert(entry.id) } } label: { Image(systemName: selected.contains(entry.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(selected.contains(entry.id) ? Tea.gold : Tea.muted).frame(width: 44, height: 44) }.buttonStyle(.plain).accessibilityLabel("選取 \(entry.title)")
                        VStack(alignment: .leading, spacing: 5) { Text(entry.title).font(.body.weight(.medium)); Text(entry.artist).font(.caption).foregroundStyle(Tea.muted) }
                        Spacer()
                        Button { play(entry) } label: { Image(systemName: "play.circle").font(.title2).frame(width: 44, height: 44) }.buttonStyle(.plain).accessibilityLabel("加入並播放 \(entry.title)")
                    }.padding(.vertical, 5).listRowBackground(Color.clear)
                }
            }
            if entries.isEmpty && !busy && error == nil { EmptyLibrary(title: "沒有可顯示的歌曲", subtitle: "試試其他關鍵字或瀏覽其他資料夾。", symbol: "folder").listRowBackground(Color.clear) }
        }.listStyle(.plain).scrollContentBackground(.hidden).background(Tea.background)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜尋這個來源").onSubmit(of: .search) { load() }
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("更新", systemImage: "arrow.clockwise") { load() }.disabled(busy) } }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button(selected.count == entries.filter { !$0.isDirectory }.count ? "取消全選" : "全選") { let ids = Set(entries.filter { !$0.isDirectory }.map(\.id)); selected = selected == ids ? [] : ids }
                    Spacer()
                    Button("加入 \(selected.count) 首") {
                        let values = entries.filter { selected.contains($0.id) && !$0.isDirectory }
                        sources.importEntries(values, sourceID: sourceID, store: store)
                        message = "已加入 \(values.count) 首至音樂庫。"; selected = []
                    }.disabled(selected.isEmpty)
                }.font(.subheadline).padding().background(Tea.panel)
            }
            .task { load() }.onDisappear { request?.cancel() }
    }
    private func load() {
        request?.cancel(); busy = true; error = nil; message = nil; selected = []
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        request = Task {
            do {
                let values = search.isEmpty ? try await sources.browse(sourceID: sourceID, url: url) : try await sources.search(sourceID: sourceID, query: search)
                guard !Task.isCancelled else { return }
                entries = values; busy = false
            } catch { guard !Task.isCancelled else { return }; self.error = sourceErrorText(error); busy = false }
        }
    }
    private func play(_ entry: RemoteEntry) {
        sources.importEntries([entry], sourceID: sourceID, store: store)
        if let track = store.tracks.first(where: { track in track.variants?.contains { $0.sourceID == sourceID && $0.remoteID == entry.id } == true }) {
            player.play(ids: [track.id], startID: track.id)
            message = "已加入音樂庫，正在準備播放。"
        } else { error = "歌曲未能加入音樂庫，請查看來源狀態。" }
    }
}
