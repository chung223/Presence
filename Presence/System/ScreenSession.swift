import AppKit
import Observation

/// 追蹤螢幕鎖定、螢幕開關、系統睡眠與使用者切換。
@Observable
final class ScreenSession {
    enum Event {
        case locked, unlocked
        case displaySlept, displayWoke
        case systemWillSleep, systemDidWake
        case sessionResigned, sessionActivated
    }

    private(set) var isLocked = ScreenSession.queryLocked() ?? false
    private(set) var isDisplayAsleep = CGDisplayIsAsleep(CGMainDisplayID()) != 0
    private(set) var isSystemSleeping = false
    private(set) var isSessionActive = true

    @ObservationIgnored var onEvent: ((Event) -> Void)?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    /// 鎖定時 session 字典才有 CGSSessionScreenIsLocked = 1（在 macOS 26.7 驗證過）。
    /// 拿不到 session 字典時回傳 nil（狀態未知），呼叫端不要把它當成「沒鎖定」。
    nonisolated static func queryLocked() -> Bool? {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return nil }
        return (dict["CGSSessionScreenIsLocked"] as? NSNumber)?.boolValue ?? false
    }

    static var loginWindowIsFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.loginwindow"
    }

    func start() {
        let ws = NSWorkspace.shared.notificationCenter
        observe(ws, NSWorkspace.screensDidSleepNotification) { $0.isDisplayAsleep = true; return .displaySlept }
        observe(ws, NSWorkspace.screensDidWakeNotification) { $0.isDisplayAsleep = false; return .displayWoke }
        observe(ws, NSWorkspace.willSleepNotification) { $0.isSystemSleeping = true; return .systemWillSleep }
        observe(ws, NSWorkspace.didWakeNotification) { $0.isSystemSleeping = false; return .systemDidWake }
        observe(ws, NSWorkspace.sessionDidResignActiveNotification) { $0.isSessionActive = false; return .sessionResigned }
        observe(ws, NSWorkspace.sessionDidBecomeActiveNotification) { $0.isSessionActive = true; return .sessionActivated }

        // 鎖定／解鎖的通知任何程式都能發，而且常比 session 字典早到。
        // 所以只拿它當「該檢查了」的提示，實際狀態一律以 session 字典為準。
        let dnc = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked"] {
            let token = dnc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshSoon() }
            }
            observers.append((dnc, token))
        }
    }

    /// 以 session 字典為準更新鎖定狀態；有變化就發出事件。也會定時呼叫，以防通知漏接。
    func refresh() {
        guard isSessionActive, let locked = Self.queryLocked(), locked != isLocked else { return }
        isLocked = locked
        onEvent?(locked ? .locked : .unlocked)
    }

    private func refreshSoon() {
        refresh()
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            refresh()
            try? await Task.sleep(for: .milliseconds(700))
            refresh()
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ apply: @escaping @MainActor (ScreenSession) -> Event) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let event = apply(self)
                self.onEvent?(event)
            }
        }
        observers.append((center, token))
    }
}
