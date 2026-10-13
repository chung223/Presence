import SwiftUI

/// 分別量「希望解鎖」和「希望鎖定」兩個位置的訊號，同時算出每台裝置的建議門檻。
struct CalibrationSheet: View {
    enum Step: Equatable {
        case near, measuringNear, far, measuringFar, result
    }

    struct Suggestion: Identifiable {
        let device: MonitoredDevice
        let near: Int?
        let far: Int?
        var id: UUID { device.id }

        var unlock: Int? { near.map { $0 - 4 } }
        var lock: Int? {
            guard let unlock, let far else { return nil }
            return min(far + 3, unlock - 5)
        }
        var tooClose: Bool {
            guard let unlock, let far else { return false }
            return far + 3 > unlock - 5
        }
    }

    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .near
    @State private var nearRSSI: [UUID: Int] = [:]
    @State private var farRSSI: [UUID: Int] = [:]
    @State private var failed = false

    private static let duration: Double = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("校準門檻").font(.title3.weight(.semibold))
            content
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                actionButton
            }
        }
        .padding(20)
        .frame(width: 480, height: 340)
    }

    private var devicesText: String {
        model.preferences.devices.map(\.displayName).joined(separator: "、")
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .near:
            instruction(1, "帶著\(devicesText)，坐在你平常使用 Mac 的位置。", "Apple Watch 請戴在手上。這個位置的訊號會用來決定解鎖門檻。")
        case .measuringNear, .measuringFar:
            VStack(alignment: .leading, spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("正在測量，請保持不動約 \(Int(Self.duration)) 秒…")
                ForEach(model.preferences.devices) { device in
                    Text("\(device.displayName)：\(model.smoothedRSSI(for: device.id).map { "\($0) dBm" } ?? "—")")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        case .far:
            instruction(2, "帶著\(devicesText)走到你希望 Mac 開始鎖定的地方。", "例如門口或隔壁座位。到了以後再按「開始測量」。")
        case .result:
            result
        }
        if failed {
            Text("沒有收到足夠的訊號，請確認裝置在附近、藍牙是開的，再試一次。")
                .font(.callout)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch step {
        case .near:
            Button("開始測量") { measure(near: true) }.keyboardShortcut(.defaultAction)
        case .far:
            HStack {
                Button("只設定解鎖門檻") { step = .result }
                Button("開始測量") { measure(near: false) }.keyboardShortcut(.defaultAction)
            }
        case .measuringNear, .measuringFar:
            Button("測量中") {}.disabled(true)
        case .result:
            Button("套用") { apply() }.keyboardShortcut(.defaultAction)
                .disabled(suggestions.allSatisfy { $0.unlock == nil })
        }
    }

    private func instruction(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .font(.headline)
                .frame(width: 28, height: 28)
                .background(.tint.opacity(0.15), in: .circle)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).fontWeight(.medium)
                Text(detail).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var suggestions: [Suggestion] {
        model.preferences.devices.map { Suggestion(device: $0, near: nearRSSI[$0.id], far: farRSSI[$0.id]) }
    }

    private var result: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                Text("裝置")
                Text("座位")
                Text("鎖定位置")
                Text("建議解鎖")
                Text("建議鎖定")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Divider()
            ForEach(suggestions) { s in
                GridRow {
                    Text(s.device.displayName).lineLimit(1)
                    Text(s.near.map(String.init) ?? "—")
                    Text(s.far.map(String.init) ?? "—")
                    Text(s.unlock.map(String.init) ?? "沒收到").foregroundStyle(s.unlock == nil ? .secondary : Color.green)
                    Text(s.lock.map(String.init) ?? "—").foregroundStyle(.orange)
                }
            }
            if suggestions.contains(where: \.tooClose) {
                Text("有裝置在兩個位置的訊號太接近，鎖定門檻已自動拉開。建議把鎖定位置再走遠一點重新校準。")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .gridCellColumns(5)
            }
        }
        .monospacedDigit()
    }

    private func measure(near: Bool) {
        failed = false
        step = near ? .measuringNear : .measuringFar
        Task {
            let values = await model.measureRSSI(for: Self.duration)
            guard !values.isEmpty else {
                failed = true
                step = near ? .near : .far
                return
            }
            if near {
                nearRSSI = values
                step = .far
            } else {
                farRSSI = values
                step = .result
            }
        }
    }

    private func apply() {
        for s in suggestions {
            if let unlock = s.unlock {
                model.preferences.unlockEnabled = true
                model.preferences.setUnlockRSSI(unlock, for: s.device.id)
            }
            if let lock = s.lock {
                model.preferences.lockEnabled = true
                model.preferences.setLockRSSI(lock, for: s.device.id)
            }
        }
        dismiss()
    }
}
