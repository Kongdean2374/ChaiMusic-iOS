# V2 首版交付與可查驗證據

日期：2026-11-05 UTC。承接 PR #1／feat/chaimusic-first-build，未合併 main。V2 重新授權完整首版開發與有界初輪驗證；本輪沒有進入交付後的反覆回歸。

## A. 已實作且有實證

| 範圍 | 證據 |
| --- | --- |
| QueueEngine 完整洗牌與恢復 | 15 個佇列測試通過，包含25/50/100/531/1000與一輪不重複、插隊、刪除、跨歌單 |
| 真實聆聽計時純邏輯 | 4 個測試通過：seek/暫停/停頓不灌水、跨午夜與DST |
| LRC／逐字／靜態／翻譯映射 | 14 個歌詞測試通過：錄音ID匹配、多時間戳、偏移、逐行翻譯錯誤 |
| SQLite／遷移／完整備份 | 7 個測試通過：1000首跨連線恢復、V1遷移、差異更新、備份還原、損毀與路徑限制 |
| 真正client模型與外掛fixture schema | 2 個測試通過：公開資料解碼、版本與權利欄位拒絕 |
| HTTP／WebDAV測試伺服器 | manifest、catalog、搜尋、stream、歌詞、候選、PROPFIND、Range、路徑限制通過 |
| 原創測試音檔 | ffmpeg實際產生AAC與FLAC；ffprobe確認12秒、16kHz單聲道，FLAC原始16bit |
| 全App Swift語法 | 27個App Swift檔語法解析通過；不等於Apple SDK型別檢查 |

Swift 6.0.3 Linux / x86_64，`swift test --jobs 2` 一次執行 **42 tests，0 failures**。單元測試執行約0.56秒，編譯時間另計。完整輸出在 [swift-tests.txt](evidence/swift-tests.txt)；協定輸出在 [fixture-protocol.txt](evidence/fixture-protocol.txt)；實際音訊資訊在 [audio-metadata.json](evidence/audio-metadata.json)。

fixture協定首次啟動受沙箱loopback socket限制，取得該操作的執行權限後完成同輪測試；沒有修改業務程式來掩蓋失敗。整合收尾修正兩處跨搜尋批次選取範圍，針對該Swift檔再做語法解析，沒有重跑核心測試或裝置編譯。

編譯警告：BackupService兩處createFile回傳值未使用；不影響上述測試通過。保留給一般修補，未為消除警告追加迴圈。

## B. 已實作但未驗證

- PlayerController與AudioUpgradeCoordinator：真實雙AVPlayer、候選下載、PCM聲學比對、預緩衝、180ms淡入、單一時間軸、取消與失敗保留A。
- SourceManager／SourceProvider：WebDAV、HTTPS外掛、Keychain、真實音軌資訊、來源排序與完整索引同步。測試伺服器通過不等於iOS client已在裝置連線。
- SwiftUI畫面、圖片取色、歌詞30fps高亮、背景播放、鎖屏、耳機與中斷處理。
- macOS `run_audio_integration.sh` 已納入CI，實際AVFoundation decode與聲學拒絕測試本次未執行。

## C. 外部與環境界線

`gh auth status` 再次回報 `The token in GH_TOKEN is invalid.`；未讀取或輸出Token。環境沒有Xcode，現有GitHub連接器沒有首次workflow_dispatch操作。因此 **CI未啟動、無Run ID、無IPA、無Artifact**。缺的是GitHub執行授權／macOS工具鏈，不是Apple簽署憑證。

未配置商業串流服務的授權或原始音訊存取；本版不提供受保護音訊取流，替代是完整實作的使用者自有HTTPS／WebDAV／Files路徑。詳細逐項差距見 [KNOWN_LIMITATIONS.md](KNOWN_LIMITATIONS.md)，沒有把尚未驗收功能列為已通過。

## D. 畫面實作狀態

| 畫面 | 已接通行為 | 視覺驗證 |
| --- | --- | --- |
| 首頁 | 繼續、最近、常聽、最近新增、來源狀態 | 無iPhone截圖 |
| 音樂庫／歌單 | 搜尋篩選、專輯歌手、收藏、批次增刪改名排序、時長與統計 | 無iPhone截圖 |
| 播放器 | 封面取色背景、音質、升級取消／診斷、版本連結、控制與歌詞預覽 | 未實機 |
| 歌詞 | 逐字遮罩、逐行跟隨、點跳、偏移、原文／翻譯匯入、來源狀態 | 未實機 |
| 佇列 | 完整數量、歷史／待播、排序刪除與快照恢復 | 核心邏輯已測，UI未實機 |
| 統計 | 日週月年、排行、歌單篩選、手動／重播／跳過／比例 | 計時純邏輯已測 |
| 來源／設定 | WebDAV／外掛驗證瀏覽同步、Files／SMB、真實偏好開關、備份還原 | 未實機 |

沒有產生虛構App截圖或把視覺稿當作執行結果。

## E. 核心驗收界線

531首洗牌、不重複與重開恢復已以可執行測試驗證；聆聽計時與歌詞時間資料邏輯已測。音源切換、實際音質在AVFoundation中的讀值與時間軸交接仍需macOS／iPhone結果。Linux語法解析及ffprobe不能替代它們。

## F. 可重現建置

PR #1 保存完整原始碼與手動工作流程；README列出從GitHub網頁合併工作流程至預設分支、Actions→Run workflow→Artifacts的逐步操作。成功時artifact名稱為 `ChaiMusic-unsigned`，內含 `ChaiMusic-unsigned.ipa`；診斷為 `ChaiMusic-first-run-logs`。尚無實際artifact連結。

## G. 交付後工作分類

**High／Medium：** 首次macOS／iPhone編譯的具體錯誤、已實作功能的邊界修補、createFile警告、iPhone17 Pro排版／VoiceOver小修、真實背景播放與音源交接回歸、再次產生IPA。

**應回交Ultra的新設計：** 漸進串流啟播、WebDAV增量同步、ETag／快取管理、樣本級DSP、可靠跨來源身份服務、商業音源授權整合、跨裝置同步、備份遠端來源ID自動重綁。

【Astra Ultra 首版工作結束】主要首版設計與程式實作到此交付。後續一般編譯修正、反覆測試與小 Bug，請切換至 High／Medium；若涉及大型新功能、重新設計、架構變更或核心系統重寫，請回到 Ultra。
