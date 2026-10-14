import Foundation
import Security

/// Mac 端的在場確認：解鎖前發出一個隨機挑戰，只有用配對金鑰加密送回同一個挑戰的裝置才算數。
///
/// 只看訊號強弱的話，偽造藍牙訊號就能讓 Mac 解鎖；挑戰每次都不同、只收一次、
/// 而且要在時限內回來，舊的回應重送也沒用。
public struct PresenceChallenge: Sendable {
    public let nonce: Data
    public let issuedAt: Date
    /// 已經送出挑戰的連線（CBCentral 的 identifier）。
    public private(set) var sentTo: Set<UUID> = []

    public init(nonce: Data = PresenceChallenge.randomNonce(), issuedAt: Date = Date()) {
        self.nonce = nonce
        self.issuedAt = issuedAt
    }

    /// 記下送給了哪條連線；已經送過就回傳 false。
    public mutating func markSent(to central: UUID) -> Bool {
        sentTo.insert(central).inserted
    }

    public func accepts(_ response: Data, at now: Date, within lifetime: TimeInterval) -> Bool {
        response == nonce && now >= issuedAt && now.timeIntervalSince(issuedAt) <= lifetime
    }

    public static func randomNonce() -> Data {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return withUnsafeBytes(of: UUID().uuid) { Data($0) }
        }
        return Data(bytes)
    }
}
