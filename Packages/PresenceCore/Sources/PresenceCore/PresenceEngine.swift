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

public enum PresenceChange: Sendable, Equatable {
    /// 剛判定為離開：可以鎖定。
    case departed(DepartureReason)
    /// 剛回到夠近、可以解鎖的距離：可以嘗試解鎖。
    case arrived
}

/// 判斷手機在不在附近。純邏輯、不碰系統，時間一律由外部傳入。
///
/// 規則：
/// - 解鎖要看 `canUnlock`：視窗內至少有 `minimumSamples` 筆樣本，而且中位數達到解鎖門檻。
///   單筆異常的強訊號不會觸發解鎖。
/// - `.arrived` 只會在「真的離開過」之後觸發一次：訊號低於鎖定門檻、判定離開、或重設，才會重新允許。
///   這樣人在座位上自己鎖定時，訊號在門檻附近抖動不會讓它馬上解鎖。
/// - 判定離開時寧可早一點：樣本稀疏時也會倒數；判定靠近時寧可保守：一定要有足夠的樣本。
/// - `reset` 會清空所有樣本，之後必須收到新的樣本才能再解鎖，避免沿用睡眠前的狀態。
public struct PresenceEngine: Sendable {
    public private(set) var settings: ProximitySettings
    public private(set) var presence: Presence = .unknown
    public private(set) var lastSampleAt: Date?
    private var window: RSSIWindow
    private var unknownSince: Date
    private var arrivalArmed = true

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

    /// 收到一筆 RSSI。
    @discardableResult
    public mutating func record(rssi: Int, at now: Date) -> PresenceChange? {
        if RSSIWindow.isValid(rssi) {
            window.add(rssi, at: now)
            lastSampleAt = now
        }
        return evaluate(now: now)
    }

    /// 定時呼叫（建議每秒一次），處理倒數與訊號逾時。
    @discardableResult
    public mutating func tick(at now: Date) -> PresenceChange? {
        window.prune(now: now)
        return evaluate(now: now)
    }

    /// 回到「未知」並清空樣本：啟動、睡眠醒來、藍牙關閉、換裝置時呼叫。
    public mutating func reset(at now: Date) {
        window.removeAll()
        presence = .unknown
        lastSampleAt = nil
        unknownSince = now
        arrivalArmed = true
    }

    private mutating func evaluate(now: Date) -> PresenceChange? {
        let lastHeard = lastSampleAt ?? unknownSince
        if now.timeIntervalSince(lastHeard) >= settings.signalTimeout {
            arrivalArmed = true
            if case .away = presence { return nil }
            presence = .away(.signalLost, since: now)
            return .departed(.signalLost)
        }

        let median = window.median
        let enough = window.count >= settings.minimumSamples
        let departure = settings.departureThreshold

        switch presence {
        case .unknown:
            if let median, enough {
                presence = median >= departure ? .near : .leaving(since: now)
            } else if let median, median < departure,
                      now.timeIntervalSince(unknownSince) >= settings.filterWindow * 2 {
                // 樣本稀疏但都很弱：不能一直停在未知，否則永遠不會鎖定
                presence = .leaving(since: now)
            }
        case .near:
            if let median, median < departure { presence = .leaving(since: now) }
        case .leaving(let since):
            if let median, median >= departure {
                presence = .near
            } else if now.timeIntervalSince(since) >= settings.lockDelay {
                // 視窗內沒有樣本也照樣倒數：收不到強訊號就是還在離開
                presence = .away(.weakSignal, since: now)
                arrivalArmed = true
                return .departed(.weakSignal)
            }
        case .away:
            // 離開後要回到解鎖門檻以上才算回來（遲滯），不是只超過鎖定門檻
            if let median, enough, median >= settings.arrivalThreshold { presence = .near }
        }

        if let median, median < departure { arrivalArmed = true }
        if arrivalArmed, canUnlock {
            arrivalArmed = false
            return .arrived
        }
        return nil
    }
}
