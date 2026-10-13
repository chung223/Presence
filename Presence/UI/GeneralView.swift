import SwiftUI
import UserNotifications

struct GeneralView: View {
    @Bindable var model: AppModel
    @State private var loginError: String?
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined

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
                        Text(EventScript.isInstalled ? "已安裝" : "未安裝").foregroundStyle(.secondary)
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
        }
    }

    private var connectionText: String {
        let total = model.preferences.devices.count
        let connected = model.bluetooth.connections.values.filter { $0 == .connected }.count
        return total == 0 ? "沒有監控中的裝置" : "已連線 \(connected) 台，共 \(total) 台"
    }
}
