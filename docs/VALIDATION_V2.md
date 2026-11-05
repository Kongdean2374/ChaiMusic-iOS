# V2 有界首輪驗證

本文件描述可執行驗證入口。實際執行結果由主代理在交付紀錄另行填寫；檔案存在不代表已測試通過。

## Linux／macOS 純邏輯與 SQLite

`swift test` 編譯 `ChaiMusic/Core`、SQLite 儲存及備份服務，執行 `Tests/ChaiMusicCoreTests`。不編譯 SwiftUI、MediaPlayer 或 iOS App，不產生 IPA。Linux 使用系統 `sqlite3` 開發標頭，由 `Sources/CSQLite` 提供 module map。

測試涵蓋完整佇列／531 與 1,000 首邊界、事件計時、歌詞解析、資料保存／遷移／備份，實際案例以各測試檔為準。未執行案例不可報為通過。

## 原創音訊與來源協定

```bash
python3 scripts/generate_fixtures.py --output build/fixtures --publish-demo fixtures/demo
python3 scripts/test_fixture_protocol.py fixtures/demo
```

生成 12 秒原創同錄音 AAC／FLAC 及錯版對照，並產生公開 HTTPS static plugin manifest/catalog/stream/lyrics/candidates。協定測試只聽 loopback 隨機 port，驗證真實 HTTP 回應、WebDAV PROPFIND、Range 與路徑限制。這不是 iOS App 的來源連線驗收。

## macOS 真實 AVFoundation 解碼與聲學匹配

```bash
bash scripts/run_audio_integration.sh
```

使用實際 AAC、FLAC、PCM 檔案，檢查 AVFoundation 解碼、同錄音聲學關聯及不同錄音拒絕。包含的品質宣告只為測試輸入；主播放實作會另讀實際音訊格式。這項驗證不能證明 iPhone 系統音訊、背景、交叉淡入聽感已通過；Linux 會明確拒絕執行。

## GitHub Actions 裝置 Release

`.github/workflows/ios-unsigned.yml` 只有 `workflow_dispatch`：

1. 檢閱 PR；工作流程須先存在預設分支，才會出現手動執行介面。
2. Actions → **iOS 未簽署實機 IPA** → **Run workflow** → 選含完整 V2 的分支 → **Run workflow**。
3. 標準 `macos-15` runner 產生 Xcode 專案，建立原創 fixture，驗證 fixture 協定，執行 `swift test`，再執行一次 macOS 音訊整合驗證。
4. 執行一次 `xcodebuild -configuration Release -destination 'generic/platform=iOS' -sdk iphoneos CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build`。
5. `package_ipa.py` 驗證主程式及每個內嵌 Mach-O 為 arm64／iOS 平台、Info.plist、資源、必要動態依賴、封裝完整性與執行權限。只在成功後上傳 **ChaiMusic-unsigned** artifact，內含 `ChaiMusic-unsigned.ipa`。
6. **ChaiMusic-first-run-logs** artifact 保存各步驟退出碼、編譯與封裝紀錄；Run summary 列出每階段狀態。Artifact 保留 14 天。

沒有 Apple 簽署資料、沒有 Secrets 需求、沒有自動重新建置、沒有失敗重試、沒有 push/PR 自動觸發。macOS 測試失敗時不繼續產生 IPA，不能以舊包或假的 ZIP 代替。

## 必須留給裝置驗收的範圍

- iPhone 的播放／鎖定畫面／中斷／耳機拔除，以及實際 AAC→FLAC crossfade 聽感。
- 高網路延遲、seek/next/取消升級競態及播放不中斷的退化。
- 531 首重啟後的 UI 與完整佇列快照。
- Dynamic Type、VoiceOver、低耗電與 Reduce Motion、長列表記憶體／捲動效能。

以上需真實取得裝置 IPA 與執行後才能說已驗收；程式碼與邏輯測試不代替裝置證據。
