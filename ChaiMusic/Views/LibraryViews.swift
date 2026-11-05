import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var sources: SourceManager
    let openPlayer: () -> Void
    private var frequent: [Track] {
        let counts = Dictionary(grouping: store.events, by: \.trackID).mapValues { $0.reduce(0) { $0 + $1.seconds } }
        return store.tracks.filter { counts[$0.id, default: 0] > 0 }.sorted { counts[$0.id, default: 0] > counts[$1.id, default: 0] }
    }
    private var recent: [Track] {
        var seen = Set<UUID>()
        return store.events.sorted { $0.date > $1.date }.compactMap { event in
            guard seen.insert(event.trackID).inserted else { return nil }
            return store.trackByID[event.trackID]
        }
    }
    var body: some View {
        let loved = store.tracks.filter(\.isFavorite)
        let newest = store.tracks.sorted { $0.importedAt > $1.importedAt }
        let often = frequent
        let latest = recent
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("慢一點，聽見更多。").font(.largeTitle.weight(.medium)).tracking(-1)
                    Text("CHAI MUSIC  /  私藏的聲音").font(.caption2.weight(.semibold)).tracking(2.5).foregroundStyle(Tea.gold)
                    if let current = player.currentTrack {
                        HStack(alignment: .center, spacing: 18) {
                            Button(action: openPlayer) { AlbumArt(track: current, size: 112).shadow(color: .black.opacity(0.3), radius: 20, y: 10) }.buttonStyle(.plain)
                            VStack(alignment: .leading, spacing: 9) {
                                Text("繼續聆聽").font(.caption).foregroundStyle(Tea.muted)
                                Text(current.title).font(.title3.weight(.semibold)).lineLimit(2)
                                Text(current.artist).font(.subheadline).foregroundStyle(Tea.muted).lineLimit(1)
                                Button(player.isPlaying ? "暫停" : "繼續", systemImage: player.isPlaying ? "pause.fill" : "play.fill") { player.togglePlay() }.buttonStyle(TeaAction(prominent: true))
                            }
                            Spacer(minLength: 0)
                        }.padding(.top, 10)
                    } else { Text("一首歌，一盞茶。讓喜歡的音樂留在身邊。 ").font(.subheadline).foregroundStyle(Tea.muted).lineSpacing(5) }
                }.padding(.vertical, 12)
                HStack(spacing: 12) {
                    NavigationLink { TrackCollection(title: "收藏歌曲", tracks: loved) } label: { shortcut("收藏", count: loved.count, icon: "heart.fill") }
                    NavigationLink { PlaylistsView() } label: { shortcut("我的歌單", count: store.playlists.count, icon: "music.note.list") }
                }.buttonStyle(.plain)
                if store.tracks.isEmpty {
                    EmptyLibrary()
                    NavigationLink { SourcesView() } label: { Label("連接音樂來源", systemImage: "network").frame(maxWidth: .infinity) }.buttonStyle(TeaAction(prominent: true))
                } else {
                    if !newest.isEmpty {
                        SectionHeading(title: "新進私藏", caption: "最近加入")
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 16) {
                                ForEach(Array(newest.prefix(12))) { track in
                                    Button { player.play(ids: newest.map(\.id), startID: track.id) } label: {
                                        VStack(alignment: .leading, spacing: 9) {
                                            AlbumArt(track: track, size: 136)
                                            Text(track.title).font(.subheadline.weight(.medium)).lineLimit(2)
                                            Text(track.artist).font(.caption).foregroundStyle(Tea.muted).lineLimit(1)
                                        }.frame(width: 136, alignment: .leading)
                                    }.buttonStyle(.plain)
                                }
                            }
                        }
                    }
                    SectionHeading(title: "常聽的聲音", caption: "依真實聆聽時間")
                    if often.isEmpty { Text("聽過幾首歌後，你的偏愛會出現在這裡。 ").font(.subheadline).foregroundStyle(Tea.muted) }
                    else { ForEach(Array(often.prefix(5))) { TrackRow(track: $0, context: often.map(\.id)) } }
                    if !latest.isEmpty {
                        SectionHeading(title: "最近點播")
                        ForEach(Array(latest.prefix(3))) { TrackRow(track: $0, context: latest.map(\.id)) }
                    }
                }
                SectionHeading(title: "音樂從這裡來", caption: "\(sources.configurations.filter(\.enabled).count) 個遠端來源啟用")
                NavigationLink { SourcesView() } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "externaldrive").font(.title2).foregroundStyle(Tea.gold)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("\(store.tracks.filter { !$0.fileName.isEmpty }.count) 首本機 · \(store.tracks.filter { $0.fileName.isEmpty }.count) 首遠端").font(.subheadline)
                            Text(sourceSummary).font(.caption).foregroundStyle(Tea.muted)
                        }
                        Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(Tea.muted)
                    }.padding(18).background(Tea.panel, in: RoundedRectangle(cornerRadius: 18))
                }.buttonStyle(.plain)
            }.padding(.horizontal, 22).padding(.bottom, 28)
        }.background(Tea.background).navigationTitle("茶音").navigationBarTitleDisplayMode(.inline)
    }
    private var sourceSummary: String {
        let incomplete = sources.statuses.values.filter { !$0.completed }.count
        return incomplete > 0 ? "\(incomplete) 個來源尚未完整同步；可在來源頁查看狀態" : "本機快照已就緒；遠端可手動更新"
    }
    private func shortcut(_ title: String, count: Int, icon: String) -> some View {
        HStack { Image(systemName: icon).foregroundStyle(Tea.gold); VStack(alignment: .leading, spacing: 3) { Text(title).font(.subheadline.weight(.medium)); Text("\(count)").font(.caption).foregroundStyle(Tea.muted) }; Spacer() }
            .padding(16).background(Tea.panel, in: RoundedRectangle(cornerRadius: 18))
    }
}

