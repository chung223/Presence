import Foundation

/// 決定什麼時候真的要鎖定或嘗試解鎖：手動鎖定、暫停、解鎖失敗次數都在這裡處理。
public struct Automation: Sendable, Equatable {
    /// 連續失敗幾次後停止自動解鎖，直到重新設定密碼或手動恢復（避免密碼錯誤一直累積）。
    public static let maximumFailures = 2
    /// 兩次解鎖嘗試之間至少間隔幾秒。
    public static let attemptCooldown: TimeInterval = 10

    /// 使用者按了「立即鎖定」：要等離開夠久再回來才自動解鎖。
    public private(set) var manualHold = false
    /// 連續失敗次數。只有自動解鎖成功或使用者重設才歸零；手動解鎖不算，
    /// 否則密碼過期時每次鎖定都會再錯兩次。
    public private(set) var failures = 0
    public private(set) var pausedUntil: Date?
    private var manualLockAt: Date?
    private var lastAttemptAt: Date?

    public init() {}

    public func isPaused(at now: Date) -> Bool {
        guard let until = pausedUntil else { return false }
        return now < until
    }

    public var isBlockedByFailures: Bool { failures >= Self.maximumFailures }

    public mutating func pause(until date: Date?) {
        pausedUntil = date
    }

    public mutating func didLockManually(at now: Date) {
        manualHold = true
        manualLockAt = now
    }

    /// 每次狀態更新時呼叫：從手動鎖定之後算起，離開超過 `rearm` 秒，就解除保留。
    public mutating func observe(_ presence: Presence, rearm: TimeInterval, at now: Date) {
        guard manualHold, case .away(_, let since) = presence else { return }
        let start = max(since, manualLockAt ?? since)
        if now.timeIntervalSince(start) >= rearm {
            manualHold = false
        }
    }

    /// 螢幕被解鎖（不論是誰解的）：清除手動鎖定的保留。
    public mutating func screenDidUnlock() {
        manualHold = false
        manualLockAt = nil
        lastAttemptAt = nil
    }

    public mutating func unlockSucceeded() {
        failures = 0
    }

    public mutating func unlockAttemptFailed() {
        failures += 1
    }

    /// 使用者重新設定密碼或手動恢復自動解鎖。
    public mutating func resetFailures() {
        failures = 0
    }

    public func shouldLock(lockEnabled: Bool, screenLocked: Bool, at now: Date) -> Bool {
        lockEnabled && !screenLocked && !isPaused(at: now)
    }

    public func shouldAttemptUnlock(canUnlock: Bool, screenLocked: Bool, at now: Date) -> Bool {
        guard canUnlock, screenLocked, !manualHold, !isPaused(at: now), !isBlockedByFailures else { return false }
        if let last = lastAttemptAt, now.timeIntervalSince(last) < Self.attemptCooldown { return false }
        return true
    }

    public mutating func didAttemptUnlock(at now: Date) {
        lastAttemptAt = now
    }
}
