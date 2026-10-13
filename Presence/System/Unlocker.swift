import AppKit

/// 用模擬鍵盤輸入密碼來解鎖。流程在 macOS 26.7 驗證過（見 docs/macos26-findings.md）：
/// 喚醒螢幕 → 等螢幕亮 → 再等 0.5 秒 → 打密碼 → 按 Enter（keycode 52）。
///
/// 防止密碼打進別的視窗：每送一段字元前、按 Enter 前，都確認仍是鎖定且前景是 loginwindow。
/// 只要使用者在這期間用 Touch ID 或 Apple Watch 解鎖，就立刻停止。
enum Unlocker {
    enum Outcome: Equatable {
        case unlocked
        case notLocked
        case noAccessibility
        case displayDidNotWake
        case interrupted
        case stillLocked
    }

    static func unlock(with password: String) async -> Outcome {
        guard ScreenSession.queryLocked() else { return .notLocked }
        guard AXIsProcessTrusted() else { return .noAccessibility }

        // 螢幕保護程式在跑時，鎖定畫面在它後面。不能送 Esc（macOS 26 會直接關螢幕），改成結束它。
        if let saver = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.ScreenSaver.Engine").first {
            saver.terminate()
            try? await Task.sleep(for: .seconds(1))
        }

        // 鎖定約 5 秒後系統會自己關螢幕，螢幕關著時打字無效，所以一律先喚醒
        ScreenControl.wakeDisplay()
        let awake = await waitUntil(timeout: 3) { CGDisplayIsAsleep(CGMainDisplayID()) == 0 }
        guard awake else { return .displayDidNotWake }
        try? await Task.sleep(for: .milliseconds(500))

        guard type(password, while: isSafeToType) else { return .interrupted }
        let unlocked = await waitUntil(timeout: 5) { ScreenSession.queryLocked() == false }
        return unlocked ? .unlocked : .stillLocked
    }

    static func isSafeToType() -> Bool {
        ScreenSession.queryLocked() && ScreenSession.loginWindowIsFrontmost
    }

    /// 每段最多 20 個 UTF-16 字元（單一鍵盤事件的上限）。
    private static func type(_ text: String, while isSafe: () -> Bool) -> Bool {
        let source = CGEventSource(stateID: .hidSystemState)
        let units = Array(text.utf16)
        for start in stride(from: 0, to: units.count, by: 20) {
            guard isSafe() else { return false }
            var chunk = Array(units[start..<min(start + 20, units.count)])
            let down = CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            down?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: source, virtualKey: 49, keyDown: false)?.post(tap: .cghidEventTap)
        }
        guard isSafe() else { return false }
        CGEvent(keyboardEventSource: source, virtualKey: 52, keyDown: true)?.post(tap: .cghidEventTap)
        CGEvent(keyboardEventSource: source, virtualKey: 52, keyDown: false)?.post(tap: .cghidEventTap)
        return true
    }

    private static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }
}
