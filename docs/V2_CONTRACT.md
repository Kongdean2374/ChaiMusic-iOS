# V2 整合契約（本輪優先）

目標 iOS17 / Swift5。既有 Models 與 Queue API 保持相容，新欄位可選以讀取 V1 JSON。所有使用者文字繁體中文。不得執行無界測試或重建；各代理只初次實作及一次靜態閱讀，測試由主代理統一。不得衍生代理或碰觸其他人擁有檔案。

## 所有權
- 主代理：Core/Models.swift、Core/SourceModels.swift、Services/AppPreferences.swift、README、V2文件、整合與GitHub。
- A playback_v2：Core/QueueEngine.swift、Services/PlayerController.swift、Services/AudioUpgradeCoordinator.swift（包含實際聲學比對），Core/ListeningMath.swift、Tests/*Queue*與*Listening*。
- B ui_v2：Views/Theme.swift、AppShell.swift、LibraryViews.swift、InsightsViews.swift、PlayerViews.swift（移除舊 LyricsView，改由 D 新檔定義）、Views/SourceViews.swift、Services/ArtworkCache.swift、ChaiMusicApp.swift。
- C sources_v2：Services/SourceProvider.swift（取代）、Services/SourceManager.swift、Services/SourceTransport.swift、Services/CredentialStore.swift、Core/PluginManifest.swift、docs/PLUGIN_PROTOCOL.md。
- D lyrics_v2：Core/LRCParser.swift、Services/LyricsService.swift、Views/LyricsView.swift、Tests/*LRC*、Tests/*Lyrics*。
- E data_v2：Services/LibraryStore.swift、Services/LibraryDatabase.swift、Services/BackupService.swift、Services/MediaImporter.swift、Tests/*Database*、docs/DATA_FORMAT.md。
- F validation_v2：Package.swift、.github、scripts、Xcode專案、Resources、Tests/*Integration*、docs/VALIDATION_V2.md、fixtures（原創合成音檔合法測試）。不得執行生成/測試/建置，由主代理一次統一。

## Root 新模型
SourceKind: String Codable CaseIterable {webDAV,httpPlugin}
SourceConfiguration: Identifiable Codable {id UUID default, name String, kind SourceKind, baseURL URL, enabled Bool=true, priority Int=0}
SourceVariant: Identifiable Codable Equatable {id UUID default, sourceID UUID?, remoteID String?, url URL?, localFileName String?, recordingID String?, sourceName String, declaredQuality AudioQuality?=nil, alignmentOffset Double=0}
PreparedAudio: {url URL, quality AudioQuality, duration Double, variantID UUID?, recordingID String?}
RemoteEntry: Identifiable {id String, title String, artist String="未知演出者",album String="未知專輯",url URL,isDirectory Bool=false,duration Double=0,recordingID String?=nil,variants [SourceVariant]=[]}
SourceSyncStatus {phase String, completed Bool, knownCount Int, message String?}
Track 新增 optional variants:[SourceVariant]?=nil、recordingID:String?=nil。fileName 空表示純遠端。
Lyrics 新增 optional staticText:String?=nil、recordingID:String?=nil；translationStatus 可由 service呈現。

## Preferences @MainActor ObservableObject root 實作
@Published autoUpgrade=true, animatedArtwork=true, respectLowPower=true, preferLossless=true, networkPlayback=true
使用 didSet 保存 UserDefaults。各功能應真正讀取相關值。

## SourceManager @MainActor ObservableObject
init(root:URL)
@Published configurations:[SourceConfiguration], statuses:[UUID:SourceSyncStatus], errorMessage:String?
func add(name:String,kind:SourceKind,url:URL,username:String,password:String) async throws
func remove(_ id:UUID); func setEnabled(_ id:UUID,enabled:Bool); func move(from:IndexSet,to:Int)
func verify(_ id:UUID) async throws
func browse(sourceID:UUID,url:URL?=nil) async throws -> [RemoteEntry]
func search(sourceID:UUID,query:String) async throws -> [RemoteEntry]
func sync(sourceID:UUID,store:LibraryStore) async throws //完整 catalog 遞迴/分頁，保留既有snapshot，完成標示，錯誤不覆寫
func importEntries(_ entries:[RemoteEntry],sourceID:UUID,store:LibraryStore) //加入持久遠端 Track，不需下載音訊
func prepare(track:Track,variant:SourceVariant?=nil) async throws -> PreparedAudio
// 本機回檔案，遠端合法認證下載至Cache後真實AVAsset檢查；HTTPS、同源憑證、取消/逾時、下載大小上限。
func candidates(for track:Track) async -> [SourceVariant] //包含同recordingID其他來源結果，可有宣告品質但切換前驗真
func fetchLyrics(for track:Track) async throws -> [Lyrics] //僅有權provider協定，嚴格 recordingID

## LibraryStore 保留 V1 公開 API 並新增
init(); @Published tracks/playlists/events/errorMessage; var queue; let root
var trackByID:[UUID:Track]（快取，非每列建字典）
func renamePlaylist(_ id:UUID,name:String); func deletePlaylist(_ id:UUID)
func movePlaylistTracks(_ id:UUID,from:IndexSet,to:Int)
func addTracks(_ ids:[UUID],to playlistID:UUID); func removeTracks(_ ids:Set<UUID>,from playlistID:UUID)
func upsertRemote(_ tracks:[Track]) //穩定來源 ID，比對不覆蓋收藏/歌詞，完整來源同步保留本機資料
func linkVariant(trackID:UUID,variant:SourceVariant) //UI可手動連結同錄音的第二版
func recordListening(trackID:UUID,playlistID:UUID?,seconds:Double,at:Date,duration:Double,manual:Bool,replay:Bool,eventID:UUID) //可供A使用；也保留 events 可寫兼容
func importBackup(from:URL) async throws; func exportBackup() async throws -> URL
func flush() async //背景序列 SQLite 工作清空供備份
store 使用 SQLite 分表 transactions / WAL / background serial writes，主線程只記憶體快照；遷移V1 JSON、無毀損覆寫。備份含音檔/封面/資料且可還原（檔案夾封裝可自訂使用者文件，說明格式與大小上限，避免任意路徑）。

## PlayerController API 保留 V1 並擴充
init(store:LibraryStore,sources:SourceManager,preferences:AppPreferences)
@Published upgradeStatus:String, isUpgrading:Bool, diagnostics:[String], actualQuality:AudioQuality?, loading:Bool
func requestUpgrade(); func cancelUpgrade()
func linkAlternate(_ track:Track) //把其本機檔/remote variant link到目前track，仍須聲學驗證才切換
業務進度單一、升級不新增事件；雙AVPlayer準備、聲學確認（不能只有歌名）+ duration對齊 + 預緩衝 + 短crossfade，候選錯誤保留A；seek/next/取消與generation避免競態。先用cache完整下載可降低控制難度，但UI要顯示首次下載等待；不宣稱樣本級無縫。

## LyricsService @MainActor ObservableObject
init(sources:SourceManager)
@Published state:String, errorMessage:String?, loading:Bool
func load(for track:Track,store:LibraryStore) async
func importTranslation(text:String,track:Track,store:LibraryStore) throws
func importLyrics(text:String,track:Track,store:LibraryStore) throws
LyricsView 自行 @StateObject 初始化有困難可透過 environmentObject App入口注入 LyricsService。
逐字高亮依player.progress，TimelineView smooth估計最多半秒但不造時間，低動態退化；文字無時間可靜態。Provider錯誤、無結果、翻譯可用/無結果/失敗明確。翻譯支援使用者LRC或逐行文字映射，不呼叫無授權API。

## UI 環境物件
LibraryStore、PlayerController、SourceManager、AppPreferences、LyricsService 由 App 注入。
來源設定、安全密碼欄位、驗證/瀏覽/搜尋/同步、來源狀態、完整歌曲數；WebDAV安全限制有可見錯誤；SMB真實Files匯入入口。
Playlist增刪改名/排序/多選；播放器動態封面取色、音質升級/取消/診斷、另一版本手動連結。

## 初輪驗證
F準備腳本、主代理最後統一執行。CI仍workflow_dispatch裝置IPA。可在Linux Docker Swift官方工具鏈跑Core tests（若可用），不是IPA。生成合法原創合成PCM，再ffmpeg成AAC+FLAC，manifest fixture提供同recordingID與錯版對照，供iOS真實升級檢查。不能把未執行測試說成功。
