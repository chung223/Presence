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
        guard !Demo.isActive, let url, isInstalled else { return false }
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

/// 登入時啟動，而且意外結束（當機、被系統結束）時由 launchd 自動重新開啟；從選單結束則不會。
///
/// 用 App 內附的 LaunchAgent（Contents/Library/LaunchAgents）而不是一般的登入項目：
/// 登入項目只在登入時開一次，Presence 在睡眠時被系統結束就不會再回來。
enum LoginItem {
    static let agentLabel = "com.chung.presence.agent"
    private static var agent: SMAppService { SMAppService.agent(plistName: "\(agentLabel).plist") }

    static var status: SMAppService.Status { agent.status }

    static var isEnabled: Bool { status == .enabled }

    /// 目前這個程序是不是 launchd 依 LaunchAgent 啟動的。
    static var isRunningAsAgent: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == agentLabel
    }

    /// 註冊後 launchd 會立刻啟動一個新的 Presence，由它接手（見 `AppInstance`）。
    static func register() throws {
        if SMAppService.mainApp.status == .enabled { try? SMAppService.mainApp.unregister() }
        try agent.register()
    }

    /// 注意：取消註冊會連同 launchd 啟動的那個程序一起結束。
    static func unregister() throws {
        try agent.unregister()
    }

    /// 0.1 版用的是一般登入項目，改成 LaunchAgent。只在「應用程式」資料夾裡做，
    /// 否則 launchd 會記住外接硬碟或「下載」裡的位置。
    static func migrateIfNeeded() {
        guard InstallLocation.isInApplications, SMAppService.mainApp.status == .enabled else { return }
        try? SMAppService.mainApp.unregister()
        try? agent.register()
    }

    /// 已註冊但沒在跑（例如使用者從選單結束後又自己打開）：請 launchd 啟動，讓它接手。
    @discardableResult
    static func kickstart() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["kickstart", "gui/\(getuid())/\(agentLabel)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// 換過 App 之後（自己拖新版進來、或 Sparkle 更新），背景項目管理會把登記作廢，launchd 卻還指著
    /// 舊的程式，一直啟動失敗（2026-10-14 實測：invalidateLaunchItem 之後 spawn scheduled、
    /// 「Could not find and/or execute program」）。重新登記也只會沿用舊的那筆，
    /// 要先把 launchd 的工作移除。重新登記後 launchd 會啟動新的那份，由它接手。
    static func repair() {
        let bootout = Process()
        bootout.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        bootout.arguments = ["bootout", "gui/\(getuid())/\(agentLabel)"]
        bootout.standardOutput = FileHandle.nullDevice
        bootout.standardError = FileHandle.nullDevice
        try? bootout.run()
        bootout.waitUntilExit()
        try? agent.unregister()
        try? agent.register()
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
        if Demo.isActive { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    static func remove(id: String) {
        if Demo.isActive { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [id])
    }
}
