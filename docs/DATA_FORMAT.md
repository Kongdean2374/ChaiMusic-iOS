# 資料層、遷移與備份

## SQLite v2

`Application Support/ChaiMusic/library.sqlite` 使用 Apple 系統 SQLite，WAL 與交易式寫入。tracks、playlists、events 分表；每列保存獨立 Codable payload，state 表保存完整佇列。stable UUID 不隨播放來源改變。schema 使用 `PRAGMA user_version=2`；較新版本拒絕覆寫。

啟動只讀本機索引，不等待遠端同步。LibraryStore 保持 UI 記憶體快照與 trackByID/eventIndex 字典。修改在序列背景佇列合併（0.75 秒窗口）；編碼、內容比較與差異 upsert 均不在主執行緒進行。不變列重用已編碼資料，順序沒有改變時不做 SQL 更新。播放器進度更新依顯式 save／flush 保存；最近尚未落盤的窗口可能於強制終止時遺失。

V1 `library.json` 首次開啟時遷移；成功後仍保留原檔，不自動刪除。讀取錯誤、未知版本或 quick_check 失敗停止寫入。開啟本機快照仍為同步初始化；極大歷史的啟動時間與記憶體使用需實機量測，並未宣稱無限資料量。

## 完整 `.chaimusic` 備份

此格式是原生串流封裝，不是 ZIP 或 IPA。包含音樂庫 metadata、所有曲目引用的本機 Audio、替代本機音源與 Artwork。匯出使用固定大小資料塊，不把整個音樂庫音訊放入記憶體。每筆內容有 CRC32，驗證截斷與損毀；CRC32 不是加密或來源身分驗證。

封裝：UTF-8 magic `CHAIMUSIC_BACKUP_V2\n`，big-endian UInt32 項目數；每筆為 UInt32 JSON header 長度、`{path,size}`、指定長度的內容、UInt32 CRC32。第一筆為 library.json。限制：索引 64 MiB、單檔 4 GiB、全部 32 GiB、200,001 筆。只允許 library.json、Audio/安全檔名、Artwork/安全檔名；拒絕路徑穿越、符號連結、重複項目與額外內容。

還原先在隔離暫存目錄驗證全部內容，再以新 UUID 檔名搬入，最後交易式替換資料庫快照。原有音檔不立即刪除，原資料庫保留在 `Recovery/before-restore-….sqlite`，供必要時人工復原。還原失敗不替換目前音樂庫。完整還原會取代目前歌單／紀錄，不是合併匯入。

不包含 Keychain、來源登入密碼、來源帳號設定或網路快取。遠端 variant URL 在備份及舊 JSON 匯出時移除 user/password/query/fragment，仍保留來源 ID 與 stream ID。重裝後需重新設定來源與重新同步；有時效的遠端 URL 不能當永久音訊備份。要離線保留的音樂請先經 Files 匯入合法音檔。

備份含私人歌曲、歌詞與聆聽資訊，請由使用者選擇可信任分享位置。本專案不自動把備份上傳任何服務。

## 首輪測試程式

DatabaseTests 涵蓋 1,000 首與完整 queue 跨連線恢復、V1 遷移、列刪除與順序、25 次合併更新、完整備份還原／去除 URL 機密、損毀與路徑穿越拒絕。測試由主代理統一執行，撰寫不代表已通過。
