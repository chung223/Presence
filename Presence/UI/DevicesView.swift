import SwiftUI

struct DevicesView: View {
    @Bindable var model: AppModel

    var body: some View {
        let target = model.preferences.targetID
        let devices = model.bluetooth.nearby.filter {
            model.preferences.showUnnamedDevices || $0.name != nil || $0.id == target
        }
        Form {
            Section("目前監控") {
                if let target {
                    let current = model.bluetooth.nearby.first { $0.id == target }
                    HStack(spacing: 12) {
                        SignalBars(rssi: current?.rssi)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.targetDisplayName)
                            Text(target.uuidString).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Text(current.map { "\($0.rssi) dBm" } ?? "不在範圍內")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("還沒選擇裝置，從下面的列表挑一台。").foregroundStyle(.secondary)
                }
            }

            Section {
                if devices.isEmpty {
                    Text(model.bluetooth.availability == .poweredOn ? "正在掃描…" : "藍牙\(model.bluetooth.availability.description)")
                        .foregroundStyle(.secondary)
                }
                ForEach(devices) { device in
                    DeviceRow(device: device, isTarget: device.id == target) {
                        model.select(device)
                    }
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
                Text("拿著手機靠近或遠離 Mac，看哪一台的訊號跟著變，就是它。iPhone 和 Apple Watch 要登入和這台 Mac 相同的 Apple 帳號，Mac 才認得出同一台裝置；其他廠牌的裝置如果會定期更換藍牙位址，就沒辦法持續追蹤。")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("裝置")
    }
}

private struct DeviceRow: View {
    let device: BluetoothMonitor.NearbyDevice
    let isTarget: Bool
    let select: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            SignalBars(rssi: device.rssi)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name ?? "未命名裝置")
                    .foregroundStyle(device.name == nil ? .secondary : .primary)
                Text(device.id.uuidString.prefix(8) + "…")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Text("\(device.rssi) dBm")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if isTarget {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .frame(width: 60)
            } else {
                Button("監控", action: select)
                    .frame(width: 60)
            }
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
        .accessibilityLabel(rssi.map { "訊號 \($0) dBm" } ?? "沒有訊號")
    }
}
