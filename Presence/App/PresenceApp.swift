import SwiftUI
import UserNotifications

@main
struct PresenceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var model: AppModel { appDelegate.model }

    var body: some Scene {
        Window("Presence", id: "main") {
            MainView(model: model)
                .frame(minWidth: 760, minHeight: 560)
        }
        .defaultSize(width: 900, height: 640)
        // 還沒設定好就在啟動時打開主視窗，否則只待在選單列
        .defaultLaunchBehavior(model.needsAttentionAtLaunch ? .presented : .suppressed)

        MenuBarExtra {
            MenuBarMenu(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        model.start()
        if model.needsAttentionAtLaunch { NSApp.activate() }
    }

    // 選單列 App 幾乎不會在前景，仍要顯示通知
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
