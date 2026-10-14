import Foundation

/// Mac（藍牙週邊）與 iPhone、Apple Watch（中央端）之間的協定。
///
/// - iPhone／手錶寫入「指令」特徵：`RequestFrame`（配對編號＋加密的 `LinkRequest`）。
/// - Mac 用「狀態」特徵通知：加密的 `LinkStatus`，太長就用 `LinkChunker` 切段。
/// - 每個配對有自己的 256 位元金鑰；Mac 依連線記住對方的配對，用對應的金鑰加密狀態。
public enum LinkIdentifiers {
    public static let service = "5B1D1001-6A1F-4C7E-9E43-2F0B7C1A8D10"
    public static let command = "5B1D1002-6A1F-4C7E-9E43-2F0B7C1A8D10"
    public static let status = "5B1D1003-6A1F-4C7E-9E43-2F0B7C1A8D10"
}

public enum LinkCommand: Codable, Sendable, Equatable {
    /// 連上後先打招呼，讓 Mac 知道這條連線屬於哪個配對、裝置叫什麼。
    case hello(deviceName: String)
    case status
    case lock
    case pause(minutes: Int)
    case resume
    /// 回應 Mac 的在場確認：原樣送回 `LinkStatus.challenge`。指令本身用配對金鑰加密，
    /// Mac 收到就知道是配對過的裝置、而且此刻真的連著。
    case confirm(challenge: Data)
}

public struct LinkRequest: Codable, Sendable, Equatable {
    public let id: UUID
    public let sentAt: Date
    public let command: LinkCommand

    public init(_ command: LinkCommand, id: UUID = UUID(), sentAt: Date = Date()) {
        self.id = id
        self.sentAt = sentAt
        self.command = command
    }
}

public enum MacPresence: String, Codable, Sendable {
    case near, leaving, away, waiting, paused, suspended, lockPending, noDevice, bluetoothOff
}

public enum LinkEvent: String, Codable, Sendable {
    /// 裝置離開，Mac 自動鎖定
    case lockedAway
    /// 從選單、快捷鍵、iPhone 或手錶手動鎖定
    case lockedManually
    case unlocked
    /// 裝置不在附近時被手動解鎖
    case unlockedWhileAway
}

public struct LinkStatus: Codable, Sendable, Equatable {
    public var macName: String
    public var presence: MacPresence
    /// Mac 上顯示的一行狀態，例如「Weichung 在附近 · -52 dBm」。
    public var summary: String
    public var locked: Bool
    public var pausedUntil: Date?
    /// 這次通知要提醒的事件；一般狀態更新是 nil。
    public var event: LinkEvent?
    /// 回覆哪一個指令；主動推送是 nil。
    public var replyTo: UUID?
    /// Mac 要解鎖前的在場確認：收到就馬上用 `LinkCommand.confirm` 送回。
    public var challenge: Data?
    public var sentAt: Date

    public init(macName: String, presence: MacPresence, summary: String, locked: Bool,
                pausedUntil: Date? = nil, event: LinkEvent? = nil, replyTo: UUID? = nil,
                challenge: Data? = nil, sentAt: Date = Date()) {
        self.macName = macName
        self.presence = presence
        self.summary = summary
        self.locked = locked
        self.pausedUntil = pausedUntil
        self.event = event
        self.replyTo = replyTo
        self.challenge = challenge
        self.sentAt = sentAt
    }
}
