# ChaiMusic HTTPS 音源協定 v1

來源是使用者自行設定且有權存取的伺服器。App 不內建商業串流解密、爬蟲、私人 API 或熱門曲庫保證。伺服器的 `authorization` 說明必填，仍須由伺服器營運者取得必要權利。

## 加入與安全

輸入 HTTPS 目錄根網址或 `manifest.json` 的網址。來源根網址不可包含帳密、查詢參數或片段。選填 HTTP Basic 帳號與密碼儲存在本機 Keychain，使用 AfterFirstUnlockThisDeviceOnly，不寫入來源 JSON、日誌或備份。網站伺服器需提供受 iOS 信任的 TLS 憑證；不接受明文 HTTP 或跳過憑證驗證。

資料請求與音訊均不跟隨 HTTP 重新導向，請提供最終 URL。Basic 憑證只送至設定來源的相同 scheme、host、port；串流 URL 可以是另一個 HTTPS CDN，但不會取得來源憑證。Cookie 儲存與 URL credential storage 關閉。簽名串流 URL 僅於執行期間使用，不寫入歌曲索引。

每份 JSON/XML 最大 8 MiB，每個音檔最大 512 MiB，請求逾時 30 秒、整體連線資源上限 180 秒。全量同步最多 20,000 首與 200 個 API 分頁；WebDAV 最多 2,000 個目錄。超過或缺頁會顯示失敗，保留舊索引，不會宣稱部分集合為完整音樂庫。

## Manifest

```json
{
  "schemaVersion": 1,
  "id": "my-authorized-library",
  "name": "我的合法音樂庫",
  "authorization": "本伺服器提供使用者自有或已取得授權的錄音",
  "health": "health.json",
  "catalog": "catalog.json",
  "search": "search.json",
  "stream": "stream/{id}.json",
  "lyrics": "lyrics/{recordingID}.json",
  "candidates": "candidates/{recordingID}.json"
}
```

`lyrics` 與 `candidates` 可省略。端點相對 manifest 所在目錄解析，必須同源。支援 `{id}`、`{recordingID}` 模板，值會安全編碼；沒有模板的參數以 query string 傳遞，因此動態服務也可使用 `stream?id=...`。原始碼提供的原創測試 fixture 使用靜態 JSON，可透過一般 HTTPS 靜態託管存取。

## 健康與曲庫

Health：`{"ok":true}`。

Catalog GET 接收選填 `cursor`；Search GET 接收 `q` 與 `cursor`。靜態 search.json 可回完整 catalog，App 會再依歌名、演出者及專輯做本機搜尋。

```json
{
  "items": [{
    "id": "tea-aac",
    "title": "原創測試錄音",
    "artist": "ChaiMusic 測試",
    "album": "合法合成音訊",
    "duration": 30,
    "recordingID": "chai-original-master-001",
    "variants": [{"id":"tea-flac", "recordingID":"chai-original-master-001", "alignmentOffset":0}]
  }],
  "complete": true,
  "nextCursor": null
}
```

分頁未完成時 `complete:false` 且 `nextCursor` 必須是新的非空字串。最後一頁 `complete:true`、`nextCursor:null`。循環游標、超限或不完整回應均不會取代上次完整索引。`recordingID` 必須識別同一錄音版本與母帶，不應以「歌名＋歌手」產生。曲目與變體 ID 必須穩定；相同 ID 不可改指另一錄音。

變體可帶 `quality`（`AudioQuality` 結構）作排序提示，但 App 不把宣告當成實際播放音質。實際編碼、容器、位元率估計、取樣率與位元深度在下載後由 Apple 音訊 API 讀取；讀不到就顯示未知。

## 音訊

Stream GET `id` 回傳：

```json
{
  "url":"https://example.org/audio/tea.flac",
  "recordingID":"chai-original-master-001",
  "authorization":"此合成錄音由伺服器營運者提供使用",
  "expiresAt":"2030-01-01T00:00:00Z"
}
```

`expiresAt` 可省略，若存在需 ISO8601；逾期拒絕使用。recordingID 必須與候選相符。首版下載完整檔案至 App 的 SourceCache 後才播放，支援離線快取重用；不是低延遲即時串流或 HLS。第一次播放會顯示準備／下載狀態。已準備 A 播放時可下載 B，音源升級控制器另做真實聲學、時長、緩衝與切換檢查；這個協定本身不保證無縫。

快取存在應用程式私人資料夾，以穩定變體 UUID 命名。首版沒有遠端檔案更新的 ETag 驗證或自動快取清理；相同變體 ID 需對應不變內容。來源刪除／停用會停止新網路讀取，不會刪除音樂庫中的私人使用紀錄。

## 升級候選

Candidates GET `recordingID`：

```json
{"recordingID":"chai-original-master-001","variants":[{"id":"tea-flac","recordingID":"chai-original-master-001","alignmentOffset":0}]}
```

來源宣告的身分只是篩選，不能替代播放器聲學驗證。不同 recordingID 不自動互換。無候選時回空陣列，不需造假的「升級成功」。

## 歌詞

Lyrics GET `recordingID`：

```json
{
  "recordingID":"chai-original-master-001",
  "authorization":"這份原創測試文字可供測試",
  "language":"zh-Hant-TW",
  "lrc":"[00:00.00]原創測試文字\n[00:03.00]<00:03.00>逐<00:03.50>字",
  "translationLRC":"[00:00.00]使用者提供的翻譯\n[00:03.00]逐字的翻譯"
}
```

可用 `text` 提供無時間戳靜態歌詞，或省略無結果欄位。只有相同 recordingID 且具有權利說明的回應才交給歌詞服務；翻譯依相同時間戳對應。未設定翻譯服務時仍可由使用者匯入翻譯，沒有暗中呼叫不明 API。

## WebDAV 與 SMB

WebDAV 使用 HTTPS Basic 認證、`PROPFIND Depth:1`，解析 DAV `href/displayname/resourcetype`，逐層列舉同源且在根目錄內的資料夾。瀏覽可先加入單曲；完整同步完成後建立持久索引，之後搜尋不必再下載所有清單。首版更新為完整掃描，不宣稱已做增量 sync-token；失敗保留先前完整索引。WebDAV 沒有可信錄音版本識別時不自動按歌名配對升級，可由使用者手動連結另一版再做聲學驗證。

SMB 使用 iOS「檔案」提供者實際匯入，並非內建 SMB 客戶端。可在「檔案」連線伺服器，再從 ChaiMusic 匯入音檔；是否可選取取決於系統提供者權限。
