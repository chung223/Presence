import Foundation
import Security

/// App 與小工具共用的最新狀態，存在共用的鑰匙圈群組（見 SharedStatusStore）。
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

/// 存在共用的鑰匙圈群組：App 與小工具的 `keychain-access-groups` 都列了它。
///
/// 不用 App Group，因為建立 App Group 要登入開發者網站；萬用與正式的描述檔本來就允許
/// 同一個團隊前綴下的任何鑰匙圈群組。群組全名（含團隊前綴）由 Info.plist 的
/// `PresenceSharedKeychainGroup` 提供。iPhone 與手錶各自是不同的鑰匙圈。
public enum SharedStatusStore {
    private static let service = "com.chung.presence.remote.shared"
    private static let account = "status"

    private static var baseQuery: [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        if let group = Bundle.main.object(forInfoDictionaryKey: "PresenceSharedKeychainGroup") as? String, !group.isEmpty {
            query[kSecAttrAccessGroup as String] = group
        }
        return query
    }

    public static func load() -> SharedStatus? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? WatchMessage.decode(SharedStatus.self, from: data)
    }

    /// 回傳 true 表示小工具顯示的內容變了。
    @discardableResult
    public static func save(_ shared: SharedStatus) -> Bool {
        let changed = load()?.widgetSignature != shared.widgetSignature
        guard let data = try? WatchMessage.encode(shared) else { return changed }
        let update: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var item = baseQuery
            item[kSecValueData as String] = data
            // 鎖定畫面的小工具要在手機鎖著時也讀得到
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(item as CFDictionary, nil)
            if status != errSecSuccess { LinkLog.write("[共用狀態] 寫入失敗（\(status)）") }
        }
        return changed
    }
}
