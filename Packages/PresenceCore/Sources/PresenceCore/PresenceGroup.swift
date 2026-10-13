import Foundation

/// 同時監控多台裝置（例如 iPhone 和 Apple Watch），任一台在附近就算你在。
///
/// - 每台裝置有自己的 `PresenceEngine` 和門檻（手錶的訊號通常比手機弱）。
/// - 合併狀態的優先順序：在附近 > 離開中 > 未知 > 離開。
/// - 全部都離開才回報 `.departed`；任一台回報 `.arrived` 就回報 `.arrived`。
public struct PresenceGroup: Sendable {
    public private(set) var engines: [UUID: PresenceEngine] = [:]
    private var wasAway = false

    public init(devices: [UUID: ProximitySettings] = [:], now: Date) {
        configure(devices, now: now)
    }

    /// 加入、移除或更新裝置。新加入的裝置從「未知」開始。
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
        wasAway = isAway
    }

    public func engine(for id: UUID) -> PresenceEngine? { engines[id] }

    public var presence: Presence {
        let states = engines.values.map(\.presence)
        guard states.isEmpty == false else { return .unknown }
        if states.contains(.near) { return .near }
        let leavingSince = states.compactMap { state -> Date? in
            if case .leaving(let since) = state { since } else { nil }
        }
        // 最晚開始倒數的那台決定什麼時候全部離開
        if let latest = leavingSince.max() { return .leaving(since: latest) }
        if states.contains(.unknown) { return .unknown }
        let away = states.compactMap { state -> (DepartureReason, Date)? in
            if case .away(let reason, let since) = state { (reason, since) } else { nil }
        }
        let last = away.max { $0.1 < $1.1 }!
        return .away(last.0, since: last.1)
    }

    public var canUnlock: Bool { engines.values.contains { $0.canUnlock } }

    /// 最晚開始倒數的裝置要等多久才會離開；給畫面顯示倒數用。
    public var lockDelay: TimeInterval {
        engines.values.map(\.settings.lockDelay).max() ?? 0
    }

    @discardableResult
    public mutating func record(device id: UUID, rssi: Int, at now: Date) -> PresenceChange? {
        guard engines[id] != nil else { return nil }
        let change = engines[id]?.record(rssi: rssi, at: now)
        return combine([change])
    }

    @discardableResult
    public mutating func tick(at now: Date) -> PresenceChange? {
        var changes: [PresenceChange?] = []
        for id in engines.keys {
            changes.append(engines[id]?.tick(at: now))
        }
        return combine(changes)
    }

    public mutating func reset(at now: Date) {
        for id in engines.keys {
            engines[id]?.reset(at: now)
        }
        wasAway = false
    }

    private var isAway: Bool {
        if case .away = presence { return true }
        return false
    }

    private mutating func combine(_ changes: [PresenceChange?]) -> PresenceChange? {
        let away = isAway
        defer { wasAway = away }
        if changes.contains(.arrived) { return .arrived }
        if away, !wasAway, case .away(let reason, _) = presence { return .departed(reason) }
        return nil
    }
}
