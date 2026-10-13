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

## 可行性驗證（先做這些，再決定細節）

| # | 要確認的事 | 怎麼驗證 |
|---|---|---|
| 1 | Presence 一邊掃描、一邊當週邊廣播，兩者互不干擾 | Mac 端驗證版 |
| 2 | iPhone App 在前景能找到 Mac 並寫入指令 | iPhone 測試 App，可以用 iPhone Use 自動操作 |
| 3 | 從控制中心或「捷徑」在背景觸發，幾秒內完成 | 同上，鎖定 iPhone 後觸發 |
| 4 | Apple Watch App 在前景能直接連 Mac | 手錶測試 App，需要你操作 |
| 5 | iPhone 在背景保持連線，Mac 鎖定時收得到通知 | 放著一小時，看耗電與是否斷線 |
