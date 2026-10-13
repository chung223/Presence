import CryptoKit
import Foundation

public enum LinkCryptoError: Error, Equatable {
    case malformed
}

/// AES-GCM 加密並驗證。JSON 的日期用秒數，盡量縮短。
public enum LinkCrypto {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()

    /// `context` 會一起被驗證但不加密（例如配對編號），對不上就解不開。
    public static func seal<T: Encodable>(_ value: T, key: SymmetricKey, context: Data = Data()) throws -> Data {
        let plain = try encoder.encode(value)
        guard let combined = try AES.GCM.seal(plain, using: key, authenticating: context).combined else {
            throw LinkCryptoError.malformed
        }
        return combined
    }

    public static func open<T: Decodable>(_ type: T.Type, from data: Data, key: SymmetricKey, context: Data = Data()) throws -> T {
        let box = try AES.GCM.SealedBox(combined: data)
        let plain = try AES.GCM.open(box, using: key, authenticating: context)
        return try decoder.decode(type, from: plain)
    }
}

/// iPhone／手錶寫給 Mac 的一筆指令：16 位元組的配對編號，接著是加密的 `LinkRequest`。
/// 配對編號同時當作驗證內容，換掉編號就解不開。
public struct RequestFrame: Equatable, Sendable {
    public let pairingID: UUID
    public let sealed: Data

    public init(pairingID: UUID, sealed: Data) {
        self.pairingID = pairingID
        self.sealed = sealed
    }

    public static func make(_ request: LinkRequest, pairing: PairingInfo) throws -> RequestFrame {
        RequestFrame(pairingID: pairing.id,
                     sealed: try LinkCrypto.seal(request, key: pairing.symmetricKey, context: pairing.id.data))
    }

    public func open(with pairing: PairingInfo) throws -> LinkRequest {
        try LinkCrypto.open(LinkRequest.self, from: sealed, key: pairing.symmetricKey, context: pairingID.data)
    }

    public var encoded: Data { pairingID.data + sealed }

    public init?(encoded data: Data) {
        guard data.count > 16 + 28 else { return nil } // 編號 + nonce 12 + tag 16
        let bytes = [UInt8](data.prefix(16))
        pairingID = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                                bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        sealed = data.dropFirst(16)
    }
}

extension UUID {
    /// 16 位元組的 UUID，當作加密時的驗證內容。
    public var data: Data {
        withUnsafeBytes(of: uuid) { Data($0) }
    }
}
