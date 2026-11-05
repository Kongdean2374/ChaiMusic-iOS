# ChaiMusic · 聲音，慢慢回甘

原生 iPhone 音樂播放器，臺灣繁體中文、iOS 17+、SwiftUI / AVFoundation / SQLite。此分支承接 PR #1，依 V2 規格擴充為本機、WebDAV 與 HTTPS 外掛來源整合版本。

**這是首版程式實作，仍待 iPhone 裝置編譯與實機驗收。** 本輪實際驗證結果見 [V2 交付紀錄](docs/V2_DELIVERY.md)。沒有 IPA 時不會以原始碼、模擬器或空殼安裝包替代。

## 真正接通的操作路徑

- **本機與 Files／SMB**：右上角匯入音樂 → 選取 Files 內音檔。SMB 由 iOS「檔案」的「連接伺服器」提供，沒有冒充自建 SMB 客戶端。匯入後讀取中繼資料與封面、複製至 App 私人空間播放。
- **WebDAV**：音樂來源 → 新增 → HTTPS WebDAV 根目錄 → 輸入帳密 → 驗證、瀏覽、搜尋與完整同步。認證存在 Keychain。同步完成前保留既有索引並明確顯示狀態；支援的遠端音檔下載到快取後播放。
- **HTTPS 外掛**：音樂來源 → 新增外掛 manifest → 驗證 → 瀏覽／搜尋／完整同步 → 點歌。實作 manifest／健康檢查／目錄分頁／stream 解析／錄音版本候選／歌詞；[公開協定](docs/PLUGIN_PROTOCOL.md)可供自己的合法音樂伺服器使用。
- **音質升級**：先播放可用版本；背景取得候選，讀取實際編碼、比較錄音識別與解碼聲學探針，通過長度、相關性與對齊門檻後預緩衝，以雙 AVPlayer 短交叉淡入。可取消，也可在播放器連結自己匯入的另一版本。失敗保留原曲；歌詞、佇列和聆聽事件共用同一歌曲時間軸。
- **歌詞與翻譯**：來源提供相符錄音的合法歌詞，或匯入 LRC、增強逐字 LRC、純文字。支援逐字漸進高亮、逐行跟隨、手動瀏覽、點句跳轉、偏移與使用者翻譯 LRC／逐行文字。沒有自動翻譯服務或未授權歌詞擷取。
- **音樂庫與歌單**：搜尋、排序、來源／收藏篩選、歌手／專輯、歌單增刪改名、曲目排序、批次加入／移除與摺疊統計。
- **完整佇列**：保存全輪排序、完整來源 ID、已播歷史、手動插隊、游標、循環與進度。完整隨機不以畫面載入的前幾十首當作全部；重開不自行重新洗牌。
- **資料與統計**：SQLite WAL、背景序列差異寫入與 V1 JSON 遷移；真實播放秒數、跳過、重播、手動點播、完成比例，跨午夜分割。備份／還原包含本機音檔與封面，不包含來源登入憑證。

## 原創雙音質測試來源

來源新增頁的「填入原創測試音源」會填入：

```
https://raw.githubusercontent.com/Kongdean2374/ChaiMusic-iOS/feat/chaimusic-first-build/fixtures/demo/manifest.json
```

此來源包含本專案自行合成、可公開使用的 12 秒測試錄音：AAC 32 kbps、FLAC 16 bit，以及不同錄音對照；它不是商業曲庫，也不是 Hi-Res 展示。音訊與歌詞均為原創測試內容。可用它驗收來源新增、搜尋、下載、真實解碼、候選拒絕與安全升級；iPhone 上的實際聽感仍須實機確認。

公開範例固定引用本分支，請保留分支；若搬移來源，可用 `scripts/generate_fixtures.py --base-url ...` 產生對應部署的 JSON。自架 WebDAV／外掛測試伺服器與操作方式見 [驗證指南](docs/VALIDATION_V2.md)。不需要提供私人音樂或帳密給開發者。

## iPhone Release 未簽署 IPA

工作流程：`.github/workflows/ios-unsigned.yml`，名稱 **iOS 未簽署實機 IPA**。

- 僅 `workflow_dispatch` 手動觸發，標準 `macos-15`，有限 timeout；無自動重試。
- `Release`、`-sdk iphoneos`、`-destination 'generic/platform=iOS'`。
- `CODE_SIGNING_ALLOWED=NO`、`CODE_SIGNING_REQUIRED=NO`；**不需要任何 Apple 憑證或 GitHub Secrets**。
- 完整 App Bundle 封裝為 `Payload/ChaiMusic.app` → `ChaiMusic-unsigned.ipa`。
- 檢查 arm64、Mach-O iOS 平台、Info.plist、資源、動態依賴與封裝完整性，成功才 upload-artifact。iOS 系統 Framework 由裝置提供；非系統依賴須在 Bundle 內。

目前 GitHub CLI 的 Token 無效，連接器沒有首次觸發 Actions 的操作，因此沒有自動啟動裝置建置。原始碼與工作流程以 PR 保留，不自動合併。

**從 GitHub 網頁手動建置：**

1. 檢閱並合併 PR #1，使工作流程先存在預設分支 `main`（GitHub 對 `workflow_dispatch` 的要求）。
2. 儲存庫 → **Actions** → **iOS 未簽署實機 IPA** → **Run workflow**。
3. 選取包含完整版本的分支，按綠色 **Run workflow**。
4. 開啟該次 Run。成功後於 **Artifacts** 下載 **ChaiMusic-unsigned**，解壓取得 `ChaiMusic-unsigned.ipa`。
5. 由您既有的工具處理簽署／安裝。失敗則下載 **ChaiMusic-first-run-logs**，在 High／Medium 任務中依具體錯誤修補。

Artifact 保存 14 天；沒有產生成功 Run 時不存在 IPA 下載連結。此流程不涉及 TestFlight、App Store Connect 或上架。

## 開發與資料

`python3 scripts/generate_project.py` 產生完整 Xcode 專案與共享 Scheme；`swift test` 驗證純核心與 SQLite／備份。Apple 音訊測試需要 macOS AVFoundation，iOS 介面與裝置編譯需要 Xcode。Linux 測試不能證明 iOS App 可編譯或可播放。

主檔案：`Core` 是可測純邏輯；`Services` 包含 SQLite、來源傳輸、Keychain、播放器、升級與歌詞；`Views` 包含實際操作介面。無第三方 App 執行階段套件，不包含 BitChord 程式或素材。

資料預設留在裝置；HTTP 請求只發往使用者配置的來源。備份含私人音樂與紀錄，請自行選擇分享對象；來源密碼不包含在備份中，還原後需重新配置來源。來源清單不會上傳至本公開儲存庫。

參閱 [架構](docs/ARCHITECTURE.md)、[資料格式](docs/DATA_FORMAT.md)、[已知限制](docs/KNOWN_LIMITATIONS.md)、[V2 交付紀錄](docs/V2_DELIVERY.md)。`docs/FIRST_BUILD.md` 僅記錄 V1 歷史狀態。
