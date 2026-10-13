import Foundation

/// 決定什麼時候真的要鎖定或嘗試解鎖：手動鎖定、暫停、解鎖失敗次數都在這裡處理。
public struct Automation: Sendable, Equatable {
    /// 連續失敗幾次後停止自動解鎖，直到使用者手動解鎖一次（避免密碼錯誤累積）。
    public static let maximumFailures = 2
    /// 兩次解鎖嘗試之間至少間隔幾秒。
    public static let attemptCooldown: TimeInterval = 10

    /// 使用者按了「立即鎖定」：要等離開夠久再回來才自動解鎖。
    public private(set) var manualHold = false
    public private(set) var failures = 0
    public private(set) var pausedUntil: Date?
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

    public mutating func didLockManually() {
        manualHold = true
    }

    /// 每次狀態更新時呼叫：離開超過 `rearm` 秒，就解除手動鎖定的保留。
    public mutating func observe(_ presence: Presence, rearm: TimeInterval, at now: Date) {
        if case .away(_, let since) = presence, now.timeIntervalSince(since) >= rearm {
            manualHold = false
        }
    }

    /// 螢幕被解鎖（不論是誰解的）：清除保留與失敗次數。
    public mutating func screenDidUnlock() {
        manualHold = false
        failures = 0
        lastAttemptAt = nil
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

    public mutating func unlockAttemptFailed() {
        failures += 1
    }
}
