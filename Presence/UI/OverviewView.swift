import Charts
import PresenceCore
import SwiftUI

struct OverviewView: View {
    let model: AppModel
    @Binding var selection: MainView.Section?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !model.pendingSetup.isEmpty {
                    SetupChecklist(model: model, selection: $selection)
                }
                StatusHeader(model: model)
                SignalChart(model: model)
                RecentEvents(log: model.log, selection: $selection)
            }
            .padding(24)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("總覽")
    }
}

// MARK: - 狀態

extension AppModel.Status {
    var tint: Color {
        switch self {
        case .near: .green
        case .leaving: .orange
        case .away: .secondary
        case .waiting: .secondary
        case .paused: .blue
        case .needsDevice, .bluetoothUnavailable: .yellow
        }
    }
}

private struct StatusHeader: View {
    let model: AppModel

    var body: some View {
        let status = model.status
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: status.symbol)
                .font(.system(size: 28, weight: .medium))
                .foregroundStyle(status.tint)
                .frame(width: 60, height: 60)
                .background(status.tint.opacity(0.15), in: .circle)
                .contentTransition(.symbolEffect(.replace))

            VStack(alignment: .leading, spacing: 4) {
                Text(model.preferences.targetID == nil ? status.title : "\(model.targetDisplayName) \(status.title)")
                    .font(.title2.weight(.semibold))
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack {
                if model.isPaused {
                    Button("恢復", systemImage: "play.fill") { model.resume() }
                } else {
                    Menu("暫停", systemImage: "pause.fill") {
                        Button("15 分鐘") { model.pause(for: 15 * 60) }
                        Button("1 小時") { model.pause(for: 60 * 60) }
                        Button("4 小時") { model.pause(for: 4 * 60 * 60) }
                    }
                    .fixedSize()
                }
                Button("立即鎖定", systemImage: "lock.fill") { model.lockNow() }
            }
            .controlSize(.large)
            .disabled(model.preferences.targetID == nil)
        }
        .padding(16)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
    }

    private var detail: String {
        if case .paused(let until) = model.status {
            return "自動鎖定與解鎖暫停到 \(until.formatted(date: .omitted, time: .shortened))"
        }
        var parts: [String] = []
        if let rssi = model.engine.smoothedRSSI { parts.append("訊號 \(rssi) dBm") }
        let p = model.preferences
        parts.append(p.unlockEnabled ? "解鎖門檻 \(p.unlockRSSI)" : "不自動解鎖")
        parts.append(p.lockEnabled ? "鎖定門檻 \(p.lockRSSI)" : "不自動鎖定")
        parts.append(p.activeMode ? "主動模式" : "被動模式")
        if model.automation.manualHold { parts.append("手動鎖定中") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 訊號圖

private struct SignalChart: View {
    let model: AppModel

    var body: some View {
        let p = model.preferences
        let end = model.now
        VStack(alignment: .leading, spacing: 8) {
            Text("最近 3 分鐘的訊號").font(.headline)
            Chart {
                ForEach(model.samples) { point in
                    PointMark(x: .value("時間", point.date), y: .value("RSSI", point.rssi))
                        .symbolSize(10)
                        .foregroundStyle(.secondary.opacity(0.35))
                }
                ForEach(model.smoothed) { point in
                    LineMark(x: .value("時間", point.date), y: .value("濾波後", point.rssi))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.tint)
                }
                if p.unlockEnabled {
                    RuleMark(y: .value("解鎖門檻", p.unlockRSSI))
                        .foregroundStyle(.green)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("解鎖 \(p.unlockRSSI)").font(.caption2).foregroundStyle(.green)
                        }
                }
                if p.lockEnabled {
                    RuleMark(y: .value("鎖定門檻", p.lockRSSI))
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .bottom, alignment: .leading) {
                            Text("鎖定 \(p.lockRSSI)").font(.caption2).foregroundStyle(.orange)
                        }
                }
            }
            .chartXScale(domain: end.addingTimeInterval(-180)...end)
            .chartYScale(domain: -100 ... -30)
            .chartXAxis {
                AxisMarks(values: .stride(by: .minute)) {
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .chartYAxis {
                AxisMarks(values: [-100, -90, -80, -70, -60, -50, -40, -30]) {
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .chartPlotStyle { $0.clipped() }
            .frame(height: 220)
            .overlay {
                if model.samples.isEmpty {
                    Text(model.preferences.targetID == nil ? "選擇裝置後會在這裡顯示訊號" : "還沒有收到訊號")
                        .foregroundStyle(.secondary)
                }
            }
            Text("灰點是每一筆收到的訊號，線是取中位數後的結果。線要高於綠色虛線才會解鎖，低於橘色虛線一段時間就會鎖定。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
    }
}

// MARK: - 最近事件

private struct RecentEvents: View {
    let log: EventLog
    @Binding var selection: MainView.Section?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("最近的事件").font(.headline)
                Spacer()
                Button("查看全部") { selection = .history }
                    .buttonStyle(.link)
            }
            let recent = Array(log.entries.suffix(5).reversed())
            if recent.isEmpty {
                Text("還沒有事件").foregroundStyle(.secondary)
            }
            ForEach(recent) { entry in
                EventRow(entry: entry)
            }
        }
        .padding(16)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
    }
}

struct EventRow: View {
    let entry: EventLog.Entry

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: entry.kind.symbol)
                .foregroundStyle(entry.kind.tint)
                .frame(width: 18)
            Text(entry.message)
            Spacer(minLength: 12)
            Text(entry.date, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

extension EventLog.Kind {
    var tint: Color {
        switch self {
        case .locked: .orange
        case .unlocked: .green
        case .manualUnlock: .blue
        case .intruded, .unlockFailed: .red
        case .warning: .yellow
        case .info: .secondary
        }
    }
}

// MARK: - 設定清單

private struct SetupChecklist: View {
    let model: AppModel
    @Binding var selection: MainView.Section?
    @State private var showingPassword = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("還差幾步就能開始使用", systemImage: "checklist")
                .font(.headline)
            ForEach(model.pendingSetup) { item in
                row(item)
                if item != model.pendingSetup.last { Divider() }
            }
        }
        .padding(16)
        .background(.yellow.opacity(0.12), in: .rect(cornerRadius: 14))
        .sheet(isPresented: $showingPassword) { PasswordSheet(model: model) }
    }

    @ViewBuilder
    private func row(_ item: AppModel.SetupItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title(item)).fontWeight(.medium)
                Text(detail(item)).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            actions(item)
        }
    }

    private func title(_ item: AppModel.SetupItem) -> String {
        switch item {
        case .bluetooth: "允許使用藍牙"
        case .device: "選擇要監控的裝置"
        case .accessibility: "允許輔助使用"
        case .password: "設定登入密碼"
        case .legacyApp: "結束舊版 BLEUnlock"
        }
    }

    private func detail(_ item: AppModel.SetupItem) -> String {
        switch item {
        case .bluetooth: "到「系統設定 › 隱私權與安全性 › 藍牙」打開 Presence。"
        case .device: "通常是你的 iPhone 或 Apple Watch。"
        case .accessibility: "自動解鎖要模擬鍵盤輸入密碼，需要這個權限。到「系統設定 › 隱私權與安全性 › 輔助使用」打開 Presence。"
        case .password: "自動解鎖時用來輸入。會先驗證是否正確，再存進鑰匙圈。"
        case .legacyApp: "兩個 App 同時執行會互相干擾。結束前，記得在舊版的選單關掉「登入時啟動」。"
        }
    }

    @ViewBuilder
    private func actions(_ item: AppModel.SetupItem) -> some View {
        switch item {
        case .bluetooth:
            Button("打開設定") {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
                    NSWorkspace.shared.open(url)
                }
            }
        case .device:
            HStack {
                if LegacyBLEUnlock.hasSettings {
                    Button("沿用 BLEUnlock 的設定") { model.importLegacySettings() }
                }
                Button("選擇裝置") { selection = .devices }
            }
        case .accessibility:
            HStack {
                Button("請系統詢問") { Accessibility.request() }
                Button("打開設定") { Accessibility.openSettings() }
            }
        case .password:
            Button("設定密碼…") { showingPassword = true }
        case .legacyApp:
            Button("結束舊版") { model.quitLegacyApp() }
        }
    }
}
