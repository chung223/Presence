import SwiftUI

struct MenuBarLabel: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: model.menuBarSymbol)
            // 選單列圖示一直都在，由它負責在需要時打開主視窗（見 AppInstance.showWindow）
            .onReceive(NotificationCenter.default.publisher(for: AppInstance.showWindow)) { _ in
                openWindow(id: "main")
                NSApp.activate()
            }
    }
}

struct MenuBarMenu: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(headline)
        if model.isPaused, let until = model.automation.pausedUntil {
            Text("暫停到 \(until.formatted(date: .omitted, time: .shortened))")
        }
        // 只有一台裝置時，第一行已經有訊號強度
        if model.preferences.devices.count > 1 {
            ForEach(model.preferences.devices) { device in
                Text(model.smoothedRSSI(for: device.id).map { "\(device.displayName)：\($0) dBm" }
                     ?? String(localized: "\(device.displayName)：沒有訊號"))
            }
        }
        if model.hasDevices {
            Text("今天在座 \(DeskTimeView.format(model.deskTime.total(on: model.now, calendar: .current, now: model.now)))")
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
        Toggle("離開時自動鎖定", isOn: $model.preferences.lockEnabled)
        Toggle("回來時自動解鎖", isOn: $model.preferences.unlockEnabled)
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

    private var headline: String { model.statusLine }
}
