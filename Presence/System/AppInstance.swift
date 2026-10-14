import AppKit

/// 同一時間只跑一個 Presence，並決定誰留下。
///
/// - launchd 依 LaunchAgent 啟動的（登入時、意外結束後），或明確要求接手的（`-PresenceTakeOver YES`），
///   會請其他的 Presence 結束，自己留下。
/// - 其他情況（例如打開了另一份拷貝）讓位：請正在跑的那個打開主視窗，自己結束。
enum AppInstance {
    static let showWindow = Notification.Name("com.chung.presence.showMainWindow")

    /// 在 App 的 init 呼叫，比任何畫面都早。回傳 false 表示這個程序應該直接結束。
    static func resolveAtLaunch() -> Bool {
        let me = ProcessInfo.processInfo.processIdentifier
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me }
        guard !others.isEmpty else { return true }

        guard LoginItem.isRunningAsAgent || UserDefaults.standard.bool(forKey: "PresenceTakeOver") else {
            DistributedNotificationCenter.default().postNotificationName(showWindow, object: nil, userInfo: nil, deliverImmediately: true)
            return false
        }
        for app in others { app.terminate() }
        waitForExit(others, timeout: 5)
        for app in others where isAlive(app) { app.forceTerminate() }
        waitForExit(others, timeout: 2)
        if let requested = UserDefaults.standard.object(forKey: handoffKey) as? Date {
            UserDefaults.standard.removeObject(forKey: handoffKey)
            // 使用者在設定頁打開「登入時自動啟動」，接手後回到同一頁
            if Date().timeIntervalSince(requested) < 30 {
                UserDefaults.standard.register(defaults: ["PresenceInitialSection": MainView.Section.general.rawValue])
            }
        }
        return true
    }

    /// 接下來會有新的 Presence 接手時，請它打開設定頁。
    static func requestWindowAfterHandoff() {
        UserDefaults.standard.set(Date(), forKey: handoffKey)
    }

    /// 開一個新的 Presence 接手，目前這個會被它結束。
    static func relaunch(_ url: URL = Bundle.main.bundleURL, arguments: [String] = []) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["-PresenceTakeOver", "YES"] + arguments
        try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    private static let handoffKey = "handoffOpenWindow"

    private static func isAlive(_ app: NSRunningApplication) -> Bool {
        kill(app.processIdentifier, 0) == 0
    }

    private static func waitForExit(_ apps: [NSRunningApplication], timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while apps.contains(where: isAlive), Date() < deadline {
            usleep(100_000)
        }
    }
}

/// 記錄上次是不是正常結束：沒有就代表當機、被系統結束或突然斷電。
enum LaunchHistory {
    private static let key = "cleanExit"

    /// 啟動時呼叫一次。回傳上次是否沒有正常結束。
    static func beginRun() -> Bool {
        let defaults = UserDefaults.standard
        let unexpected = defaults.object(forKey: key) != nil && !defaults.bool(forKey: key)
        defaults.set(false, forKey: key)
        return unexpected
    }

    static func endRun() {
        UserDefaults.standard.set(true, forKey: key)
    }
}

/// 不在「應用程式」資料夾時，從外接硬碟執行會在睡眠時被系統結束（SIGBUS），
/// 從「下載」執行則會被系統搬到隨機的唯讀位置（App Translocation），登入時也開不起來。
enum InstallLocation {
    static var isInApplications: Bool {
        let path = Bundle.main.bundleURL.standardizedFileURL.path
        return ["/Applications/", NSHomeDirectory() + "/Applications/"].contains { path.hasPrefix($0) }
    }

    /// 目前所在的資料夾，顯示用。
    static var currentFolder: String {
        Bundle.main.bundleURL.deletingLastPathComponent().path
    }

    /// 複製到 /Applications（同名的舊版會先移到垃圾桶），回傳新的位置。原本這份不刪，留給使用者處理。
    static func copyToApplications() throws -> URL {
        let fileManager = FileManager.default
        let destination = URL(fileURLWithPath: "/Applications").appendingPathComponent(Bundle.main.bundleURL.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.trashItem(at: destination, resultingItemURL: nil)
        }
        try fileManager.copyItem(at: Bundle.main.bundleURL, to: destination)
        // 從網路下載的會帶隔離標記，不拿掉的話新的這份也會被搬到隨機位置執行
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", destination.path]
        xattr.standardError = FileHandle.nullDevice
        try? xattr.run()
        xattr.waitUntilExit()
        return destination
    }
}
