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

    private(set) var isLocked = ScreenSession.queryLocked()
    private(set) var isDisplayAsleep = false
    private(set) var isSystemSleeping = false
    private(set) var isSessionActive = true

    @ObservationIgnored var onEvent: ((Event) -> Void)?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    /// 鎖定時 session 字典才有 CGSSessionScreenIsLocked = 1（在 macOS 26.7 驗證過）。
    nonisolated static func queryLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
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

        let dnc = DistributedNotificationCenter.default()
        observe(dnc, Notification.Name("com.apple.screenIsLocked")) { $0.isLocked = true; return .locked }
        observe(dnc, Notification.Name("com.apple.screenIsUnlocked")) { $0.isLocked = false; return .unlocked }
    }

    /// 通知可能漏接，定時再對一次實際狀態。
    func refresh() {
        let locked = Self.queryLocked()
        guard locked != isLocked else { return }
        isLocked = locked
        onEvent?(locked ? .locked : .unlocked)
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
