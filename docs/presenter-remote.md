# 簡報遙控：運作方式，以及其他 App 怎麼配合

Presence Remote（iPhone、Apple Watch）可以當簡報筆。這份文件寫 Presence 怎麼做，也給想配合的 App（例如同一個作者的 [Folium](https://chung223.github.io/folium/)）當規格。

手機與手錶上的簡報遙控是 Presence Remote 的付費功能 **Presence Pro**（2026-10-15 決定）：月訂閱 US$0.99、年訂閱 US$4.99（都可以免費試用 7 天）、一次買斷 US$12.99，都可以家人共享。Mac 這邊（送按鍵、簡報時不自動鎖定）免費。程式在 `Remote/Store/`（購買狀態、付費畫面），判斷規則在 `PresenceLink/ProAccess.swift`；只擋「開始簡報」「翻頁」這些動作，結束簡報永遠可以按，讓 Mac 恢復自動鎖定。手錶從 iPhone 同步「有沒有 Pro」，也自己向 App Store 查；手錶的指令經 iPhone 轉送時，iPhone 再檢查一次。開發時用 `-PresencePro YES|NO` 強制切換，從 Xcode 執行會用 `StoreKit/PresencePro.storekit` 的測試商品。

## Presence 怎麼控制簡報

Mac 上的 Presence 對**最前面的 App** 按鍵，和自動解鎖輸入密碼一樣用輔助使用權限送出。不需要和簡報 App 另外連線，所以 Keynote、PowerPoint、瀏覽器裡的 Google 簡報都不用特別支援。

| 手機或手錶上的按鈕 | Mac 送出的按鍵 |
|---|---|
| 下一頁（點、左滑、轉錶冠、雙指互點、鎖定畫面按鈕） | → |
| 上一頁 | ← |
| 開始播放 | Keynote：⌥⌘P；PowerPoint：⇧⌘↩；其他 App：⌘↩ |
| 結束播放 | Esc |
| 黑畫面 | B |
| 跳頁 | 頁碼的數字鍵（主鍵盤上方那排），再按 ↩ |

安全限制（`AppModel.handleRemote`、`PresenterKeys`）：

- 要在 Mac 的「手機與手錶」打開「允許簡報遙控」（預設關閉），而且只送上面這幾個鍵，不接受任意按鍵。
- 螢幕鎖著、或登入畫面在最前面時不送，免得打進密碼欄。
- 指令走配對時的加密藍牙連線，和鎖定、暫停一樣防重送。

手機上會顯示 Mac 最前面是哪個 App。如果它不在 `PresenterKeys.presentationApps`（簡報軟體、PDF 閱讀器、常見瀏覽器）裡，就提醒「翻頁的按鍵會送到那裡」。

## 簡報時暫停自動鎖定

簡報者拿著手機走到台前，訊號變弱，Presence 原本會把投影中的畫面鎖住。有兩種情況會暫停自動鎖定：

1. **在手機打開簡報遙控**：暫停自動鎖定與解鎖，最多 3 小時，在手機上結束簡報就恢復。
2. **偵測到簡報正在播放**（「情境」頁的「播放簡報時不自動鎖定」，預設開啟，`PresentationDetector`）：Keynote、PowerPoint、Folium 要求螢幕保持亮著（`PreventUserIdleDisplaySleep`）時。結束播放後，如果人不在附近會馬上鎖定。

偵測的依據是 2026-10-15 在 macOS 26.7 實測：

- Keynote 播放時有 `PreventUserIdleDisplaySleep named: "Displaying Keynote slideshow"`，編輯時沒有。
- 預覽程式的幻燈片秀只有全螢幕視窗，沒有這個要求，和一般全螢幕分不出來，所以不偵測。
- 瀏覽器也不偵測：Comet（Chromium 系的瀏覽器）播放影片時一直有 `NoDisplaySleepAssertion named: "Video Wake Lock"`，算進來的話，看影片時人離開也不會鎖。

用瀏覽器（Google 簡報）或預覽程式簡報時，請用手機的簡報遙控，或從選單列暫停。

## 其他 App 怎麼配合

1. **簡報模式支援上面的按鍵**。Presence 對 Keynote、PowerPoint 以外的 App 用 ⌘↩ 開始播放，所以建議把 ⌘↩ 當「從目前這一頁開始簡報」。方向鍵、B、數字、Esc 只在簡報畫面處理，不要做成全域快捷鍵。另外支援 ↓、空白鍵、Page Down（一般藍牙簡報筆送的）會更好用。
2. **只在播放時要求螢幕保持亮著**。Mac 用 `ProcessInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated], reason:)`，結束時 `endActivity`；可以用 `pmset -g assertions` 確認。閱讀、編輯時不要要求，否則那個 App 開著時 Presence 永遠不會自動鎖定。
3. **讓 Presence 認得**：把 bundle ID 加進 `PresenterKeys.presentationApps`；要讓「播放時不鎖定」也生效，再加進 `PresentationDetector.apps`。Folium（`com.chung.folium`）已經加了。

Folium 的實作指引（中文、照 Folium 專案的格式）在 Folium 專案的 `kb/wiki/concepts/presence-presenter-remote.md`。

## 之後

- 手機顯示「第 5 / 23 頁」與講者備忘稿：要讀簡報 App 的內容。Keynote、PowerPoint 可以用 Apple Events，但要使用者給「控制 Keynote」的權限；Folium 可以用輔助使用 API 讀它在簡報畫面放的固定識別碼。Google 簡報做不到。
- 雷射筆：用手機的陀螺儀在 Mac 畫面上疊一層紅點或聚光燈。
