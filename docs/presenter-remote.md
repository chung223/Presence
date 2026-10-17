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
| 跳頁 | 頁碼的數字鍵（主鍵盤上方那排），再按 ↩；送的時候暫時換成英文鍵盤 |

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
- PowerPoint 播放時有 `NoDisplaySleepAssertion named: ""`，結束播放就放掉。
- 預覽程式的幻燈片秀只有全螢幕視窗，沒有這個要求，和一般全螢幕分不出來，所以不偵測。
- 瀏覽器也不偵測：Comet（Chromium 系的瀏覽器）播放影片時一直有 `NoDisplaySleepAssertion named: "Video Wake Lock"`，算進來的話，看影片時人離開也不會鎖。

用瀏覽器（Google 簡報）或預覽程式簡報時，請用手機的簡報遙控，或從選單列暫停。

## 實測（2026-10-15，iPhone TestFlight 版＋Mac 0.2.0）

Keynote 與 PowerPoint 都測過開始播放、下一頁、上一頁、跳頁、黑畫面（再按一次回來）、結束播放，演講倒數也正常。

- **跳頁要換成英文鍵盤**：Keynote 按下第一個數字會打開投影片導覽與頁碼欄，但用中文輸入法（Rime）時 Return 被輸入法吃掉，導覽停住不跳頁。現在 `PresenterKeys.goTo` 先換成英文鍵盤（`TISCopyCurrentASCIICapableKeyboardInputSource`），送完再換回原本的輸入法。
- Keynote 的「播放」從目前選取的那一頁開始，不一定是第一頁（PowerPoint 的 ⇧⌘↩ 也是）。
- 沒有測：鎖定畫面與動態島的按鈕、手錶（要真人按）。

## 雷射筆與聚光燈（2026-10-17，第一版）

手機簡報畫面上方多了「翻頁、雷射筆、聚光燈」三種模式（Mac 太舊時只有翻頁）。雷射筆和聚光燈的觸控區形狀跟 Mac 上播放簡報的螢幕一樣，手指按在哪裡，投影畫面上就在同一個位置出現紅點或聚光燈。

- **不模擬滑鼠**：Mac 在播放簡報的螢幕最上層疊一個透明、點不到的視窗（`PointerOverlay`，`.screenSaver` 層級、所有桌面空間都在），只畫不點擊，所以每個簡報軟體都一樣能用，也不會誤按到東西。
- **位置走另一條通道**：藍牙特徵 `LinkIdentifiers.pointer`，寫入不等回覆，每秒約 30 筆；每筆 58 位元組（配對編號＋AES-GCM 加密的 14 位元組），驗證內容多加 "pointer"，指令的密文不能拿來當位置。Mac 只收比上一筆新、時鐘差 30 秒內的（`PointerGuard`）。手指停著不動時每秒補送一次。
- **Mac 端**：兩筆之間用 70 毫秒的線性動畫補平；手指放開、或 2.5 秒沒收到位置就淡出收起。畫在 Mac 正在使用的 App 最大那個視窗所在的螢幕（接投影機時就是播放簡報的那個），寬高比放在 `LinkStatus.screenAspect` 給手機。
- **實測**（Keynote 全螢幕播放、MacBook 內建螢幕）：紅點與聚光燈都蓋在簡報上面；第一次測時收起雷射筆的視窗被系統當成「最後一個視窗關掉」而結束整個 Presence，已改成 `applicationShouldTerminateAfterLastWindowClosed` 回傳 false。
- **聚光燈的畫法**：一整片比螢幕大很多的暗色圖層，中間一個邊緣柔和的洞，整片跟著手指移動。第一版用「洞＋四周四塊暗色」拼起來，移動時幾塊的動畫對不齊，洞的四周出現方形接縫，使用者實測說效果很差。圖只畫洞附近一小塊，外面靠 `contentsRect` 超出圖的範圍時延伸最外圈的暗色，邊緣才細緻、記憶體也小。四周暗 0.8、邊緣在半徑的 0.9～1.1 倍之間由亮變暗（第一版 0.72、邊緣太寬，像一團白光）。
- **自己檢查效果**：開發版 `-PresenceDemo YES -PresencePointerDemo spotlight`（或 `laser`）會在螢幕中間 1280×720 的範圍畫一張假投影片，照固定路線走一遍（8 字、甩到四個角、停住、收起）；假投影片畫在同一個視窗裡，用 `scripts/promo/winrec` 只錄那個視窗就看得到結果。
- 還沒做：手錶的雷射筆、接投影機的雙螢幕實測。

## 螢光筆（2026-10-17）

手機工具列多了「螢光筆」（Mac 要夠新，`LinkStatus.highlighter` 是 true 才顯示）。手指在觸控區畫線，投影畫面同一個位置出現半透明的黃色線；手機上也畫出同樣的線。最後一筆畫完 4 秒後全部一起淡掉（先圈起來再畫底線，會一起留著）；翻頁、跳頁時馬上清掉，線不會留到下一頁。

