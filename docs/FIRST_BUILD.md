> 此檔記錄 V1 首次交付；本輪結果請見 V2_DELIVERY.md。

# 首次交付紀錄

日期：2026-11-05（UTC）。

| 項目 | 本次狀態 |
| --- | --- |
| 原生 SwiftUI 第一版原始碼 | 已撰寫，未編譯 |
| Xcode 專案與手動 CI | 已建立，未執行 |
| 531 首等測試程式 | 已撰寫，未執行 |
| GitHub 儲存庫 | Kongdean2374/ChaiMusic-iOS（Public） |
| 首次 CI Run | 未啟動，無 Run ID |
| iPhone Release 編譯 | 未執行 |
| IPA／Artifact | 未產生，無下載連結 |
| 實機測試 | 未執行 |
| 自動重跑 | 0 次 |

## 具體受阻原因

`gh auth status` 回報 `Failed to log in to github.com using token (GH_TOKEN)` 及 `The token in GH_TOKEN is invalid.` 未讀取或輸出 Token 值。雲端環境狀態沒有可用秘密綁定或替代身分；現有 GitHub 連接器可提交檔案與建立 PR，但工具清單沒有首次觸發 workflow_dispatch 的操作。本機是 Linux 且沒有 Xcode，因此不能產生 iPhone 可用執行檔。

依使用者指示，不進行反覆授權嘗試、重跑 CI、模擬器替代或假 IPA。第一版以獨立分支及草稿 PR 保存，未合併 main。儲存庫原本為空，main 只有初始化說明。

## 下一輪（先切換 High 或 Medium）

1. 恢復安全的 GitHub Actions 操作授權，或自行從 GitHub 網頁執行。
2. 檢閱第一版 PR，將工作流程納入預設分支後手動啟動首輪。重點檔案：`.github/workflows/ios-unsigned.yml`、`scripts/`、`ChaiMusic.xcodeproj`。
3. 若失敗，以該次完整編譯 log 定位檔案與行號，再修復／重編譯；本次沒有編譯錯誤 log，不能臆測已通過或失敗。
4. 成功時下載 `ChaiMusic-unsigned.ipa`，由使用者既有工具處理後，以合法音檔驗收 531 首佇列恢復、背景音訊、歌詞偏移與統計。
5. 再決定是否處理大型快照效能、翻譯匯入、WebDAV 或更高品質來源。不要把這些工作加入本次 Ultra 任務。

【Ultra 任務停止】第一版初始開發或建置階段已結束。後續需要反覆測試、修正 Bug 或重新產生 IPA，請先將模型切換至 High 或 Medium，再繼續開發。
