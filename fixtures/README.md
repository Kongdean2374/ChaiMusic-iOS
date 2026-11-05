# 原創驗證音源

素材由 Python 數學振盪器合成，包含 12 秒、16 kHz、單聲道的原始錄音，以及 AAC 32 kbps、FLAC 16-bit 和另一段不同旋律。不含第三方歌曲。此低取樣率素材專為驗證「有損來源 → 原始無損版本」與錯版拒絕，不是高解析音質展示。

可直接加入 App 的 HTTPS 音源外掛網址：

`https://raw.githubusercontent.com/Kongdean2374/ChaiMusic-iOS/feat/chaimusic-first-build/fixtures/demo/manifest.json`

GitHub raw 靜態來源可健康檢查、完整 catalog、搜尋、本機索引、取得串流下載 URL、歌詞與同錄音候選。搜尋端點提供完整清單，再由 App 過濾；正式動態外掛可以伺服器搜尋及分頁。實際音質由下載後的 AVFoundation 解碼資訊確認，manifest 的宣告只供候選排序。

從音樂來源加入、同步後，播放「茶間練習」。初始變體為 AAC，啟用自動升級時可嘗試 FLAC；診斷頁會顯示聲學比對與切換結果。因歌曲短、網路延遲與系統排程，升級未必能在播完前完成，可循環單曲或用自己的較長同錄音素材進行裝置驗證。錯版錄音應拒絕替換，不能因標題相似而通過。

## 重現與自架 WebDAV

```bash
python3 scripts/generate_fixtures.py --output build/fixtures --publish-demo fixtures/demo
python3 scripts/test_fixture_protocol.py fixtures/demo
python3 scripts/fixture_server.py --root fixtures/demo --public-base https://你的網域/ --port 8787
```

伺服器預設只監聽 `127.0.0.1:8787`；需自行使用有效 TLS 憑證的 HTTPS 反向代理。App 不接受不安全 HTTP 或忽略憑證。反向代理後根目錄提供 manifest，`/dav/` 提供真實唯讀 WebDAV `PROPFIND` 與檔案下載；不提供修改私人檔案的功能。可透過環境變數 `FIXTURE_USER`、`FIXTURE_PASSWORD` 設定 Basic 認證，切勿將值提交儲存庫。

macOS 可執行 `bash scripts/run_audio_integration.sh` 檢查 AVFoundation 解碼及同錄音／錯錄音聲學匹配。這不等於 iPhone 背景播放或 crossfade 聽感驗收。
