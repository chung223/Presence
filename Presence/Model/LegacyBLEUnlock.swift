import AppKit

/// 讀取舊版 BLEUnlock（jp.sone.BLEUnlock）的設定，讓使用者一鍵沿用。密碼不匯入，要重新設定。
enum LegacyBLEUnlock {
    static let bundleID = "jp.sone.BLEUnlock"

    static var hasSettings: Bool {
        UserDefaults(suiteName: bundleID)?.string(forKey: "device") != nil
    }

    static var runningApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    /// 把舊版設定套到目前的設定上；回傳 nil 表示沒有舊版設定。
    static func imported(into base: Preferences) -> Preferences? {
        guard let old = UserDefaults(suiteName: bundleID),
              let device = old.string(forKey: "device"), let uuid = UUID(uuidString: device) else { return nil }
        var p = base
        p.targetID = uuid
        p.targetName = nil

        // 舊版用 -100 表示不鎖定、1 表示不解鎖；0 表示沒設定過
        let lock = old.integer(forKey: "lockRSSI")
        if lock == -100 { p.lockEnabled = false } else if lock != 0 { p.lockEnabled = true; p.lockRSSI = lock }
        let unlock = old.integer(forKey: "unlockRSSI")
        if unlock == 1 { p.unlockEnabled = false } else if unlock != 0 { p.unlockEnabled = true; p.unlockRSSI = unlock }
        if p.lockRSSI >= p.unlockRSSI { p.lockRSSI = p.unlockRSSI - 1 }

        let delay = old.integer(forKey: "lockDelay")
        if delay > 0 { p.lockDelay = TimeInterval(delay) }
        let timeout = old.integer(forKey: "timeout")
        if timeout > 0 { p.signalTimeout = TimeInterval(timeout) }

        p.activeMode = !old.bool(forKey: "passiveMode")
        p.lockMethod = old.bool(forKey: "screensaver") ? .screensaver : .lockScreen
        p.wakeOnProximity = old.bool(forKey: "wakeOnProximity")
        p.pauseMedia = old.bool(forKey: "pauseItunes")
        if old.bool(forKey: "wakeWithoutUnlocking") { p.unlockEnabled = false }
        return p
    }
}
