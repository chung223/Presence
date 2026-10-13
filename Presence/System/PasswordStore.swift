import Foundation
import LocalAuthentication
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

    enum ReadResult {
        case success(String)
        case notFound
        /// 鑰匙圈要使用者允許才能讀（例如 App 的簽名換了）。
        case needsPermission
        case failed(OSStatus)
    }

    /// `allowUI` 為 false 時絕不跳出對話框：鎖定畫面後面的對話框沒人看得到，會讓 App 卡住。
    static func read(allowUI: Bool) -> ReadResult {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowUI {
            let context = LAContext()
            context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else { return .failed(status) }
            return .success(password)
        case errSecItemNotFound:
            return .notFound
        case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled:
            return .needsPermission
        default:
            return .failed(status)
        }
    }

    static func save(_ password: String) throws {
        SecItemDelete(baseQuery as CFDictionary)
        var item = baseQuery
        item[kSecValueData as String] = Data(password.utf8)
        item[kSecAttrLabel as String] = "Presence"
        item[kSecAttrDescription as String] = String(localized: "Presence 自動解鎖用的登入密碼")
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                          userInfo: [NSLocalizedDescriptionKey: SecCopyErrorMessageString(status, nil) as String? ?? String(localized: "錯誤 \(status)")])
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
