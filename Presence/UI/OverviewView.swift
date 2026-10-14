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
                if model.preferences.devices.isEmpty {
                    SignalChart(model: model, device: nil)
                }
                ForEach(model.preferences.devices) { device in
                    SignalChart(model: model, device: device)
                }
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
        case .suspended, .lockPending: .orange
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
                Text(title)
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
            .disabled(!model.hasDevices)
        }
        .padding(16)
        .background(.background.secondary, in: .rect(cornerRadius: 14))
    }

    private var title: String {
        let status = model.status
        guard model.hasDevices else { return status.title }
        if status == .near {
            return String(localized: "\(AppModel.list(model.nearDeviceNames)) 在附近")
        }
        return "\(model.subject) \(status.title)"
    }

    private var detail: String {
        if case .paused(let until) = model.status {
            return String(localized: "自動鎖定與解鎖暫停到 \(until.formatted(date: .omitted, time: .shortened))")
        }
        let p = model.preferences
        var parts = p.devices.map { device in
            let rssi = model.smoothedRSSI(for: device.id).map { "\($0) dBm" } ?? String(localized: "沒有訊號")
            return "\(device.displayName) \(rssi)"
        }
        if !p.lockEnabled { parts.append(String(localized: "不自動鎖定")) }
        if !p.unlockEnabled { parts.append(String(localized: "不自動解鎖")) }
        parts.append(p.activeMode ? String(localized: "主動模式") : String(localized: "被動模式"))
        if model.automation.manualHold { parts.append(String(localized: "手動鎖定中")) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 訊號圖

private struct SignalChart: View {
    let model: AppModel
    let device: MonitoredDevice?

    var body: some View {
        let p = model.preferences
        let end = model.now
        let samples = device.flatMap { model.samples[$0.id] } ?? []
        let smoothed = device.flatMap { model.smoothed[$0.id] } ?? []
        VStack(alignment: .leading, spacing: 8) {
            Text(device.map { String(localized: "\($0.displayName)：最近 3 分鐘的訊號") } ?? String(localized: "最近 3 分鐘的訊號")).font(.headline)
            Chart {
                ForEach(samples) { point in
                    PointMark(x: .value("時間", point.date), y: .value("RSSI", point.rssi))
                        .symbolSize(10)
                        .foregroundStyle(.secondary.opacity(0.35))
                }
                ForEach(smoothed) { point in
                    LineMark(x: .value("時間", point.date), y: .value("濾波後", point.rssi))
                        .interpolationMethod(.monotone)
                        .foregroundStyle(.tint)
                }
                if let device, p.unlockEnabled {
                    RuleMark(y: .value("解鎖門檻", device.unlockRSSI))
                        .foregroundStyle(.green)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .top, alignment: .leading) {
                            Text("解鎖 \(device.unlockRSSI)").font(.caption2).foregroundStyle(.green)
                        }
                }
                if let device, p.lockEnabled {
                    RuleMark(y: .value("鎖定門檻", device.lockRSSI))
                        .foregroundStyle(.orange)
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .annotation(position: .bottom, alignment: .leading) {
                            Text("鎖定 \(device.lockRSSI)").font(.caption2).foregroundStyle(.orange)
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
            .frame(height: 200)
            .overlay {
                if samples.isEmpty {
                    Text(device == nil ? String(localized: "加入裝置後會在這裡顯示訊號") : String(localized: "還沒有收到訊號"))
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
        case .intruded: .orange
        case .unlockFailed: .red
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
    @State private var moving = false
    @State private var moveError: String?

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
        case .bluetooth: String(localized: "允許使用藍牙")
        case .device: String(localized: "選擇要監控的裝置")
        case .accessibility: String(localized: "允許輔助使用")
        case .password: String(localized: "設定登入密碼")
        case .legacyApp: String(localized: "結束舊版 BLEUnlock")
        case .location: String(localized: "移到「應用程式」資料夾")
        }
    }

    private func detail(_ item: AppModel.SetupItem) -> String {
        switch item {
        case .bluetooth: String(localized: "到「系統設定 › 隱私權與安全性 › 藍牙」打開 Presence。")
        case .device: String(localized: "通常是你的 iPhone，也可以再加上 Apple Watch。")
        case .accessibility: String(localized: "自動解鎖要模擬鍵盤輸入密碼，需要這個權限。到「系統設定 › 隱私權與安全性 › 輔助使用」打開 Presence。")
        case .password: String(localized: "自動解鎖時用來輸入。會先驗證是否正確，再存進鑰匙圈。")
        case .legacyApp: String(localized: "兩個 App 同時執行會互相干擾。結束前，記得在舊版的選單關掉「登入時啟動」。")
        case .location:
            moveError ?? String(localized: "Presence 目前在「\(InstallLocation.currentFolder)」。不在「應用程式」資料夾時，Mac 睡眠後可能被系統結束，登入時也可能開不起來。")
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
        case .location:
            Button("移過去並重新開啟") {
                moving = true
                Task {
                    moveError = await model.moveToApplications()
                    moving = false
                }
            }
            .disabled(moving)
        }
    }
}
