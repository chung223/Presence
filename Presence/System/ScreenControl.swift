import AppKit
import IOKit.pwr_mgt

/// 鎖定、螢幕保護程式、關閉與喚醒螢幕。私有 API 只集中在這裡。
enum ScreenControl {
    private typealias LockFunction = @convention(c) () -> Int32

    /// login.framework 的 SACLockScreenImmediate（私有 API，在 macOS 26.7 驗證過）。
    private static let lockFunction: LockFunction? = {
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        guard let handle = dlopen(path, RTLD_LAZY), let sym = dlsym(handle, "SACLockScreenImmediate") else { return nil }
        return unsafeBitCast(sym, to: LockFunction.self)
    }()

    @discardableResult
    static func lockScreen() -> Bool {
        guard let lock = lockFunction else { return false }
        return lock() == 0
    }

    static func startScreensaver() {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    /// 舊版用的 IODisplayWrangler 在 Apple Silicon 上無效，改用 pmset。
    static func sleepDisplay() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        try? process.run()
    }

    static func wakeDisplay() {
        var id: IOPMAssertionID = 0
        if IOPMAssertionDeclareUserActivity("Presence" as CFString, kIOPMUserActiveLocal, &id) == kIOReturnSuccess {
            IOPMAssertionRelease(id)
        }
    }
}
