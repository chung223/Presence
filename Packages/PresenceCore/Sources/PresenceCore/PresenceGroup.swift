import Foundation

/// 同時監控多台裝置（例如 iPhone 和 Apple Watch）。
///
/// - 每台裝置有自己的 `PresenceEngine` 和門檻（手錶的訊號通常比手機弱）。
/// - `.anyNear`（預設）：任一台在附近就算你在，全部離開才鎖。
///   合併狀態的優先順序：在附近 > 離開中 > 未知 > 離開。
/// - `.allNear`：每一台都要在附近，任一台離開就鎖。
///   優先順序反過來：離開 > 離開中 > 未知 > 在附近。
/// - 「走回來」以整組為準：整組判定離開過（或重設）之後，第一次證據足以解鎖時回報一次。
///   某一台在門檻附近抖動不會讓已經在座位上的你被解鎖。
public struct PresenceGroup: Sendable {
    public enum Policy: String, Sendable, Codable, CaseIterable {
        case anyNear
        case allNear
    }

    public private(set) var engines: [UUID: PresenceEngine] = [:]
    public var policy: Policy
    private var wasAway = false
    private var arrivalArmed = true

    public init(devices: [UUID: ProximitySettings] = [:], policy: Policy = .anyNear, now: Date) {
        self.policy = policy
        configure(devices, now: now)
    }

    /// 加入、移除或更新裝置。新加入的裝置從「未知」開始。
    /// 這裡刻意不更新 `wasAway`：移除裝置後如果整組變成離開，下一次更新就要回報離開。
    public mutating func configure(_ devices: [UUID: ProximitySettings], now: Date) {
        for id in engines.keys where devices[id] == nil {
            engines[id] = nil
        }
        for (id, settings) in devices {
            if engines[id] == nil {
                engines[id] = PresenceEngine(settings: settings, now: now)
            } else {
                engines[id]?.update(settings: settings)
            }
        }
    }

    public func engine(for id: UUID) -> PresenceEngine? { engines[id] }

    public var presence: Presence {
        let states = engines.values.map(\.presence)
        guard states.isEmpty == false else { return .unknown }
        let leavingSince = states.compactMap { state -> Date? in
            if case .leaving(let since) = state { since } else { nil }
        }
        let away = states.compactMap { state -> (DepartureReason, Date)? in
            if case .away(let reason, let since) = state { (reason, since) } else { nil }
        }

        switch policy {
        case .anyNear:
            if states.contains(.near) { return .near }
            // 最晚開始倒數的那台決定什麼時候全部離開
            if let latest = leavingSince.max() { return .leaving(since: latest) }
            if states.contains(.unknown) { return .unknown }
            let last = away.max { $0.1 < $1.1 }!
            return .away(last.0, since: last.1)
        case .allNear:
            // 最早離開的那台就是整組離開的時間
            if let first = away.min(by: { $0.1 < $1.1 }) { return .away(first.0, since: first.1) }
            if let earliest = leavingSince.min() { return .leaving(since: earliest) }
            if states.contains(.unknown) { return .unknown }
            return .near
        }
    }

    public var canUnlock: Bool {
        guard engines.isEmpty == false else { return false }
        switch policy {
        case .anyNear: return engines.values.contains { $0.canUnlock }
        case .allNear: return engines.values.allSatisfy { $0.canUnlock }
        }
    }

    /// 最晚開始倒數的裝置要等多久才會離開；給畫面顯示倒數用。
    public var lockDelay: TimeInterval {
        engines.values.map(\.settings.lockDelay).max() ?? 0
    }

    @discardableResult
    public mutating func record(device id: UUID, rssi: Int, at now: Date) -> PresenceChange? {
        guard engines[id] != nil else { return nil }
        engines[id]?.record(rssi: rssi, at: now)
        return combine()
    }

    @discardableResult
    public mutating func tick(at now: Date) -> PresenceChange? {
        for id in engines.keys {
            engines[id]?.tick(at: now)
        }
        return combine()
    }

    public mutating func reset(at now: Date) {
        for id in engines.keys {
            engines[id]?.reset(at: now)
        }
        wasAway = false
        arrivalArmed = true
    }

    private mutating func combine() -> PresenceChange? {
        let current = presence
        let away: Bool
        if case .away = current { away = true } else { away = false }
        defer { wasAway = away }

        if away {
            arrivalArmed = true
            if !wasAway, case .away(let reason, _) = current { return .departed(reason) }
            return nil
        }
        if arrivalArmed, canUnlock {
            arrivalArmed = false
            return .arrived
        }
        return nil
    }
}
