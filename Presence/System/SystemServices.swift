import AppKit
import ServiceManagement
import UserNotifications

/// 鎖定或解鎖時執行使用者自己的腳本：
/// ~/Library/Application Scripts/com.chung.presence/event <事件> [RSSI]
/// 事件名稱沿用 BLEUnlock：away、lost、unlocked、intruded。
enum EventScript {
    enum Event: String {
        case away, lost, unlocked, intruded
    }

    static var directory: URL? {
        try? FileManager.default.url(for: .applicationScriptsDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    }

    static var url: URL? { directory?.appendingPathComponent("event") }

    static var isInstalled: Bool {
        guard let url else { return false }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    @discardableResult
    static func run(_ event: Event, rssi: Int?) -> Bool {
        guard let url, isInstalled else { return false }
        let process = Process()
        process.executableURL = url
        process.arguments = [event.rawValue] + (rssi.map { [String($0)] } ?? [])
        do {
            try process.run()
            return true
        } catch {
            return false
        }
    }
}

enum LoginItem {
    static var status: SMAppService.Status { SMAppService.mainApp.status }

    static var isEnabled: Bool { status == .enabled }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    static func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}

enum Accessibility {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 請系統顯示權限對話框（只會在還沒授權時出現）。
    static func request() {
        let key = "AXTrustedCheckOptionPrompt" // kAXTrustedCheckOptionPrompt 是全域變數，Swift 6 不允許直接取用
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

enum Notifier {
    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    static func post(_ title: String, _ body: String, id: String = UUID().uuidString) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    static func remove(id: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }
}
