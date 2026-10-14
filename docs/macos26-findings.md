# BLE 驗證結果（macOS 26.7，Apple Silicon，2026-10-13）

驗證工具原始碼在 `Sources/`。原始紀錄檔含密碼長度，已刪除；以下是整理後的結論。

## 確定可用

| 項目 | 結果 | 對正式版的影響 |
|---|---|---|
| 純選單列 App（`LSUIElement = YES`）掃描藍牙 | 可以，每秒約 30 筆廣播 | 不需要舊版切換 Dock 圖示的繞法 |
| 鎖定期間掃描 | 持續，沒有中斷 | 鎖定時可以照常偵測手機靠近 |
| 主動連線後讀 RSSI | 約 1 秒連上，`readRSSI` 正常 | 主動模式可以保留 |
| `SACLockScreenImmediate`（私有） | 成功，約 0.2 秒後收到鎖定通知 | 保留，集中在一個檔案 |
| `CGSSessionScreenIsLocked` | 鎖定時才有這個鍵，值為 1 | 判斷是否鎖定的主要依據 |
| 鎖定時的前景 App | `com.apple.loginwindow` | 打字前與打字中的防護條件 |
| `IOPMAssertionDeclareUserActivity` 喚醒螢幕 | 0.1～0.2 秒亮起 | 解鎖前一定要先喚醒 |
| `pmset displaysleepnow` | 立即關螢幕 | 取代舊版的 IODisplayWrangler |
| MediaRemote 送出暫停 | 有效 | 可以暫停播放 |
| ⏯ 媒體鍵（NX_KEYTYPE_PLAY） | 有效，可切換播放與暫停 | 備用 |

## 自動解鎖：唯一成功的做法

喚醒螢幕 → 等 `screensDidWake` → 再等 0.5 秒 → 用全系統鍵盤事件（keycode 49 帶 Unicode 字串，每段 20 字）打密碼 → 按 Enter（**keycode 52**）。打完 0.9 秒後解鎖。

正式版要加上：每段字元送出前、以及按 Enter 前，都確認「仍是鎖定」且「前景是 loginwindow」。

## 不能用 / 不要用

| 項目 | 結果 |
|---|---|
| 讀 `/Library/Bluetooth/*.db` 取得名稱與 MAC | 系統拒絕存取（authorization denied）。名稱改用 CoreBluetooth 提供的 |
| IODisplayWrangler `IORequestIdle` 關螢幕 | 回傳成功但螢幕不會關（#169、#84） |
| MediaRemote 查詢是否正在播放 | 永遠回報沒在播放（macOS 15.4 起的限制） |
| 用安全輸入（`kCGSSessionSecureInputPID`）判斷密碼框是否就緒 | 不可靠：螢幕關著時反而由 loginwindow 持有，喚醒後 0.1 秒內就放掉 |
| 鎖定畫面送 Esc | 會把螢幕直接關掉（舊版在螢幕保護程式狀態下會送 Esc） |
| 鎖定後 8 秒才打字 | 鎖定約 5 秒後系統會自動關螢幕，關著時打字無效 |

## 重現的問題

- **#182 密碼外洩**：不檢查就打字時，假字串和 Enter 送到了解鎖後的前景 App（一次是 Claude，一次是誘餌框）。加上「鎖定＋前景是 loginwindow」檢查後一個字都沒送。

## 執行位置

- **不要從外接硬碟執行。** 2026-10-14 06:48 Mac 進入睡眠時，從外接 SSD 的 build 資料夾執行的 Presence 收到 SIGBUS 結束（`Process exited … SIGBUS(10)`），沒有當機報告，醒來後也不會自己重開。同一時間 USB 儲存裝置正在進入省電；推測是睡眠時讀不到執行檔。日常使用要裝在內建硬碟的 `/Applications`。

## 尚未驗證

- 系統睡眠與醒來：計時器是否暫停、醒來多久收到第一筆手機訊號、睡眠時藍牙狀態是否變化。
- 「只送給 loginwindow」（`CGEventPostToPid`）能不能解鎖：第三輪在它之前就成功了，沒跑到。
- Enter 用 keycode 36 是否也可以。
