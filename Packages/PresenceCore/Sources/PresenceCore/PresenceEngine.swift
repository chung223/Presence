import Foundation

public enum DepartureReason: String, Sendable, Codable {
    /// 訊號持續低於鎖定門檻
    case weakSignal
    /// 完全收不到訊號
    case signalLost
}

public enum Presence: Sendable, Equatable {
    /// 剛啟動、睡眠醒來、藍牙關閉或換了裝置：還沒有足夠的新樣本。
    case unknown
    case near
    /// 訊號低於鎖定門檻，倒數中。
    case leaving(since: Date)
    case away(DepartureReason, since: Date)
}

/// 判斷手機在不在附近。純邏輯、不碰系統，時間一律由外部傳入。
///
/// 規則：
/// - 鎖定看 `presence` 變成 `.away` 的那一刻（`handle` 回傳 departure）。
/// - 解鎖看 `canUnlock`：視窗內至少有 `minimumSamples` 筆樣本，而且中位數達到解鎖門檻。
///   單筆異常的強訊號不會觸發解鎖。
/// - `reset` 會清空所有樣本，之後必須收到新的樣本才能再解鎖，避免沿用睡眠前的狀態。
public struct PresenceEngine: Sendable {
    public private(set) var settings: ProximitySettings
    public private(set) var presence: Presence = .unknown
    public private(set) var lastSampleAt: Date?
    private var window: RSSIWindow
    private var unknownSince: Date

    public init(settings: ProximitySettings = .default, now: Date) {
        let s = settings.normalized()
        self.settings = s
        self.window = RSSIWindow(duration: s.filterWindow)
        self.unknownSince = now
    }

    /// 濾波後的訊號強度；視窗內沒有樣本時是 nil。
    public var smoothedRSSI: Int? { window.median }

    public var sampleCount: Int { window.count }

    /// 證據足以解鎖：樣本夠多、而且中位數達到解鎖門檻。
    public var canUnlock: Bool {
        guard settings.unlockRSSI != nil, let median = window.median else { return false }
        return window.count >= settings.minimumSamples && median >= settings.arrivalThreshold
    }

    public mutating func update(settings newSettings: ProximitySettings) {
        let s = newSettings.normalized()
        settings = s
        window.duration = s.filterWindow
    }

    /// 收到一筆 RSSI。回傳非 nil 表示剛剛判定為離開。
    @discardableResult
    public mutating func record(rssi: Int, at now: Date) -> DepartureReason? {
        guard RSSIWindow.isValid(rssi) else { return evaluate(now: now) }
        window.add(rssi, at: now)
        lastSampleAt = now
        return evaluate(now: now)
    }

    /// 定時呼叫（建議每秒一次），處理倒數與訊號逾時。
    @discardableResult
    public mutating func tick(at now: Date) -> DepartureReason? {
        window.prune(now: now)
        return evaluate(now: now)
    }

    /// 回到「未知」並清空樣本：啟動、睡眠醒來、藍牙關閉、換裝置時呼叫。
    public mutating func reset(at now: Date) {
        window.removeAll()
        presence = .unknown
        lastSampleAt = nil
        unknownSince = now
    }

    private mutating func evaluate(now: Date) -> DepartureReason? {
        let lastHeard = lastSampleAt ?? unknownSince
        if now.timeIntervalSince(lastHeard) >= settings.signalTimeout {
            if case .away = presence { return nil }
            presence = .away(.signalLost, since: now)
            return .signalLost
        }

        guard let median = window.median else { return nil }
        let enough = window.count >= settings.minimumSamples
        let above = median >= settings.departureThreshold

        switch presence {
        case .unknown:
            guard enough else { return nil }
            presence = above ? .near : .leaving(since: now)
        case .near:
            if !above { presence = .leaving(since: now) }
        case .leaving(let since):
            if above {
                presence = .near
            } else if now.timeIntervalSince(since) >= settings.lockDelay {
                presence = .away(.weakSignal, since: now)
                return .weakSignal
            }
        case .away:
            // 離開後要回到解鎖門檻以上才算回來（遲滯），不是只超過鎖定門檻
            if enough, median >= settings.arrivalThreshold { presence = .near }
        }
        return nil
    }
}
