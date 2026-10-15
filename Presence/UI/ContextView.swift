import PresenceCore
import SwiftUI

/// 依情境暫停自動鎖定：播放簡報時、信任的網路、接著電源、指定時段。
struct ContextView: View {
    @Bindable var model: AppModel
    @State private var namingNetwork = false
    @State private var networkName = ""

    var body: some View {
        Form {
            Section {
                LabeledContent("目前") {
                    if let reason = model.suspension {
                        Text("\(AppModel.Status.describe(reason))，不會自動鎖定")
                            .foregroundStyle(.orange)
                    } else {
                        Text(model.preferences.context.isEmpty ? String(localized: "沒有設定情境，一律照常") : String(localized: "照常自動鎖定"))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                Toggle("播放簡報時不自動鎖定", isOn: $model.preferences.context.pauseWhilePresenting)
            } header: {
                Text("簡報")
            } footer: {
                Text("Keynote、PowerPoint 或 Folium 播放簡報時，就算你走到台前、訊號變弱，也不會把投影中的畫面鎖住；結束播放後如果你不在附近，會馬上鎖定。瀏覽器裡的 Google 簡報和預覽程式的幻燈片秀偵測不到（和全螢幕看影片分不出來），請用 iPhone 的簡報遙控，或從選單列暫停。")
            }

            Section {
                ForEach(model.preferences.context.trustedNetworks) { network in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(network.name)
                            Text("路由器 \(network.id)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if network.id == model.currentNetwork?.id {
                            Text("目前連線中").font(.caption).foregroundStyle(.green)
                        }
                        Button("移除", role: .destructive) {
                            model.preferences.context.trustedNetworks.removeAll { $0.id == network.id }
                        }
                    }
                }
                LabeledContent("目前的網路") {
                    if let current = model.currentNetwork {
                        HStack {
                            Text(current.ssid ?? String(localized: "路由器 \(current.id)")).foregroundStyle(.secondary)
                            if !isTrusted(current) {
                                Button("加入信任…") {
                                    networkName = current.ssid ?? ""
                                    namingNetwork = true
                                }
                            }
                        }
                    } else {
                        Text("沒有連上網路").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("信任的網路")
            } footer: {
                Text("連上這些網路時不會自動鎖定，例如家裡。Presence 用路由器的硬體位址辨識網路，不需要定位權限。")
            }

            Section {
                if model.hasBattery {
                    Toggle("只在使用電池時自動鎖定", isOn: $model.preferences.context.onlyOnBattery)
                } else {
                    Text("這台 Mac 沒有電池，不適用。").foregroundStyle(.secondary)
                }
            } header: {
                Text("電源")
            } footer: {
                Text("接著電源時通常放在固定的地方，例如家裡的書桌；帶出門用電池時才自動鎖定。")
            }

            Section {
                Toggle("只在指定時段自動鎖定", isOn: $model.preferences.context.scheduleEnabled)
                if model.preferences.context.scheduleEnabled {
                    DatePicker("開始", selection: minutesBinding(\.scheduleStart), displayedComponents: .hourAndMinute)
                    DatePicker("結束", selection: minutesBinding(\.scheduleEnd), displayedComponents: .hourAndMinute)
                    LabeledContent("星期") {
                        HStack(spacing: 4) {
                            ForEach(Self.weekdayOrder, id: \.self) { day in
                                Toggle(Self.weekdaySymbols[day - 1], isOn: weekdayBinding(day))
                                    .toggleStyle(.button)
                            }
                        }
                    }
                }
            } header: {
                Text("時段")
            } footer: {
                Text("例如只在上班時間自動鎖定。開始晚於結束表示跨過午夜，例如 22:00 到 06:00。")
            }

            Section {
                Toggle("情境符合時也暫停自動解鎖", isOn: $model.preferences.context.alsoSuspendUnlock)
            } footer: {
                Text("預設只暫停自動鎖定，回來時仍會自動解鎖。情境結束時如果裝置不在附近，會立刻鎖定。")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("情境")
        .task { await model.refreshNetwork() }
        .alert("為這個網路取個名字", isPresented: $namingNetwork) {
            TextField("例如：家裡", text: $networkName)
            Button("加入") { model.trustCurrentNetwork(named: networkName) }
            Button("取消", role: .cancel) {}
        } message: {
            if model.currentNetwork?.isShared == true {
                Text("注意：這個網路的路由器使用企業或旅館常見的共用位址，其他地方的網路可能被誤認成同一個。建議只信任家裡這類自己的網路。")
            } else {
                Text("連上這個網路時，Presence 不會自動鎖定。")
            }
        }
    }

    private func isTrusted(_ network: NetworkIdentity.Current) -> Bool {
        model.preferences.context.trustedNetworks.contains { $0.id == network.id }
    }

    /// 依照系統設定的一週第一天排列（台灣通常從星期日開始）。
    private static var weekdayOrder: [Int] {
        let first = Calendar.current.firstWeekday
        return (0..<7).map { (first - 1 + $0) % 7 + 1 }
    }

    private static let weekdaySymbols = Calendar.current.veryShortStandaloneWeekdaySymbols

    private func weekdayBinding(_ day: Int) -> Binding<Bool> {
        Binding(
            get: { model.preferences.context.weekdays.contains(day) },
            set: { on in
                if on { model.preferences.context.weekdays.insert(day) } else { model.preferences.context.weekdays.remove(day) }
            }
        )
    }

    private func minutesBinding(_ keyPath: WritableKeyPath<ContextRules, Int>) -> Binding<Date> {
        Binding(
            get: {
                let minutes = model.preferences.context[keyPath: keyPath]
                return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                model.preferences.context[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            }
        )
    }
}
