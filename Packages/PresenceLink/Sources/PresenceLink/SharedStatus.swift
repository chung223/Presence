import Foundation

/// App 與小工具共用的最新狀態，存在 App Group 的 UserDefaults。
///
/// 小工具與控制中心不能自己連藍牙，只能顯示 App 存下來的狀態；按下按鈕時，動作交回 App 執行。
public struct SharedStatus: Codable, Sendable, Equatable {
    public var macName: String?
    public var status: LinkStatus?
    /// 寫入時跟 Mac 連著沒有（手錶是指 iPhone 剛同步過來）。
    public var connected: Bool
    public var updatedAt: Date

    public init(macName: String?, status: LinkStatus?, connected: Bool, updatedAt: Date = Date()) {
        self.macName = macName
        self.status = status
        self.connected = connected
        self.updatedAt = updatedAt
    }

    public var isPaired: Bool { macName != nil }

    public func isPaused(at now: Date = Date()) -> Bool {
        status?.pausedUntil.map { $0 > now } ?? false
    }

    /// 小工具上要不要提醒「這是舊的狀態」。
    public func isStale(at now: Date = Date()) -> Bool {
        !connected || now.timeIntervalSince(updatedAt) > 30 * 60
    }

    /// 只比較小工具會顯示的內容，用來決定要不要請系統重畫小工具（重畫次數有限額）。
    public var widgetSignature: String {
        guard let status else { return "\(macName ?? "-")|\(connected)" }
        return "\(macName ?? "-")|\(connected)|\(status.presence.rawValue)|\(status.locked)|\(status.pausedUntil?.timeIntervalSince1970 ?? 0)"
    }
}

public enum SharedStatusStore {
    /// iPhone 與手錶各自的 App 和小工具共用；名稱相同，但兩台裝置上是不同的容器。
    public static let appGroup = "group.com.chung.presence.remote"
    private static let key = "sharedStatus"

    public static func load() -> SharedStatus? {
        guard let data = UserDefaults(suiteName: appGroup)?.data(forKey: key) else { return nil }
        return try? WatchMessage.decode(SharedStatus.self, from: data)
    }

    /// 回傳 true 表示小工具顯示的內容變了。
    @discardableResult
    public static func save(_ shared: SharedStatus) -> Bool {
        let changed = load()?.widgetSignature != shared.widgetSignature
        if let data = try? WatchMessage.encode(shared) {
            UserDefaults(suiteName: appGroup)?.set(data, forKey: key)
        }
        return changed
    }
}