struct LibraryView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var player: PlayerController
    @State private var query = ""
    @State private var grouping = Grouping.songs
    @State private var order = Ordering.title
    @State private var scope = Scope.all
    @State private var selection = Set<UUID>()
    @State private var selecting = false
    @State private var adding = false
    enum Grouping: String, CaseIterable { case songs = "歌曲", artists = "歌手", albums = "專輯" }
    enum Ordering: String, CaseIterable { case title = "名稱", artist = "歌手", newest = "最近加入" }
    enum Scope: String, CaseIterable { case all = "全部", local = "本機", remote = "遠端", favorites = "收藏" }
    private var tracks: [Track] {
        store.tracks.filter { track in
            let match = query.isEmpty || "\(track.title) \(track.artist) \(track.album)".localizedStandardContains(query)
            let included: Bool
            switch scope { case .all: included = true; case .local: included = !track.fileName.isEmpty; case .remote: included = track.fileName.isEmpty; case .favorites: included = track.isFavorite }
            return match && included
        }.sorted {
            switch order { case .title: return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            case .artist: return $0.artist.localizedStandardCompare($1.artist) == .orderedAscending
            case .newest: return $0.importedAt > $1.importedAt }
        }
    }
    var body: some View {
        let visible = tracks
        let ids = visible.map(\.id)
        let grouped = Dictionary(grouping: visible) { grouping == .artists ? $0.artist : "\($0.album) · \($0.artist)" }
        List(selection: $selection) {
            Section {
                NavigationLink { PlaylistsView() } label: { Label("我的歌單", systemImage: "music.note.list").font(.headline) }
                Picker("瀏覽方式", selection: $grouping) { ForEach(Grouping.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) { ForEach(Scope.allCases, id: \.self) { value in
                        Button { scope = value; selection = [] } label: { Text(value.rawValue).font(.caption.weight(.medium)).padding(.horizontal, 15).padding(.vertical, 9).background(scope == value ? Tea.gold : Tea.panel, in: Capsule()).foregroundStyle(scope == value ? Tea.background : Tea.muted) }.buttonStyle(.plain)
                    } }
                }
                HStack {
                    Text("\(visible.count) 首 · 目前完整快照").font(.caption).foregroundStyle(Tea.muted)
                    Spacer()
                    Menu { Picker("排序", selection: $order) { ForEach(Ordering.allCases, id: \.self) { Text($0.rawValue).tag($0) } } } label: { Label("排序", systemImage: "arrow.up.arrow.down").font(.caption) }
                }
                if !visible.isEmpty && grouping == .songs {
                    Button("完整隨機播放", systemImage: "shuffle") { player.play(ids: ids, shuffle: true) }.buttonStyle(TeaAction(prominent: true))
                }
            }.listRowBackground(Color.clear).listRowSeparator(.hidden)
            if visible.isEmpty { EmptyLibrary(title: "這裡還沒有音樂", subtitle: query.isEmpty ? "試試切換分類、匯入檔案，或從來源加入歌曲。" : "換個歌名、歌手或專輯關鍵字。 ").listRowBackground(Color.clear) }
            else if grouping == .songs {
                ForEach(visible) { track in
                    if selecting { HStack { AlbumArt(track: track, size: 40); Text(track.title) }.tag(track.id).listRowBackground(Color.clear) }
                    else { TrackRow(track: track, context: ids).listRowBackground(Color.clear) }
                }
            } else {
                ForEach(grouped.keys.sorted(), id: \.self) { key in
                    let collection = grouped[key] ?? []
                    NavigationLink { TrackCollection(title: key, tracks: collection) } label: {
                        HStack(spacing: 14) { AlbumArt(track: collection.first, size: 62); VStack(alignment: .leading, spacing: 5) { Text(key).font(.headline); Text("\(collection.count) 首").font(.caption).foregroundStyle(Tea.muted) } }.padding(.vertical, 4)
                    }.listRowBackground(Color.clear)
                }
            }
        }.listStyle(.plain).scrollContentBackground(.hidden).background(Tea.background)
            .environment(\.editMode, .constant(selecting ? .active : .inactive))
            .navigationTitle("音樂庫").searchable(text: $query, prompt: "搜尋歌曲、歌手、專輯")
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button(selecting ? "完成" : "選取") { selecting.toggle(); selection = [] }.disabled(grouping != .songs) } }
            .safeAreaInset(edge: .bottom) {
                if selecting { HStack { Text("已選 \(selection.count) 首").font(.caption); Spacer(); Button("加入歌單") { adding = true }.disabled(selection.isEmpty) }.padding().background(Tea.panel) }
            }
            .sheet(isPresented: $adding) { PlaylistPicker(trackIDs: store.tracks.map(\.id).filter { selection.contains($0) }) }
    }
}

