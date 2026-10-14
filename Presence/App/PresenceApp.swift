import SwiftUI
import UserNotifications

@main
struct PresenceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private var model: AppModel { appDelegate.model }

    init() {
        // 已經有 Presence 在跑：讓它打開主視窗，這個直接結束
        if !AppInstance.resolveAtLaunch() { exit(0) }
        AppInstance.installTerminationHandler()
        ProcessInfo.processInfo.automaticTerminationSupportEnabled = false
    }

    /// 指定了 -PresenceInitialSection（截圖檢查用）也會打開主視窗。
    private var opensWindowAtLaunch: Bool {
        model.needsAttentionAtLaunch || UserDefaults.standard.string(forKey: "PresenceInitialSection") != nil
    }

    var body: some Scene {
        Window("Presence", id: "main") {
            MainView(model: model)
                .frame(minWidth: 760, minHeight: 560)
        }
        .defaultSize(width: 900, height: 640)
        // 還沒設定好就在啟動時打開主視窗，否則只待在選單列
        .defaultLaunchBehavior(opensWindowAtLaunch ? .presented : .suppressed)

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
        // 另一份 Presence 被打開時，會請這裡打開主視窗
        DistributedNotificationCenter.default().addObserver(forName: AppInstance.showWindow, object: nil, queue: .main) { _ in
            NotificationCenter.default.post(name: AppInstance.showWindow, object: nil)
        }
        model.start(afterUnexpectedExit: LaunchHistory.beginRun())
        _ = Updater.shared
        if model.needsAttentionAtLaunch { NSApp.activate() }
        prepareLoginItem()
    }

    func applicationWillTerminate(_ notification: Notification) {
        LaunchHistory.endRun()
    }

    /// 在 Finder 或 Spotlight 再打開一次 Presence：打開主視窗。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NotificationCenter.default.post(name: AppInstance.showWindow, object: nil) }
        return true
    }

    private func prepareLoginItem() {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "PresenceUnregisterAgent") {
            // 使用者關掉「登入時自動啟動」：接手時已經取消註冊了（見 AppInstance.resolveAtLaunch）
        } else if defaults.bool(forKey: "PresenceReregisterAgent") {
            // 剛移到「應用程式」：用新的位置重新註冊，之後會由 launchd 啟動的 Presence 接手
            try? LoginItem.register()
        } else {
            LoginItem.migrateIfNeeded()
            // 從選單結束後又自己打開：交還給 launchd，意外結束時才會自動重開
            if LoginItem.isEnabled, !LoginItem.isRunningAsAgent, !defaults.bool(forKey: "PresenceTakeOver") {
                LoginItem.kickstart()
            }
        }
        model.refreshStatus()
    }

    // 選單列 App 幾乎不會在前景，仍要顯示通知
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
