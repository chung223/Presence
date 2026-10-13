import Carbon.HIToolbox
import SwiftUI
import UserNotifications

struct GeneralView: View {
    @Bindable var model: AppModel
    @State private var loginError: String?
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var shortcuts: [String] = []
    @State private var cameraDenied = false

    var body: some View {
        Form {
            Section("啟動") {
                Toggle("登入時自動啟動", isOn: Binding(
                    get: { model.loginItemEnabled },
                    set: { loginError = model.setLaunchAtLogin($0) }
                ))
                if model.loginItemNeedsApproval {
                    LabeledContent("需要你在系統設定允許") {
                        Button("打開登入項目設定") { LoginItem.openSettings() }
                    }
                }
                if let loginError {
                    Text(loginError).font(.callout).foregroundStyle(.red)
                }
            }

            Section {
                LabeledContent("立即鎖定的快捷鍵") {
                    HotKeyRecorder(hotKey: $model.preferences.lockHotKey)
                }
                if model.hotKeyConflict {
                    Text("這組快捷鍵已被其他 App 使用，請換一組。").font(.callout).foregroundStyle(.red)
                }
            } header: {
                Text("快捷鍵與捷徑")
            } footer: {
                Text("在任何 App 裡按下快捷鍵就會立即鎖定。「捷徑」App 裡也有 Presence 的動作（立即鎖定、暫停、恢復、取得狀態），可以接進自動化，或在終端機用 shortcuts run 執行。")
            }

            Section {
                Picker("離開時執行", selection: $model.preferences.shortcutOnLeave) {
                    Text("不執行").tag(String?.none)
                    ForEach(shortcutChoices(model.preferences.shortcutOnLeave), id: \.self) { Text($0).tag(Optional($0)) }
                }
                Picker("回來時執行", selection: $model.preferences.shortcutOnReturn) {
                    Text("不執行").tag(String?.none)
                    ForEach(shortcutChoices(model.preferences.shortcutOnReturn), id: \.self) { Text($0).tag(Optional($0)) }
                }
            } header: {
                Text("自動執行捷徑")
            } footer: {
                Text("Presence 鎖定時執行「離開時」的捷徑，之後解鎖時執行「回來時」的捷徑。例如離開時開啟專注模式、把 Slack 狀態改成離座、關燈，回來時再恢復。")
            }

            Section {
                Toggle("裝置不在時有人手動解鎖，就拍一張照片", isOn: photoBinding)
                if cameraDenied {
                    Text("沒有相機權限，請到「系統設定 › 隱私權與安全性 › 相機」打開 Presence。")
                        .font(.callout).foregroundStyle(.red)
                }
                LabeledContent("照片位置") {
                    Button("打開資料夾") {
                        if let dir = CameraCapture.directory {
                            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(dir)
                        }
                    }
                }
            } header: {
                Text("拍照存證")
            } footer: {
                Text("照片只存在這台 Mac 上，30 天後自動刪除，可以在「紀錄」頁查看。拍照時相機的綠燈會亮。如果你自己用 Touch ID 解鎖時剛好偵測不到裝置，也會拍到你自己。")
            }

            Section {
                Toggle("鎖定時暫停播放，解鎖後繼續", isOn: $model.preferences.pauseMedia)
            } header: {
                Text("播放")
            } footer: {
                Text("適用於 Music、Spotify、瀏覽器影片等出現在「正在播放」的內容。")
            }

            Section {
                Toggle("主動模式", isOn: $model.preferences.activeMode)
                if model.preferences.activeMode {
                    LabeledContent("連線狀態", value: connectionText)
                }
            } header: {
                Text("藍牙")
            } footer: {
                Text("主動模式會連線到裝置定期讀取訊號，數值比較穩定，但可能干擾藍牙鍵盤、滑鼠、耳機或個人熱點。被動模式只收廣播訊號，不會干擾其他設備。")
            }

            Section {
                LabeledContent("腳本位置") {
                    Text(EventScript.url?.path(percentEncoded: false) ?? "—")
                        .textSelection(.enabled)
                        .font(.callout.monospaced())
                }
                LabeledContent("狀態") {
                    HStack {
                        Text(EventScript.isInstalled ? String(localized: "已安裝") : String(localized: "未安裝")).foregroundStyle(.secondary)
                        Button("打開資料夾") {
                            if let dir = EventScript.directory { NSWorkspace.shared.open(dir) }
                        }
                    }
                }
            } header: {
                Text("事件腳本")
            } footer: {
                Text("在這個位置放一個名為 event 的可執行檔，鎖定或解鎖時會帶參數執行：away（訊號變弱而鎖定）、lost（收不到訊號而鎖定）、unlocked（自動解鎖）、intruded（裝置不在時被手動解鎖）。第二個參數是當時的訊號強度。與 BLEUnlock 相容。")
            }

            Section("權限") {
                LabeledContent("藍牙", value: model.bluetooth.availability.description)
                LabeledContent("輔助使用") {
                    if model.accessibilityGranted {
                        Text("已允許").foregroundStyle(.secondary)
                    } else {
                        Button("打開設定") { Accessibility.openSettings() }
                    }
                }
                LabeledContent("通知") {
                    switch notificationStatus {
                    case .authorized, .provisional:
                        Text("已允許").foregroundStyle(.secondary)
                    case .denied:
                        Button("打開設定") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    default:
                        Button("允許通知") {
                            Task {
                                _ = await Notifier.requestAuthorization()
                                notificationStatus = await Notifier.authorizationStatus()
                            }
                        }
                    }
                }
            }

            if LegacyBLEUnlock.hasSettings || model.legacyAppRunning {
                Section("舊版 BLEUnlock") {
                    if LegacyBLEUnlock.hasSettings {
                        LabeledContent("沿用裝置與門檻設定（不含密碼）") {
                            Button("匯入") { model.importLegacySettings() }
                        }
                    }
                    if model.legacyAppRunning {
                        LabeledContent("舊版正在執行，會互相干擾") {
                            Button("結束舊版") { model.quitLegacyApp() }
                        }
                    }
                }
            }

            Section("關於") {
                LabeledContent("版本", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                Text("Presence 的想法來自 Takeshi Sone 的 BLEUnlock（MIT 授權），為新版 macOS 重新設計與實作。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("一般")
        .task {
            model.refreshStatus()
            notificationStatus = await Notifier.authorizationStatus()
            shortcuts = await ShortcutsRunner.list()
        }
    }

    /// 捷徑清單；已選的捷徑如果被刪掉或改名，仍保留在選項裡，免得選單變成空白。
    private func shortcutChoices(_ selected: String?) -> [String] {
        guard let selected, !shortcuts.contains(selected) else { return shortcuts }
        return [selected] + shortcuts
    }

    private var photoBinding: Binding<Bool> {
        Binding(get: { model.preferences.capturePhotoOnIntrusion }, set: { enabled in
            guard enabled else {
                model.preferences.capturePhotoOnIntrusion = false
                return
            }
            Task {
                let granted = await CameraCapture.requestAccess()
                cameraDenied = !granted
                model.preferences.capturePhotoOnIntrusion = granted
            }
        })
    }

    private var connectionText: String {
        let total = model.preferences.devices.count
        let connected = model.bluetooth.connections.values.filter { $0 == .connected }.count
        return total == 0 ? String(localized: "沒有監控中的裝置") : String(localized: "已連線 \(connected) 台，共 \(total) 台")
    }
}

/// 按一下開始錄製，接著按下想要的組合鍵；Esc 取消。
private struct HotKeyRecorder: View {
    @Binding var hotKey: HotKey?
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Button(recording ? String(localized: "按下新的組合鍵…") : (hotKey?.display ?? String(localized: "設定…"))) {
                recording ? stop() : start()
            }
            .monospaced(hotKey != nil && !recording)
            if hotKey != nil, !recording {
                Button("清除") { hotKey = nil }
            }
        }
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == UInt16(kVK_Escape) {
                stop()
                return nil
            }
            guard let key = HotKey(event: event) else {
                NSSound.beep()
                return nil
            }
            hotKey = key
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
