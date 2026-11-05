# 首版介面契約與檔案所有權
最低 iOS 17，Swift 5 語言模式，無第三方執行階段依賴。所有文字、必要註解使用臺灣繁體中文。
Core/Models.swift 由主代理建立，其他代理不可修改。

A 擁有 Core/QueueEngine.swift、Services/LibraryStore.swift、Services/PlayerController.swift。
B 擁有 Views/*.swift、ChaiMusicApp.swift。
C 擁有 .github、scripts、Tests、Package.swift、Xcode 專案與 Resources/Info.plist。
主代理擁有 Services/MediaImporter.swift、Core/LRCParser.swift、Services/SourceProvider.swift、README 與其他文件。

LibraryStore: @MainActor final class ObservableObject
@Published var tracks:[Track], playlists:[Playlist], events:[ListeningEvent], errorMessage:String?
var queue:QueueState (可寫)
let root:URL 指向 Application Support/ChaiMusic
func fileURL(for track:Track)->URL // root/Audio/track.fileName
func artworkURL(for track:Track)->URL? // root/Artwork/track.artworkName
func save(); func add(_ tracks:[Track]); func deleteTrack(_ id:UUID)
func toggleFavorite(_ id:UUID); func createPlaylist(name:String)
func addToPlaylist(trackID:UUID,playlistID:UUID); func removeFromPlaylist(trackID:UUID,playlistID:UUID)
func updateLyrics(trackID:UUID,lyrics:Lyrics); func clearHistory(); func exportData() throws -> URL
初始化讀取原子 JSON 快照，錯誤不得靜默覆寫原始資料。

PlayerController: @MainActor final class ObservableObject
init(store:LibraryStore)
@Published var currentTrack:Track?, isPlaying:Bool, progress:Double, duration:Double, errorMessage:String?
@Published var queue:QueueState
func play(ids:[UUID],startID:UUID? = nil,shuffle:Bool = false,playlistID:UUID? = nil)
func togglePlay(); func pause(); func next(); func previous(); func seek(to:Double)
func insertNext(_ id:UUID); func removeUpcoming(at offsets:IndexSet); func moveUpcoming(from:IndexSet,to:Int)
func setRepeat(_ mode:RepeatMode); func setShuffle(_ enabled:Bool); func persist()
var upcomingIDs:[UUID] // pending + order after current base index
隊列、進度和統計保存，不自動開始恢復播放。

QueueEngine 純 Foundation struct，var state:QueueState; init(state:QueueState=QueueState())
mutating func start(ids:[UUID],startID:UUID?=nil,shuffle:Bool=false,playlistID:UUID?=nil)
mutating func advance(automatic:Bool=false)->UUID?
mutating func previous()->UUID?
mutating func insertNext(_ id:UUID)
mutating func reconcile(validIDs:Set<UUID>)
mutating func setShuffle(_ enabled:Bool)
var upcomingIDs:[UUID]
mutating func removeUpcoming(at:IndexSet); mutating func moveUpcoming(from:IndexSet,to:Int)

MediaImporter actor: init(root:URL); func importAudio(urls:[URL]) async -> ImportResult
ImportResult struct { tracks:[Track]; failures:[String] }
匯入檔案複製到 root/Audio，封面到 root/Artwork。支援 security scoped resource。
LRCParser enum: static func parse(_ text:String) -> Lyrics
UI 自行讀取 LRC（security scope），以 parser 解析，store.updateLyrics 保存。

只寫程式碼與測試；任何代理均不得執行測試、編譯或 CI。唯一初次驗證由主代理統一啟動，完成後不修復、不重跑。子代理不可再分派。
