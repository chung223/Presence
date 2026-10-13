import Foundation
import OpenDirectory
import Security

/// 登入密碼存在鑰匙圈。只有解鎖的那一刻才讀出來，不寫進任何紀錄。
enum PasswordStore {
    private static let service = "com.chung.presence"

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: NSUserName(),
        ]
    }

    /// 只查有沒有，不讀內容。
    static var exists: Bool {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    static func read() -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ password: String) throws {
        SecItemDelete(baseQuery as CFDictionary)
        var item = baseQuery
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrLabel as String] = "Presence"
        item[kSecAttrDescription as String] = "Presence 自動解鎖用的登入密碼"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? "錯誤 \(status)"])
        }
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    /// 存之前先驗證這是目前使用者正確的登入密碼，避免存錯後每次解鎖都失敗。
    static func verify(_ password: String) -> Bool {
        do {
            let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeAuthentication))
            let record = try node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
            try record.verifyPassword(password)
            return true
        } catch {
            return false
        }
    }
}
