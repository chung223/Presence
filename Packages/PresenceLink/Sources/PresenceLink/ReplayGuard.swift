import Foundation

/// 擋掉重送的指令：時間差超過視窗的不收，同一個指令編號只收一次。
public struct ReplayGuard: Sendable {
    public var window: TimeInterval
    private var seen: [UUID: Date] = [:]

    public init(window: TimeInterval = 60) {
        self.window = window
    }

    public mutating func accept(_ request: LinkRequest, now: Date) -> Bool {
        seen = seen.filter { now.timeIntervalSince($0.value) < window * 2 }
        guard abs(now.timeIntervalSince(request.sentAt)) <= window, seen[request.id] == nil else { return false }
        seen[request.id] = now
        return true
    }
}
