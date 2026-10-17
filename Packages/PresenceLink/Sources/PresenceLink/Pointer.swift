import CryptoKit
import Foundation

/// 雷射筆、聚光燈與螢光筆：手機連續送手指在畫面上的位置，Mac 在畫面最上層畫紅點、聚光燈或線（只畫、不點擊）。
///
/// 跟指令分開，走另一個特徵、寫入不等回覆：每秒約 30 筆，翻頁那種一來一回（約 0.1 秒）跟不上手指。
/// 每筆只有十幾個位元組，照樣用配對金鑰加密驗證；驗證內容多加 "pointer"，不會跟指令混用。
public struct PointerUpdate: Equatable, Sendable {
    public enum Mode: UInt8, Sendable, CaseIterable {
        /// 手指離開：收起紅點或聚光燈。
        case hidden = 0
        case laser = 1
        case spotlight = 2
        /// 手指畫線，幾秒後淡掉。要 `LinkStatus.highlighter` 是 true 的 Mac 才看得懂。
        case highlighter = 3
    }

    public var mode: Mode
    /// 在畫面上的位置，0～1，從左上角算。
    public var x: Double
    public var y: Double
    /// 螢光筆的第幾筆：手指放開再按下就換一個號碼，Mac 才不會把兩筆連成一條線（收起的那筆可能掉）。
    public var stroke: UInt8
    public var sentAt: Date

    public init(mode: Mode, x: Double, y: Double, stroke: UInt8 = 0, sentAt: Date = Date()) {
        self.mode = mode
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
        self.stroke = stroke
        self.sentAt = sentAt
    }

    /// 第 1 版 14 位元組：版本、模式、x、y（各 2 位元組）、送出時間（8 位元組）。
    /// 第 2 版在最後多一個位元組的筆畫號碼，只有螢光筆用：雷射筆、聚光燈照舊送第 1 版，舊版 Mac 才看得懂。
    var plain: Data {
        let version: UInt8 = mode == .highlighter ? 2 : 1
        var data = Data([version, mode.rawValue])
        for value in [UInt16((x * 65535).rounded()), UInt16((y * 65535).rounded())] {
            withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
        }
        withUnsafeBytes(of: sentAt.timeIntervalSince1970.bitPattern.bigEndian) { data.append(contentsOf: $0) }
        if version == 2 { data.append(stroke) }
        return data
    }

    init?(plain data: Data) {
        let bytes = [UInt8](data)
        guard (bytes.count == 14 && bytes.first == 1) || (bytes.count == 15 && bytes.first == 2),
              let mode = Mode(rawValue: bytes[1]) else { return nil }
        func uint<T: FixedWidthInteger>(_ range: Range<Int>, as: T.Type) -> T {
            range.reduce(T(0)) { $0 << 8 | T(bytes[$1]) }
        }
        self.init(mode: mode,
                  x: Double(uint(2..<4, as: UInt16.self)) / 65535,
                  y: Double(uint(4..<6, as: UInt16.self)) / 65535,
                  stroke: bytes.count == 15 ? bytes[14] : 0,
                  sentAt: Date(timeIntervalSince1970: Double(bitPattern: uint(6..<14, as: UInt64.self))))
    }
}

/// 寫給 Mac 的一筆位置：16 位元組的配對編號，接著是加密的 `PointerUpdate`。
public enum PointerFrame {
    private static func context(_ pairingID: UUID) -> Data { pairingID.data + Data("pointer".utf8) }

    public static func make(_ update: PointerUpdate, pairing: PairingInfo) throws -> Data {
        guard let sealed = try AES.GCM.seal(update.plain, using: pairing.symmetricKey,
                                            authenticating: context(pairing.id)).combined else {
            throw LinkCryptoError.malformed
        }
        return pairing.id.data + sealed
    }

    /// 開頭的配對編號（Mac 用來找金鑰）。
    public static func pairingID(of data: Data) -> UUID? {
        guard data.count > 16 + 28 else { return nil }
        let b = [UInt8](data.prefix(16))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// 金鑰不對、被改過或格式不對都回傳 nil。
    public static func open(_ data: Data, key: SymmetricKey) -> PointerUpdate? {
        guard let id = pairingID(of: data),
              let box = try? AES.GCM.SealedBox(combined: data.dropFirst(16)),
              let plain = try? AES.GCM.open(box, using: key, authenticating: context(id)) else { return nil }
        return PointerUpdate(plain: plain)
    }
}

/// 擋掉重送：只收比上一筆新、而且跟 Mac 時鐘差在 30 秒內的位置。
public struct PointerGuard: Sendable {
    private var last: Date?

    public init() {}

    public mutating func accept(_ update: PointerUpdate, now: Date) -> Bool {
        guard abs(now.timeIntervalSince(update.sentAt)) <= 30 else { return false }
        if let last, update.sentAt <= last { return false }
        last = update.sentAt
        return true
    }
}
