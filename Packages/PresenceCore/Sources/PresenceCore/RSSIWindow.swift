import Foundation

/// 保留一段時間內的 RSSI 樣本，取中位數。中位數不會被單筆異常的強訊號拉高。
public struct RSSIWindow: Sendable, Equatable {
    public struct Sample: Sendable, Equatable {
        public let rssi: Int
        public let at: Date
    }

    public var duration: TimeInterval
    public private(set) var samples: [Sample] = []

    public init(duration: TimeInterval) {
        self.duration = duration
    }

    /// RSSI 必須是負值；0 或正值、以及 -127（無法取得）都不是有效讀數。
    public static func isValid(_ rssi: Int) -> Bool {
        rssi < 0 && rssi > -127
    }

    public mutating func add(_ rssi: Int, at date: Date) {
        guard Self.isValid(rssi) else { return }
        samples.append(Sample(rssi: rssi, at: date))
        prune(now: date)
    }

    public mutating func prune(now: Date) {
        samples.removeAll { now.timeIntervalSince($0.at) > duration }
    }

    public mutating func removeAll() {
        samples.removeAll()
    }

    public var count: Int { samples.count }

    public var latest: Sample? { samples.last }

    public var median: Int? {
        guard samples.isEmpty == false else { return nil }
        let sorted = samples.map(\.rssi).sorted()
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return Int((Double(sorted[mid - 1] + sorted[mid]) / 2).rounded(.down))
        }
        return sorted[mid]
    }
}
