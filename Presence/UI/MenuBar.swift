import SwiftUI

struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        Image(systemName: model.status.symbol)
    }
}

struct MenuBarMenu: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(headline)
        if model.isPaused, let until = model.automation.pausedUntil {
            Text("暫停到 \(until.formatted(date: .omitted, time: .shortened))")
        }
        Divider()
        Button("立即鎖定") { model.lockNow() }
            .keyboardShortcut("l")
        if model.isPaused {
            Button("恢復自動鎖定與解鎖") { model.resume() }
        } else {
            Menu("暫停") {
                Button("15 分鐘") { model.pause(for: 15 * 60) }
                Button("1 小時") { model.pause(for: 60 * 60) }
                Button("4 小時") { model.pause(for: 4 * 60 * 60) }
            }
        }
        Divider()
        Button("打開 Presence…") {
            openWindow(id: "main")
            NSApp.activate()
        }
        .keyboardShortcut(",")
        Divider()
        Button("結束 Presence") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var headline: String {
        let status = model.status
        guard model.preferences.targetID != nil else { return status.title }
        let rssi = model.engine.smoothedRSSI.map { " · \($0) dBm" } ?? ""
        return "\(model.targetDisplayName)：\(status.title)\(rssi)"
    }
}
