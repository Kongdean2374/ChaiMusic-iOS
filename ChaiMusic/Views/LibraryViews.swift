import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var player: PlayerController
    private var frequent: [Track] {
        let seconds = Dictionary(grouping: store.events, by: \.trackID).mapValues { $0.reduce(0) { $0 + $1.seconds } }
        return store.tracks.filter { (seconds[$0.id] ?? 0) > 0 }.sorted { (seconds[$0.id] ?? 0) > (seconds[$1.id] ?? 0) }
    }
    private var recent: [Track] {
        var seen = Set<UUID>()
        return store.events.sorted { $0.date > $1.date }.compactMap { event in
            guard seen.insert(event.trackID).inserted else { return nil }
            return store.tracks.first { $0.id == event.trackID }
        }
    }
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("一盞茶的時間，\n留給喜歡的聲音。")
                        .font(.largeTitle.weight(.medium)).foregroundStyle(Tea.gold)
                    Text("CHAI MUSIC · 私藏的每一首")
                        .font(.caption.weight(.medium)).tracking(2).foregroundStyle(Tea.muted)
                    if player.currentTrack != nil {
                        Button(player.isPlaying ? "暫停聆聽" : "繼續聆聽", systemImage: player.isPlaying ? "pause.fill" : "play.fill") { player.togglePlay() }
                            .buttonStyle(.borderedProminent).tint(Tea.gold).foregroundStyle(Tea.background)
                    }
                }.padding(.vertical, 20)
            }.listRowBackground(Tea.panel)
            if store.tracks.isEmpty { EmptyLibrary().listRowBackground(Color.clear) }
            else {
                Section("你的收藏") {
                    NavigationLink { TrackCollection(title: "收藏歌曲", tracks: store.tracks.filter(\.isFavorite)) } label: { Label("收藏歌曲 · \(store.tracks.filter(\.isFavorite).count)", systemImage: "heart.fill") }
                    NavigationLink { TrackCollection(title: "最近加入", tracks: store.tracks.sorted { $0.importedAt > $1.importedAt }) } label: { Label("最近加入", systemImage: "tray.and.arrow.down") }
                }
                Section("常聽的聲音") {
                    if frequent.isEmpty { Text("聆聽後，常聽歌曲會出現在這裡。 ").foregroundStyle(Tea.muted) }
                    ForEach(Array(frequent.prefix(5))) { TrackRow(track: $0, context: frequent.map(\.id)) }
                }
                Section("最近聆聽") {
                    if recent.isEmpty { Text("從音樂庫選一首，開始留下聆聽足跡。 ").foregroundStyle(Tea.muted) }
                    ForEach(Array(recent.prefix(5))) { TrackRow(track: $0, context: recent.map(\.id)) }
                }
            }
        }.scrollContentBackground(.hidden).navigationTitle("茶音")
    }
}

struct LibraryView: View {
    @EnvironmentObject private var player: PlayerController
    @EnvironmentObject private var store: LibraryStore
    @State private var query = ""
    @State private var grouping = Grouping.songs
    @State private var sort = Ordering.title
    enum Grouping: String, CaseIterable { case songs = "歌曲", artists = "歌手", albums = "專輯" }
    enum Ordering: String, CaseIterable { case title = "名稱", artist = "歌手", newest = "最近加入" }
    private var tracks: [Track] {
        let filtered = store.tracks.filter { query.isEmpty || "\($0.title) \($0.artist) \($0.album)".localizedStandardContains(query) }
        return filtered.sorted {
            switch sort {
            case .title: return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            case .artist: return $0.artist.localizedStandardCompare($1.artist) == .orderedAscending
            case .newest: return $0.importedAt > $1.importedAt
            }
        }
    }
    private var groups: [(key: String, tracks: [Track])] {
        let grouped = Dictionary(grouping: tracks) { grouping == .artists ? $0.artist : "\($0.album) · \($0.artist)" }
        return grouped.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { (key: $0, tracks: grouped[$0] ?? []) }
    }
    var body: some View {
        List {
            Section {
                Picker("瀏覽方式", selection: $grouping) { ForEach(Grouping.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                Picker("排序", selection: $sort) { ForEach(Ordering.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
            }
            if tracks.isEmpty {
                EmptyLibrary(title: query.isEmpty ? "你的私人音樂庫" : "找不到符合的歌曲", subtitle: query.isEmpty ? "從「檔案」匯入自己擁有的音訊，離線隨時聽。" : "試試其他歌名、歌手或專輯關鍵字。")
            } else if grouping == .songs {
                Section("\(tracks.count) 首歌曲 · 全部參與目前播放範圍") {
                    Button("完整隨機播放", systemImage: "shuffle") { player.play(ids: tracks.map(\.id), shuffle: true) }
                    ForEach(tracks) { TrackRow(track: $0, context: tracks.map(\.id)) } }
            } else {
                ForEach(groups, id: \.key) { group in
                    NavigationLink { TrackCollection(title: group.key, tracks: group.tracks) } label: {
                        HStack(spacing: 12) {
                            AlbumArt(track: group.tracks.first)
                            VStack(alignment: .leading) { Text(group.key); Text("\(group.tracks.count) 首歌曲").font(.caption).foregroundStyle(Tea.muted) }
                        }
                    }
                }
            }
        }.scrollContentBackground(.hidden).navigationTitle("音樂庫")
            .searchable(text: $query, prompt: "搜尋歌曲、歌手或專輯")
    }
}

struct PlaylistsView: View {
    @EnvironmentObject private var store: LibraryStore
    @State private var creating = false
    @State private var name = ""
    var body: some View {
        List {
            Button("新增歌單", systemImage: "plus") { creating = true }
            if store.playlists.isEmpty { EmptyLibrary(title: "替心情留一張歌單", subtitle: "建立歌單後，從任一歌曲的更多操作加入音樂。", symbol: "music.note.list") }
            ForEach(store.playlists) { playlist in
                NavigationLink {
                    PlaylistDetail(playlistID: playlist.id)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "music.note.list").font(.title2).foregroundStyle(Tea.gold).frame(width: 44, height: 44).background(Tea.panel, in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 4) { Text(playlist.name); Text("\(playlist.trackIDs.count) 首歌曲").font(.caption).foregroundStyle(Tea.muted) }
                    }
                }
            }
        }.scrollContentBackground(.hidden).navigationTitle("我的歌單")
        .alert("新增歌單", isPresented: $creating) {
            TextField("歌單名稱", text: $name)
            Button("取消", role: .cancel) { name = "" }
            Button("建立") {
                let value = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty { store.createPlaylist(name: value) }
                name = ""
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}

struct PlaylistDetail: View {
    @EnvironmentObject private var store: LibraryStore
    let playlistID: UUID
    var body: some View {
        let playlist = store.playlists.first { $0.id == playlistID }
        let tracks = (playlist?.trackIDs ?? []).compactMap { id in store.tracks.first { $0.id == id } }
        TrackCollection(title: playlist?.name ?? "歌單", tracks: tracks, playlistID: playlistID)
    }
}
