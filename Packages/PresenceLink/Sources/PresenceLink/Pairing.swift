import CryptoKit
import Foundation

/// 一組配對：Mac 產生編號與金鑰，用 QR code 交給 iPhone；iPhone 再透過 WatchConnectivity 交給手錶。
public struct PairingInfo: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let macName: String
    public let key: Data

    public init(id: UUID, macName: String, key: Data) {
        self.id = id
        self.macName = macName
        self.key = key
    }

    public static func generate(macName: String) -> PairingInfo {
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return PairingInfo(id: UUID(), macName: macName, key: key)
    }

    public var symmetricKey: SymmetricKey { SymmetricKey(data: key) }

    private static let prefix = "presence-pair:1:"

    /// QR code 的內容：`presence-pair:1:<編號>:<金鑰>:<Mac 名稱>`，金鑰與名稱用 base64url。
    public var qrString: String {
        "\(Self.prefix)\(id.uuidString):\(key.base64URL):\(Data(macName.utf8).base64URL)"
    }

    public init?(qrString: String) {
        guard qrString.hasPrefix(Self.prefix) else { return nil }
        let parts = qrString.dropFirst(Self.prefix.count).split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let id = UUID(uuidString: String(parts[0])),
              let key = Data(base64URL: String(parts[1])), key.count == 32,
              let nameData = Data(base64URL: String(parts[2])),
              let name = String(data: nameData, encoding: .utf8), !name.isEmpty else { return nil }
        self.init(id: id, macName: name, key: key)
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URL: String) {
        var s = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        self.init(base64Encoded: s)
    }
}
