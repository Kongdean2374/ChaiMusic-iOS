# ChaiMusic

以臺灣繁體中文呈現的原生 iPhone 本機音樂播放器首版。使用 SwiftUI、AVFoundation 與 MediaPlayer，最低 iOS 17，不依賴第三方音源或執行階段套件。

**交付狀態：第一版程式碼已撰寫，尚未編譯或在 iPhone 實測；本次未產生 IPA。** 雲端環境的 GitHub CLI 授權無效，現有 GitHub 連接器沒有首次觸發工作流程的工具。未嘗試重跑或以模擬器產物代替裝置版。詳細狀態見 [首次交付紀錄](docs/FIRST_BUILD.md)。

## 使用範圍

- 從「檔案」匯入有權使用的 MP3、M4A、AAC、WAV、AIFF、CAF、FLAC 等音檔；實際解碼能力由裝置 AVFoundation 決定。音訊會複製到 App 自己的資料夾，讀取標題、歌手、專輯與內嵌封面。
- 首頁、音樂庫搜尋／排序、歌手／專輯、個人歌單、收藏、完整播放器、佇列、歌詞、聆聽統計與設定。
- 完整 ID 集合洗牌、循環單曲／歌單、手動插隊、佇列編輯。JSON 保存全部佇列、游標、歷史及進度；重新啟動後等待使用者按播放。
- AVPlayer 實際播放、拖曳進度、背景音訊、鎖定畫面控制、中斷與耳機拔除處理。
- 音質來自音訊軌描述；AVFoundation 的 estimatedDataRate 標為估計。未知欄位明確顯示未知；不由副檔名推論無損或高解析度。
- 使用者匯入 LRC／增強 LRC，逐行／逐字高亮、點擊跳時間、歌詞偏移。未提供翻譯時明確顯示沒有翻譯。
- 統計累計實際播放進度差，seek 不灌入聆聽秒數；保留手動點播、跳過、重播與完成比例。沒有預置歌曲、歌詞或假統計。

## GitHub Actions：真正的裝置 Release IPA

工作流程只接受 `workflow_dispatch`，不在每次 push 或 PR 自動建置；使用標準 `macos-15` runner，沒有 larger runner、簽署、憑證或秘密值需求。

**需要的 GitHub Actions Secrets：無。** 執行帳號需要儲存庫與 Actions 的操作權限；這是 GitHub 權限，不是 Apple Developer 授權。

首次交付以 `feat/chaimusic-first-build` 草稿 PR 保存。`workflow_dispatch` 需要工作流程先存在預設分支：請先切換至 High／Medium 處理檢閱與合併，再進行以下步驟。本次不代為合併。

1. 開啟儲存庫的 **Actions**，選擇 **iOS 未簽署實機 IPA**。
2. 選 **Run workflow**，選定包含完整程式碼的分支，手動執行一次。
3. 工作流程先執行純邏輯 Swift 測試，再以 Xcode 編譯 iPhone 裝置版。測試在 macOS 執行，不是模擬器 App，也不作為 IPA 執行檔。
4. `xcodebuild` 使用 `Release`、`-sdk iphoneos`、`-destination 'generic/platform=iOS'`，並設定 `CODE_SIGNING_ALLOWED=NO`、`CODE_SIGNING_REQUIRED=NO`。
5. 成功的 App Bundle 複製成 `Payload/ChaiMusic.app`，封裝 `ChaiMusic-unsigned.ipa`。驗證 Info.plist、arm64、Mach-O iOS 平台與非系統 Framework 後才上傳。
6. 在該次 Run 底部 **Artifacts** 下載 IPA artifact；解壓 artifact ZIP 後可取得 `ChaiMusic-unsigned.ipa`。未簽署 IPA 留給您自己的工具處理。

若失敗，只下載該次診斷 artifact、記錄錯誤並停止。本工作流程不自動重試。Artifacts 有期限，請及時下載。系統內建 Framework 由 iOS 提供，不會複製整套系統 Framework 進 App；若未來加入第三方動態 Framework，必須嵌入 Bundle 並通過依賴驗證。

## 專案結構

- `ChaiMusic.xcodeproj`：完整 Xcode 專案與共享 Scheme。
- `ChaiMusic/Core`：資料模型、完整佇列引擎、LRC 解析；同時供 Swift Package 邏輯測試使用。
- `ChaiMusic/Services`：原子資料保存、音訊匯入、AVPlayer、來源擴充協定。
- `ChaiMusic/Views`：SwiftUI 操作介面。
- `scripts`：可重現專案產生、IPA 封裝與裝置產物檢查。
- `Tests`：531 首洗牌、邊界、保存、歌詞等首輪驗證程式（本次未執行）。

新增 Swift 檔案後，以 `python3 scripts/generate_project.py` 更新專案。工作流程會產生專案再建置。Xcode 設定與工具版本以工作流程及 Run log 為準；runner 映像更新仍可能影響結果。

## 資料與隱私

私人音檔、封面、歌詞、歌單與聆聽紀錄只存在 App 的 Application Support 目錄；程式不提供第三方追蹤或自動上傳。設定的資料匯出是 JSON 中繼資料／歌詞／聆聽紀錄，不包含音訊檔，不是完整音樂備份，也沒有首版匯回功能。匯出檔可能包含私人曲目與使用紀錄，請自行選擇分享對象。

公開儲存庫只保存程式碼與原創圖示，不包含使用者歌曲、BitChord 素材、Apple 憑證、API Token 或帳號密碼。工作流程採最小讀取權限且不保留 checkout 憑證。未使用 Apple Music、Spotify、YouTube Music 非官方音源或 DRM 繞過。

詳見 [架構](docs/ARCHITECTURE.md)、[已知限制](docs/KNOWN_LIMITATIONS.md)、[首次交付與下一輪工作](docs/FIRST_BUILD.md)。
