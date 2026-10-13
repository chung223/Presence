import Foundation

/// 依情境暫停自動鎖定：在信任的網路、接著電源、或不在指定時段時。
public struct ContextRules: Sendable, Equatable, Codable {
    public struct TrustedNetwork: Sendable, Equatable, Codable, Identifiable {
        /// 路由器的硬體位址。用它辨識網路，不需要定位權限（讀 Wi-Fi 名稱需要）。
        public var id: String
        public var name: String

        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    public enum Suspension: Sendable, Equatable {
        case trustedNetwork(String)
        case onACPower
        case outsideSchedule
    }

    /// 判斷時需要的外部狀態。拿不到的值用 nil，不會因此暫停。
    public struct Environment: Sendable {
        public var networkID: String?
        public var onACPower: Bool?
        public var date: Date
        public var calendar: Calendar

        public init(networkID: String?, onACPower: Bool?, date: Date, calendar: Calendar = .current) {
            self.networkID = networkID
            self.onACPower = onACPower
            self.date = date
            self.calendar = calendar
        }
    }

    public var trustedNetworks: [TrustedNetwork] = []
    public var onlyOnBattery = false
    public var scheduleEnabled = false
    /// 從午夜起算的分鐘數。開始晚於結束表示跨過午夜（例如晚班 22:00–06:00）。
    public var scheduleStart = 9 * 60
    public var scheduleEnd = 18 * 60
    /// Calendar 的星期：1 是星期日，7 是星期六。
    public var weekdays: Set<Int> = [2, 3, 4, 5, 6]
    /// 情境符合時，是否也暫停自動解鎖。
    public var alsoSuspendUnlock = false

    public init() {}

    public var isEmpty: Bool {
        trustedNetworks.isEmpty && !onlyOnBattery && !scheduleEnabled
    }

    public func suspension(in env: Environment) -> Suspension? {
        if let id = env.networkID, let network = trustedNetworks.first(where: { $0.id == id }) {
            return .trustedNetwork(network.name)
        }
        if onlyOnBattery, env.onACPower == true {
            return .onACPower
        }
        if scheduleEnabled, !isWithinSchedule(env.date, calendar: env.calendar) {
            return .outsideSchedule
        }
        return nil
    }

    public func isWithinSchedule(_ date: Date, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday, let hour = parts.hour, let minute = parts.minute else { return true }
        let now = hour * 60 + minute
        // 一天都沒選視為每天都適用，否則會變成永遠不鎖定
        let days = weekdays.isEmpty ? Set(1...7) : weekdays
        if scheduleStart == scheduleEnd { return days.contains(weekday) }
        if scheduleStart < scheduleEnd {
            return days.contains(weekday) && now >= scheduleStart && now < scheduleEnd
        }
        // 跨過午夜：午夜前算當天，午夜後算前一天開始的時段
        if now >= scheduleStart { return days.contains(weekday) }
        if now < scheduleEnd {
            let previous = weekday == 1 ? 7 : weekday - 1
            return days.contains(previous)
        }
        return false
    }
}

extension ContextRules {
    private enum CodingKeys: String, CodingKey {
        case trustedNetworks, onlyOnBattery, scheduleEnabled, scheduleStart, scheduleEnd, weekdays, alsoSuspendUnlock
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = ContextRules()
        trustedNetworks = try c.decodeIfPresent([TrustedNetwork].self, forKey: .trustedNetworks) ?? d.trustedNetworks
        onlyOnBattery = try c.decodeIfPresent(Bool.self, forKey: .onlyOnBattery) ?? d.onlyOnBattery
        scheduleEnabled = try c.decodeIfPresent(Bool.self, forKey: .scheduleEnabled) ?? d.scheduleEnabled
        scheduleStart = try c.decodeIfPresent(Int.self, forKey: .scheduleStart) ?? d.scheduleStart
        scheduleEnd = try c.decodeIfPresent(Int.self, forKey: .scheduleEnd) ?? d.scheduleEnd
        weekdays = try c.decodeIfPresent(Set<Int>.self, forKey: .weekdays) ?? d.weekdays
        alsoSuspendUnlock = try c.decodeIfPresent(Bool.self, forKey: .alsoSuspendUnlock) ?? d.alsoSuspendUnlock
    }
}
