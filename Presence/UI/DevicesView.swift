import PresenceCore
import SwiftUI

struct DevicesView: View {
    @Bindable var model: AppModel

    var body: some View {
        let monitored = Set(model.preferences.devices.map(\.id))
        let candidates = model.bluetooth.nearby.filter {
            !monitored.contains($0.id) && (model.preferences.showUnnamedDevices || $0.name != nil)
        }
        Form {
            Section {
                if model.preferences.devices.isEmpty {
                    Text("還沒有監控任何裝置，從下面的列表加入。").foregroundStyle(.secondary)
                }
                ForEach(model.preferences.devices) { device in
                    let current = model.bluetooth.nearby.first { $0.id == device.id }
                    HStack(spacing: 12) {
                        SignalBars(rssi: current?.rssi)
                        VStack(alignment: .leading, spacing: 2) {
                            TextField("名稱", text: nameBinding(device.id), prompt: Text(MonitoredDevice.unnamed))
                                .textFieldStyle(.plain)
                            Text(device.id.uuidString).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Text(current.map { "\($0.rssi) dBm" } ?? String(localized: "不在範圍內"))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Button("移除", role: .destructive) { model.removeDevice(device.id) }
                    }
                }
                if model.preferences.devices.count > 1 {
                    Picker("多台裝置時", selection: $model.preferences.devicePolicy) {
                        Text("任一台在附近就算我在").tag(PresenceGroup.Policy.anyNear)
                        Text("每一台都要在附近").tag(PresenceGroup.Policy.allNear)
                    }
                }
            } header: {
                Text("監控中的裝置")
            } footer: {
                Text("預設任一台在附近就算你在，全部都離開才會鎖定。例如同時加入 iPhone 和 Apple Watch，手錶訊號變弱時只要手機還在就不會鎖。選「每一台都要在附近」則任一台離開就鎖，比較嚴格。每台裝置的門檻在「鎖定與解鎖」分開設定。")
            }

            Section {
                if candidates.isEmpty {
                    Text(model.bluetooth.availability == .poweredOn ? String(localized: "正在掃描…") : String(localized: "藍牙\(model.bluetooth.availability.description)"))
                        .foregroundStyle(.secondary)
                }
                ForEach(candidates) { device in
                    DeviceRow(device: device) { model.addDevice(device) }
                }
            } header: {
                HStack {
                    Text("附近的裝置（依訊號強弱排序）")
                    Spacer()
                    Toggle("顯示未命名裝置", isOn: $model.preferences.showUnnamedDevices)
                        .toggleStyle(.checkbox)
                        .font(.callout)
                }
            } footer: {
                Text("拿著裝置靠近或遠離 Mac，看哪一台的訊號跟著變，就是它。iPhone 和 Apple Watch 要登入和這台 Mac 相同的 Apple 帳號，Mac 才認得出同一台裝置；其他廠牌的裝置如果會定期更換藍牙位址，就沒辦法持續追蹤。")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("裝置")
    }

    private func nameBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { model.preferences.device(id)?.name ?? "" },
                set: { model.preferences.rename(id, to: $0) })
    }
}

private struct DeviceRow: View {
    let device: BluetoothMonitor.NearbyDevice
    let add: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            SignalBars(rssi: device.rssi)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name ?? String(localized: "未命名裝置"))
                    .foregroundStyle(device.name == nil ? .secondary : .primary)
                Text(device.id.uuidString.prefix(8) + "…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text("\(device.rssi) dBm")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Button("加入", action: add)
        }
    }
}

struct SignalBars: View {
    let rssi: Int?

    private var level: Int {
        guard let rssi else { return 0 }
        switch rssi {
        case (-55)...: return 4
        case (-67)...: return 3
        case (-78)...: return 2
        default: return 1
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(1...4, id: \.self) { bar in
                RoundedRectangle(cornerRadius: 1)
                    .fill(bar <= level ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary))
                    .frame(width: 4, height: CGFloat(4 + bar * 3))
            }
        }
        .frame(width: 24, height: 18, alignment: .bottom)
        .accessibilityLabel(rssi.map { String(localized: "訊號 \($0) dBm") } ?? String(localized: "沒有訊號"))
    }
}
