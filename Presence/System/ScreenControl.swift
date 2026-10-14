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
        guard !Demo.isActive, let lock = lockFunction else { return false }
        return lock() == 0
    }

    static func startScreensaver() {
        if Demo.isActive { return }
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/ScreenSaverEngine.app")
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    /// 舊版用的 IODisplayWrangler 在 Apple Silicon 上無效，改用 pmset。
    static func sleepDisplay() {
        if Demo.isActive { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        try? process.run()
    }

    static func wakeDisplay() {
        if Demo.isActive { return }
        var id: IOPMAssertionID = 0
        if IOPMAssertionDeclareUserActivity("Presence" as CFString, kIOPMUserActiveLocal, &id) == kIOReturnSuccess {
            IOPMAssertionRelease(id)
        }
    }

    private static var awakeAssertion: IOPMAssertionID = 0
    private static var awakeRelease: Task<Void, Never>?

    /// 自動解鎖前後讓螢幕保持亮著。`wakeDisplay` 只宣告「剛剛有人操作」，效果只有幾秒；
    /// 你還沒碰鍵盤滑鼠前，系統會照閒置計時讓螢幕變暗，設了「螢幕變暗就要密碼」就又鎖住
    /// （2026-10-14 實測：手錶解開 5 秒後又鎖定）。時間到或再呼叫一次就延長。
    static func keepDisplayAwake(for seconds: TimeInterval) {
        if Demo.isActive { return }
        if awakeAssertion == 0 {
            let created = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                      IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                      "Presence: just unlocked, waiting for you to sit down" as CFString,
                                                      &awakeAssertion)
            if created != kIOReturnSuccess { awakeAssertion = 0 }
        }
        awakeRelease?.cancel()
        awakeRelease = Task {
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            releaseDisplayAwake()
        }
    }

    static func releaseDisplayAwake() {
        awakeRelease?.cancel()
        awakeRelease = nil
        guard awakeAssertion != 0 else { return }
        IOPMAssertionRelease(awakeAssertion)
        awakeAssertion = 0
    }
}
