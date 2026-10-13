import Foundation

/// 在座時間：裝置在附近的連續時段。用來統計每天坐了多久，以及提醒久坐。
public struct DeskTime: Sendable, Equatable, Codable {
    public struct Session: Sendable, Equatable, Codable {
        public var start: Date
        public var end: Date

        public init(start: Date, end: Date) {
            self.start = start
            self.end = end
        }

        public var duration: TimeInterval { end.timeIntervalSince(start) }
    }

    /// 離開不到這麼久就回來，視為同一段（例如去倒杯水）。
    public static let breakThreshold: TimeInterval = 3 * 60
    /// 只保留這麼多天的紀錄。
    public static let retentionDays = 60

    public private(set) var sessions: [Session] = []
    /// 目前這一段的開始時間；nil 表示現在不在座位上。
    public private(set) var currentStart: Date?
    private var lastSeenNear: Date?
    /// 本段已經提醒過的次數，避免每秒都提醒。
    public private(set) var remindersInSession = 0

    public init() {}

    /// 每次狀態更新時呼叫（建議每秒）。`near` 是目前是否判定在附近。
    public mutating func update(near: Bool, at now: Date) {
        if near {
            if currentStart == nil {
                // 短暫離開後回來：接回上一段
                if let last = sessions.last, now.timeIntervalSince(last.end) < Self.breakThreshold {
                    currentStart = last.start
                    sessions.removeLast()
                } else {
                    currentStart = now
                    remindersInSession = 0
                }
            }
            lastSeenNear = now
        } else if let start = currentStart, let last = lastSeenNear,
                  now.timeIntervalSince(last) >= Self.breakThreshold {
            // 離開夠久才結束這一段；結束時間記在最後一次在附近的時間
            sessions.append(Session(start: start, end: last))
            currentStart = nil
            prune(now: now)
        }
    }

    /// 目前這一段已經坐了多久。
    public func currentDuration(at now: Date) -> TimeInterval {
        guard let start = currentStart else { return 0 }
        return now.timeIntervalSince(start)
    }

    /// 是否該提醒久坐：每坐滿 `interval` 就提醒一次。
    public mutating func shouldRemind(every interval: TimeInterval, at now: Date) -> Bool {
        guard interval > 0, currentStart != nil else { return false }
        let due = Int(currentDuration(at: now) / interval)
        guard due > remindersInSession else { return false }
        remindersInSession = due
        return true
    }

    /// 某一天（依 calendar）坐了多久，包含進行中的這一段。
    public func total(on day: Date, calendar: Calendar, now: Date) -> TimeInterval {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return 0 }
        var all = sessions
        if let start = currentStart { all.append(Session(start: start, end: lastSeenNear ?? now)) }
        return all.reduce(0) { sum, s in
            let start = max(s.start, interval.start)
            let end = min(s.end, interval.end)
            return sum + max(0, end.timeIntervalSince(start))
        }
    }

    /// 某一天最長的一段。
    public func longestSession(on day: Date, calendar: Calendar, now: Date) -> TimeInterval {
        guard let interval = calendar.dateInterval(of: .day, for: day) else { return 0 }
        var all = sessions
        if let start = currentStart { all.append(Session(start: start, end: lastSeenNear ?? now)) }
        return all.filter { $0.end > interval.start && $0.start < interval.end }
            .map { min($0.end, interval.end).timeIntervalSince(max($0.start, interval.start)) }
            .max() ?? 0
    }

    private mutating func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Double(Self.retentionDays) * 86400)
        sessions.removeAll { $0.end < cutoff }
    }
}
