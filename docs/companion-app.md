# iPhone 與 Apple Watch 配套 App：設計草稿

狀態：草稿，等可行性驗證（見最後一節）。

## 目標

**第一版**

- 從 iPhone、Apple Watch、控制中心、動作按鈕、Siri 或「捷徑」：立即鎖定 Mac、暫停（15 分鐘到 4 小時）、恢復、查看狀態。
- Mac 自動鎖定、或在裝置不在時被手動解鎖，iPhone 收到通知。

**第二版**

- **Face ID 核准解鎖**：Mac 螢幕被喚醒時，iPhone 鎖定畫面跳出通知，用 Face ID 核准後 Mac 才解鎖。不再單憑訊號強弱判斷。
- **加密的在場證明**：Mac 出挑戰，iPhone 或 Apple Watch 用配對時交換的金鑰回答。訊號可以偽造，金鑰不行；也可以要求「手錶戴著且已解鎖」才回答。

**之後再說**

- 不在藍牙範圍內也能遠端鎖定（走 iCloud／CloudKit）。

## 連線方式：藍牙，Mac 當週邊

| 方案 | 優點 | 缺點 |
|---|---|---|
| **藍牙，Mac 當週邊（選這個）** | 不用網路、不用帳號；Apple Watch 也能直接連 | 只在藍牙範圍內 |
| 藍牙，iPhone 當週邊 | iPhone 背景廣播較省電 | **Apple Watch 不能當週邊**，手錶只能透過 iPhone 轉送 |
| 區網（Bonjour） | 範圍是整個網路 | watchOS 不能用低階網路與 Bonjour；要同一個 Wi-Fi |
| iCloud（CloudKit） | 人在外面也能用 | 延遲數秒；Mac 要開 iCloud 權限並使用配置描述檔；要有網路 |

Presence 本來就用藍牙偵測裝置，所以 Mac 端再加一個 `CBPeripheralManager` 廣播 Presence 的服務；iPhone 和手錶當中央端連過來，寫入指令、訂閱狀態。

## 配對與安全

1. 在 Mac 的 Presence 按「配對 iPhone」，畫面顯示 QR code，內容是服務識別碼、Mac 名稱和一把隨機產生的 256 位元金鑰。
2. iPhone App 掃描後把金鑰存進鑰匙圈，再用 WatchConnectivity 傳給手錶。
3. 每個指令都用 AES-GCM（CryptoKit）加密並驗證，內含時間戳記與一次性亂數；Mac 拒絕超過 30 秒或重複使用過的指令。
4. Mac 回傳的狀態也加密，旁人掃描藍牙看不到你在不在座位上。
5. 可以在 Mac 上撤銷任何一台已配對的裝置。

**沒有解決的問題**：中繼攻擊。攻擊者可以把你手機和 Mac 之間的藍牙訊號轉送到遠處。Apple 內建的手錶解鎖用測距防這種攻擊，第三方 App 拿不到同樣的能力。所以 Face ID 核准仍然需要你本人操作，而不是全自動。

## 專案結構

都放在 Presence 這個 repo：

- `Packages/PresenceLink`：三個平台共用的指令格式、加密、藍牙 UUID、配對內容。
- `Presence`（macOS）：新增配對畫面與藍牙週邊服務。
- `PresenceRemote`（iOS）：App 本體、控制中心按鈕、小工具、App Intents。
- `PresenceRemote Watch`（watchOS）：App 與錶面複雜功能。

## 可行性驗證結果（2026-10-14，iPhone 18 Pro、iOS 27.0.1、macOS 26.7）

測試程式：Mac 端是 Presence 的 `LinkPeripheral`（啟動參數 `-PresenceLinkSpike YES`），iPhone 端是 `Remote/` 的測試 App；用 iPhone Use 自動操作。

| # | 項目 | 結果 |
|---|---|---|
| 1 | Presence 一邊掃描、一邊當週邊廣播 | ✅ 同時運作，不需要額外的藍牙權限 |
| 2 | iPhone App 在前景找到 Mac 並送指令 | ✅ 從找到到可收送約 1.6 秒；連著時一來一回 64 毫秒 |
| 3a | App 在背景，從 Spotlight 執行「Ping Mac」捷徑 | ✅ 50 毫秒，不會打開 App |
| 3b | App 已被結束，從捷徑冷啟動 | ✅ 44 毫秒（系統保留了連線並交還給 App） |
| 3c | Mac 端重開，連線真的斷掉 | ✅ Mac 重新廣播後約 1.5 秒，iPhone 自動重連並在背景叫醒 App；之後捷徑 34 毫秒 |
| 5 | App 在背景或已被結束時收 Mac 的通知 | ✅ 照樣收到；系統會為了通知在背景啟動 App |
| 4 | Apple Watch（Ultra 2、watchOS 27.2）直接連 Mac | ⚠️ 可以，但 **iPhone 連著時手錶連不上**（連續 3 次、每次 15 秒都停在連線中）；iPhone 斷開後手錶 0.9 秒連上，ping 207 毫秒 |

**踩到的坑**：系統冷啟動 App 時會交還仍然連著的 Mac（state restoration），這時要重新取得服務與特徵，不能因為「已經連著」就跳過，否則會一直等不到就緒。

**Mac 當週邊同時只接受一台裝置連線。** 所以正式版：

- iPhone 保持連線，負責收通知，也代手錶轉送指令。手錶透過 WatchConnectivity 經由 iPhone 送指令。
- iPhone 不在身邊、或沒連著時，手錶才直接連 Mac，用完就斷，把連線讓回給 iPhone。
- 手錶 App 在背景不能掃描藍牙，直接連線只在 App 開著時有效。

**結論**：藍牙、Mac 當週邊的架構可行，而且背景行為比預期好。正式版只要在斷線時登記待命連線，Mac 一回到範圍內，系統就會自動連上，不需要 App 一直在跑。

**還要注意**：

- 驗證版每 30 秒送一次心跳，會頻繁叫醒手機上的 App；正式版只在狀態改變時通知。
- 電量影響還沒量。
- 「用戶手動從 App 切換器滑掉 App」時，系統不會再為藍牙事件叫醒它（這是 iOS 的規則），通知會收不到，直到下次打開 App。
