import SwiftUI

/// 分別量「希望解鎖」和「希望鎖定」兩個位置的訊號，算出建議門檻。
struct CalibrationSheet: View {
    enum Step: Equatable {
        case near, measuringNear, far, measuringFar, result
    }

    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var step: Step = .near
    @State private var nearRSSI: Int?
    @State private var farRSSI: Int?
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
        .frame(width: 440, height: 300)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .near:
            instruction(1, "拿著\(model.targetDisplayName)，坐在你平常使用 Mac 的位置。", "這個位置的訊號會用來決定解鎖門檻。")
        case .measuringNear, .measuringFar:
            VStack(alignment: .leading, spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("正在測量，請保持不動約 \(Int(Self.duration)) 秒…")
                Text("目前訊號 \(model.engine.smoothedRSSI.map { "\($0) dBm" } ?? "—")")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case .far:
            instruction(2, "帶著\(model.targetDisplayName)走到你希望 Mac 開始鎖定的地方。", "例如門口或隔壁座位。到了以後再按「開始測量」。")
        case .result:
            result
        }
        if failed {
            Text("收到的訊號太少，請確認裝置在附近、藍牙是開的，再試一次。")
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
                .disabled(suggestion.unlock == nil)
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

    private var suggestion: (unlock: Int?, lock: Int?, tooClose: Bool) {
        guard let near = nearRSSI else { return (nil, nil, false) }
        let unlock = near - 4
        guard let far = farRSSI else { return (unlock, nil, false) }
        let lock = min(far + 3, unlock - 5)
        return (unlock, lock, far + 3 > unlock - 5)
    }

    private var result: some View {
        let s = suggestion
        return VStack(alignment: .leading, spacing: 8) {
            if let near = nearRSSI {
                LabeledContent("座位上的訊號", value: "\(near) dBm")
            }
            if let far = farRSSI {
                LabeledContent("鎖定位置的訊號", value: "\(far) dBm")
            }
            Divider()
            if let unlock = s.unlock {
                LabeledContent("建議解鎖門檻") { Text("\(unlock) dBm").foregroundStyle(.green) }
            }
            if let lock = s.lock {
                LabeledContent("建議鎖定門檻") { Text("\(lock) dBm").foregroundStyle(.orange) }
            }
            if s.tooClose {
                Text("兩個位置的訊號太接近，鎖定門檻已自動拉開。建議把鎖定位置再走遠一點重新校準。")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
        .monospacedDigit()
    }

    private func measure(near: Bool) {
        failed = false
        step = near ? .measuringNear : .measuringFar
        Task {
            let value = await model.measureRSSI(for: Self.duration)
            guard let value else {
                failed = true
                step = near ? .near : .far
                return
            }
            if near {
                nearRSSI = value
                step = .far
            } else {
                farRSSI = value
                step = .result
            }
        }
    }

    private func apply() {
        let s = suggestion
        if let unlock = s.unlock {
            model.preferences.unlockEnabled = true
            model.preferences.setUnlockRSSI(unlock)
        }
        if let lock = s.lock {
            model.preferences.lockEnabled = true
            model.preferences.setLockRSSI(lock)
        }
        dismiss()
    }
}
