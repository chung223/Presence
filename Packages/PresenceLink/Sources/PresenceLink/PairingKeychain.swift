import Foundation
import Security

/// iPhone 與 Apple Watch 存配對資料（含金鑰）的地方。
/// 手機鎖定時背景的藍牙連線也要讀得到，所以用「開機後解鎖過一次就可讀、不同步到其他裝置」。
public enum PairingKeychain {
    private static let service = "com.chung.presence.remote.pairing"
    private static let account = "pairing"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public static func load() -> PairingInfo? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(PairingInfo.self, from: data)
    }

    public static func save(_ pairing: PairingInfo) {
        guard let data = try? JSONEncoder().encode(pairing) else { return }
        SecItemDelete(baseQuery as CFDictionary)
        var item = baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(item as CFDictionary, nil)
    }

    public static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}