- **筆畫號碼**：線是把收到的點連起來畫的，手指放開再按下要分成新的一筆，否則兩筆會連成一條線。收起的那筆（`.hidden`）可能掉，所以 `PointerUpdate` 多了筆畫號碼 `stroke`，手指每按下一次換一個。只有螢光筆送第 2 版格式（15 位元組，最後一個位元組是筆畫號碼），雷射筆、聚光燈照舊送第 1 版，舊版 Mac 看得懂。
- **送得比較密**：螢光筆每 16 毫秒送一次最新位置（雷射筆 33 毫秒），Mac 再用經過每一點的平滑曲線連起來（相鄰兩點的中點相連、原本的點當控制點），快速畫圈也不會變成多邊形。
- **畫法**：每一筆一個 `CAShapeLayer`，線本身不透明、透明度放在圖層上（0.68）：同一筆自己交疊的地方不會更深，不同筆交疊會更深，跟真的螢光筆一樣。粗細是螢幕高度的 2%。線畫在聚光燈的暗色上面；紅點、聚光燈收起時線還留著，線都淡掉了才把透明視窗拿掉。
- **自己檢查**：`-PresenceDemo YES -PresencePointerDemo highlighter` 在假投影片上畫一條底線、再圈起最高的長條，等它淡掉。第一次的黃色（0.55）在白底上太淡，改成比較深的黃、0.68。
- **實測**（iPhone 開發版經藍牙送到 MacBook Pro，只錄透明視窗）：連畫三筆，Mac 上是三條分開的線、沒有連在一起，留著幾秒後一起淡掉，透明視窗也收起。之後使用者親手試過，可以用。

## Mac 的音量（2026-10-17）

簡報裡的影片太大聲或太小聲時，不用走回電腦。手機簡報畫面的「上一頁」下面有一條音量條：拖拉調整，點喇叭靜音。手錶在「上一頁」左邊有喇叭按鈕，點開後轉錶冠調整（簡報畫面的錶冠拿來翻頁，所以音量另外開一頁）。

- **Mac 直接調系統音量**（`SystemVolume`，CoreAudio 的 `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` 與 `kAudioDevicePropertyMute`），不模擬鍵盤的音量鍵：投影畫面上不會跳出音量圖示，也不需要輔助使用權限。調大聲時跟音量鍵一樣順便取消靜音；沒有靜音開關的裝置用音量 0 代替，取消時調回原本的音量。
- **指令** `LinkCommand.volume(VolumeChange)`：`set(0～1)`、`step(up:)`（一格 1/16，跟音量鍵一樣）、`mute(Bool)`，要 Presence Pro、要允許簡報遙控。**狀態** `LinkStatus.volume`（音量、靜音、能不能調）：舊版 Mac 是 nil，手機與手錶就不顯示音量。Mac 每秒檢查一次，音量變了（例如在 Mac 上按音量鍵）就推送給手機。
- **接 HDMI 的電視、投影機常常不能從 Mac 調音量**（Mac 的音量鍵也沒用）：這時 `adjustable` 是 false，手機只顯示說明；硬送會收到 `CommandRefusal.volumeNotAdjustable`。
- **拖拉不塞車**：手機與手錶同時只送一筆，前一筆有回覆了才送最新的值。手機的音量條在最後一次拉動後 1.5 秒內顯示手指的位置，之後顯示 Mac 回報的音量；第一版用 Slider 的 `onEditingChanged` 判斷放開，實測放開後音量條一直停在手指的位置，Mac 的音量變了也不動。
- **實測**（MacBook Pro 內建喇叭，iPhone 開發版）：手機拉到 69%，Mac 也是 69%；靜音、取消靜音都正確；在 Mac 上把音量改成 62%，手機一兩秒內跟著變。手錶（Apple Watch Ultra 2，經由 iPhone 轉送）使用者實測可以用。
- iPhone 側邊的實體音量鍵不能拿來調 Mac：Apple 不讓 App 接管，繞過的做法容易被退審。

## 其他 App 怎麼配合

1. **簡報模式支援上面的按鍵**。Presence 對 Keynote、PowerPoint 以外的 App 用 ⌘↩ 開始播放，所以建議把 ⌘↩ 當「從目前這一頁開始簡報」。方向鍵、B、數字、Esc 只在簡報畫面處理，不要做成全域快捷鍵。另外支援 ↓、空白鍵、Page Down（一般藍牙簡報筆送的）會更好用。
2. **只在播放時要求螢幕保持亮著**。Mac 用 `ProcessInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated], reason:)`，結束時 `endActivity`；可以用 `pmset -g assertions` 確認。閱讀、編輯時不要要求，否則那個 App 開著時 Presence 永遠不會自動鎖定。
3. **讓 Presence 認得**：把 bundle ID 加進 `PresenterKeys.presentationApps`；要讓「播放時不鎖定」也生效，再加進 `PresentationDetector.apps`。Folium（`com.chung.folium`）已經加了。

Folium 的實作指引（中文、照 Folium 專案的格式）在 Folium 專案的 `kb/wiki/concepts/presence-presenter-remote.md`。

## 之後

- 手機顯示「第 5 / 23 頁」與講者備忘稿：要讀簡報 App 的內容。Keynote、PowerPoint 可以用 Apple Events，但要使用者給「控制 Keynote」的權限；Folium 可以用輔助使用 API 讀它在簡報畫面放的固定識別碼。Google 簡報做不到。