struct PlaylistsView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var creating = false
    @State private var editing: UUID?
    @State private var deleting: UUID?
    @State private var name = ""
    var body: some View {
        List {
            Button("建立一張歌單", systemImage: "plus") { name = ""; creating = true }.buttonStyle(TeaAction())
                .listRowBackground(Color.clear).listRowSeparator(.hidden)
            if store.playlists.isEmpty { EmptyLibrary(title: "替心情留一張歌單", subtitle: "從音樂庫批次選取歌曲，或在曲目選單加入。", symbol: "music.note.list").listRowBackground(Color.clear) }
            ForEach(store.playlists) { playlist in
                let tracks = playlist.trackIDs.compactMap { store.trackByID[$0] }
                NavigationLink { PlaylistDetail(playlistID: playlist.id) } label: {
                    HStack(spacing: 16) {
                        AlbumArt(track: tracks.first, size: 72)
                        VStack(alignment: .leading, spacing: 7) {
                            Text(playlist.name).font(.headline)
                            Text("\(tracks.count) 首 · \(clockText(tracks.reduce(0) { $0 + $1.duration }))").font(.caption).foregroundStyle(Tea.muted)
                        }
                    }.padding(.vertical, 7)
                }.listRowBackground(Color.clear)
                    .swipeActions { Button("刪除", role: .destructive) { deleting = playlist.id }; Button("重新命名") { name = playlist.name; editing = playlist.id }.tint(Tea.raised) }
            }
        }.listStyle(.plain).scrollContentBackground(.hidden).background(Tea.background).navigationTitle("我的歌單")
            .alert("建立歌單", isPresented: $creating) {
                TextField("歌單名稱", text: $name)
                Button("建立") { store.createPlaylist(name: name) }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("取消", role: .cancel) {}
            }
            .alert("重新命名", isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
                TextField("歌單名稱", text: $name)
                Button("儲存") { if let editing { store.renamePlaylist(editing, name: name) }; editing = nil }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("取消", role: .cancel) { editing = nil }
            }
            .confirmationDialog("刪除歌單？音樂檔案仍會保留。", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("刪除歌單", role: .destructive) { if let deleting { store.deletePlaylist(deleting) }; deleting = nil }
                Button("取消", role: .cancel) { deleting = nil }
            }
    }
}

