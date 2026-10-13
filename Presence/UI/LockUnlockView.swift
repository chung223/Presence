import SwiftUI

struct LockUnlockView: View {
    @Bindable var model: AppModel
    @State private var showingPassword = false
    @State private var showingCalibration = false

    var body: some View {
        Form {
            Section {
                Toggle("離開時自動鎖定", isOn: $model.preferences.lockEnabled)
                Picker("訊號低於門檻多久才鎖定", selection: $model.preferences.lockDelay) {
                    ForEach([2, 5, 10, 15, 30, 60] as [TimeInterval], id: \.self) { Text(Self.seconds($0)).tag($0) }
                }
                .disabled(!model.preferences.lockEnabled)
                Picker("完全收不到訊號多久就鎖定", selection: $model.preferences.signalTimeout) {
                    ForEach([30, 60, 120, 300, 600] as [TimeInterval], id: \.self) { Text(Self.seconds($0)).tag($0) }
                }
                .disabled(!model.preferences.lockEnabled)
                Picker("鎖定方式", selection: $model.preferences.lockMethod) {
                    ForEach(LockMethod.allCases) { Text($0.title).tag($0) }
                }
                .disabled(!model.preferences.lockEnabled)
                Toggle("鎖定後在鎖定畫面顯示原因", isOn: notifyBinding)
                    .disabled(!model.preferences.lockEnabled)
            } header: {
                Text("自動鎖定")
            } footer: {
                Text("藍牙關閉或收不到訊號時也會在逾時後鎖定。用螢幕保護程式鎖定時，要在系統設定把「螢幕保護程式啟動後要求密碼」設為「立即」，否則 Presence 會改用直接鎖定。")
            }

            Section {
                Toggle("回來時自動解鎖", isOn: $model.preferences.unlockEnabled)
                Toggle("靠近時喚醒螢幕", isOn: $model.preferences.wakeOnProximity)
                    .disabled(!model.preferences.unlockEnabled)
                LabeledContent("登入密碼") {
                    HStack {
                        Text(model.hasPassword ? String(localized: "已設定") : String(localized: "未設定"))
                            .foregroundStyle(model.hasPassword ? Color.secondary : Color.red)
                        Button(model.hasPassword ? String(localized: "更改…") : String(localized: "設定…")) { showingPassword = true }
                        if model.hasPassword {
                            Button("移除") { model.removePassword() }
                        }
                    }
                }
                if !model.accessibilityGranted {
                    LabeledContent("輔助使用權限") {
                        HStack {
                            Text("未允許").foregroundStyle(.red)
                            Button("打開設定") { Accessibility.openSettings() }
                        }
                    }
                }
                if model.automation.isBlockedByFailures {
                    LabeledContent {
                        Button("恢復自動解鎖") { model.resumeAutoUnlock() }
                    } label: {
                        Label("連續解鎖失敗，已停止自動解鎖。如果改過登入密碼，請重新設定。", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            } header: {
                Text("自動解鎖")
            } footer: {
                Text("訊號在幾秒內持續高於解鎖門檻才會解鎖，單一筆異常的強訊號不算。關掉「靠近時喚醒螢幕」後，要等你按鍵盤或滑鼠叫醒螢幕才會解鎖，比較安全。")
            }

            Section {
                LabeledContent("不確定門檻要設多少？") {
                    Button("開始校準…") { showingCalibration = true }
                        .disabled(!model.hasDevices)
                }
            } header: {
                Text("門檻")
            } footer: {
                Text("校準時分別站在「希望解鎖」和「希望鎖定」的位置各量 8 秒，會同時算出每台裝置的門檻。數值越接近 0 代表要越近。")
            }

            ForEach(model.preferences.devices) { device in
                Section(device.displayName) {
                    ThresholdRow(title: "解鎖門檻", value: unlockBinding(device.id), range: -99 ... -30,
                                 current: model.smoothedRSSI(for: device.id), tint: .green)
                        .disabled(!model.preferences.unlockEnabled)
                    ThresholdRow(title: "鎖定門檻", value: lockBinding(device.id), range: -100 ... -31,
                                 current: nil, tint: .orange)
                        .disabled(!model.preferences.lockEnabled)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("鎖定與解鎖")
        .sheet(isPresented: $showingPassword) { PasswordSheet(model: model) }
        .sheet(isPresented: $showingCalibration) { CalibrationSheet(model: model) }
    }

    private func lockBinding(_ id: UUID) -> Binding<Int> {
        Binding(get: { model.preferences.device(id)?.lockRSSI ?? -75 },
                set: { model.preferences.setLockRSSI($0, for: id) })
    }

    private func unlockBinding(_ id: UUID) -> Binding<Int> {
        Binding(get: { model.preferences.device(id)?.unlockRSSI ?? -60 },
                set: { model.preferences.setUnlockRSSI($0, for: id) })
    }

    private var notifyBinding: Binding<Bool> {
        Binding(get: { model.preferences.notifyOnLock }, set: { enabled in
            model.preferences.notifyOnLock = enabled
            if enabled { Task { _ = await Notifier.requestAuthorization() } }
        })
    }

    static func seconds(_ value: TimeInterval) -> String {
        AppModel.describe(value)
    }
}

private struct ThresholdRow: View {
    let title: LocalizedStringKey
    @Binding var value: Int
    let range: ClosedRange<Int>
    let current: Int?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value) dBm").monospacedDigit().foregroundStyle(tint)
            }
            Slider(value: Binding(get: { Double(value) }, set: { value = Int($0.rounded()) }),
                   in: Double(range.lowerBound)...Double(range.upperBound)) {
                Text(title)
            } minimumValueLabel: {
                Text("遠").font(.caption)
            } maximumValueLabel: {
                Text("近").font(.caption)
            }
            .labelsHidden()
            .tint(tint)
            if let current {
                Text("目前訊號 \(current) dBm").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct PasswordSheet: View {
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("設定登入密碼").font(.title3.weight(.semibold))
            Text("Presence 會先確認這是「\(NSFullUserName())」的登入密碼，再存進鑰匙圈。只有自動解鎖時才會讀出來，不會寫進任何紀錄。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SecureField("登入密碼", text: $password)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("儲存", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func save() {
        guard !password.isEmpty else { return }
        if let message = model.setPassword(password) {
            error = message
        } else {
            password = ""
            dismiss()
        }
    }
}