struct PlaylistDetail: View {
    @EnvironmentObject private var store: LibraryStore
    let playlistID: UUID
    @State private var selecting = false
    @State private var selected = Set<UUID>()
    @State private var adding = false
    private var playlist: Playlist? { store.playlists.first { $0.id == playlistID } }
    var body: some View {
        let tracks = (playlist?.trackIDs ?? []).compactMap { store.trackByID[$0] }
        let ids = tracks.map(\.id)
        let records = store.events.filter { $0.playlistID == playlistID }
        List(selection: $selected) {
            Section {
                CollectionHeader(title: playlist?.name ?? "歌單", tracks: tracks, playlistID: playlistID)
                DisclosureGroup("這張歌單的聆聽足跡") {
                    PlaylistInsights(records: records)
                }.padding(.horizontal, 20).padding(.top, 12)
            }.listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 16, trailing: 0)).listRowBackground(Color.clear).listRowSeparator(.hidden)
            if tracks.isEmpty { EmptyLibrary(title: "這張歌單還很安靜", subtitle: "點選「加入歌曲」，從音樂庫批次挑選。", symbol: "music.note.list").listRowBackground(Color.clear) }
            ForEach(tracks) { track in
                if selecting { HStack { AlbumArt(track: track, size: 40); Text(track.title) }.tag(track.id).listRowBackground(Color.clear) }
                else { TrackRow(track: track, context: ids, playlistID: playlistID).listRowBackground(Color.clear) }
            }.onMove { store.movePlaylistTracks(playlistID, from: $0, to: $1) }
        }.listStyle(.plain).scrollContentBackground(.hidden).background(Tea.background)
            .environment(\.editMode, .constant(selecting ? .active : .inactive))
            .navigationTitle(playlist?.name ?? "歌單").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button(selecting ? "完成" : "編輯") { selecting.toggle(); selected = [] } } }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button("加入歌曲", systemImage: "plus") { adding = true }
                    Spacer()
                    if selecting { Button("移除 \(selected.count) 首", role: .destructive) { store.removeTracks(selected, from: playlistID); selected = [] }.disabled(selected.isEmpty) }
                }.font(.subheadline).padding().background(Tea.panel)
            }
            .sheet(isPresented: $adding) { AddTracksView(playlistID: playlistID) }
    }
}

struct AddTracksView: View {
    @EnvironmentObject private var store: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let playlistID: UUID
    @State private var selected = Set<UUID>()
    @State private var query = ""
    var body: some View {
        let tracks = store.tracks.filter { query.isEmpty || "\($0.title) \($0.artist)".localizedStandardContains(query) }
        NavigationStack {
            List(tracks, selection: $selected) { track in HStack { AlbumArt(track: track, size: 40); VStack(alignment: .leading) { Text(track.title); Text(track.artist).font(.caption).foregroundStyle(Tea.muted) } }.tag(track.id) }
                .environment(\.editMode, .constant(.active)).scrollContentBackground(.hidden).background(Tea.background)
                .navigationTitle("選擇歌曲").searchable(text: $query, prompt: "搜尋音樂庫")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("加入 \(selected.count) 首") { store.addTracks(store.tracks.map(\.id).filter { selected.contains($0) }, to: playlistID); dismiss() }.disabled(selected.isEmpty) }
                }
        }
    }
}

struct PlaylistInsights: View {
    @EnvironmentObject private var store: LibraryStore
    let records: [ListeningEvent]
    private var frequent: UUID? { Dictionary(grouping: records, by: \.trackID).max { lhs, rhs in lhs.value.reduce(0) { $0 + $1.seconds } < rhs.value.reduce(0) { $0 + $1.seconds } }?.key }
    private var manual: UUID? { Dictionary(grouping: records.filter(\.manual), by: \.trackID).max { $0.value.count < $1.value.count }?.key }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("實際聆聽", value: clockText(records.reduce(0) { $0 + $1.seconds }))
            LabeledContent("最常聽", value: frequent.flatMap { store.trackByID[$0]?.title } ?? "尚無紀錄")
            LabeledContent("最常手動點播", value: manual.flatMap { store.trackByID[$0]?.title } ?? "尚無紀錄")
        }.font(.caption).foregroundStyle(Tea.muted).padding(.vertical, 8)
    }
}
