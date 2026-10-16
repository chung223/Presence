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
    /// 簡報遙控：翻頁、開始與結束播放、黑畫面。Mac 要先在「手機與手錶」允許。
    case presenter(PresenterAction)
    /// 開始或結束簡報：簡報時 Mac 暫停自動鎖定，拿著手機走到台前也不會鎖。
    case presentation(active: Bool)
    /// 跳到第幾頁：Mac 輸入頁碼再按 Return（Keynote、PowerPoint、Google 簡報都支援）。
    case goToSlide(Int)
    /// 簡報計時：從什麼時候開始算、預定講幾分鐘（nil 表示不限）。存在 Mac 上，手機、手錶、鎖定畫面顯示同一個倒數。
    case presentationTimer(startedAt: Date, minutes: Int?)
}

extension LinkCommand {
    /// 要 Presence Pro 才能送的簡報指令。結束簡報不算：沒有 Pro 也要能讓 Mac 恢復自動鎖定。
    public var needsPro: Bool {
        switch self {
        case .presenter, .goToSlide, .presentationTimer, .presentation(active: true): true
        case .hello, .status, .lock, .pause, .resume, .confirm, .presentation(active: false): false
        }
    }
}

/// 簡報遙控能按的鍵。只有這幾個，Mac 不接受任意按鍵。
public enum PresenterAction: String, Codable, Sendable, CaseIterable {
    case next, previous
    /// 開始播放：Mac 依前景的 App 送對應的快捷鍵。
    case start
    /// 結束播放（Esc）。
    case end
    /// 把投影畫面變黑（B），再按一次回來。
    case blank
}

/// Mac 沒有執行指令的原因，iPhone 與手錶依此顯示自己語言的說明。
public enum CommandRefusal: String, Codable, Sendable {
    /// Mac 上沒有允許簡報遙控。
    case presenterNotAllowed
    /// Mac 沒有輔助使用權限，不能送按鍵。
    case noAccessibility
    /// Mac 螢幕鎖著：不送按鍵，免得打進登入畫面。
    case screenLocked
    /// 沒有 Presence Pro（iPhone 代手錶轉送簡報指令時判斷，不是 Mac 回的）。
    case proRequired

    public var message: String {
        switch self {
        case .presenterNotAllowed:
            String(localized: "請在 Mac 的 Presence 打開「手機與手錶 › 允許簡報遙控」", bundle: .module)
        case .noAccessibility:
            String(localized: "Mac 上的 Presence 沒有輔助使用權限，不能翻頁", bundle: .module)
        case .screenLocked:
            String(localized: "Mac 螢幕鎖著，先解鎖才能翻頁", bundle: .module)
        case .proRequired:
            String(localized: "簡報遙控是 Presence Pro 的功能，請在 iPhone 的 Presence Remote 升級", bundle: .module)
        }
    }
}

extension LinkStatus {
    /// 預定的結束時間；沒設演講長度是 nil。
    public var presentationEndsAt: Date? {
        guard let start = presentationStartedAt, let minutes = presentationMinutes else { return nil }
        return start.addingTimeInterval(TimeInterval(minutes * 60))
    }

    /// 回覆的指令沒有做成的原因；Mac 用了這版不認得的原因時，給一般的說明。
    public var refusalMessage: String? {
        guard let refusal else { return nil }
        return CommandRefusal(rawValue: refusal)?.message ?? String(localized: "Mac 沒有接受這個指令", bundle: .module)
    }
}

/// Mac 對簡報遙控的支援。`LinkStatus.presenter` 是 nil 表示 Mac 上的 Presence 太舊、看不懂簡報指令。
public enum PresenterSupport: String, Codable, Sendable {
    /// Mac 上沒有允許簡報遙控。
    case disabled
    case enabled
    /// 正在簡報：已暫停自動鎖定。
    case presenting
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
    /// Mac 上顯示的一行狀態，例如「Weichung 在附近 · -52 dBm」（Mac 的語言）。顯示時用 `displaySummary`。
    public var summary: String
    /// 同一行狀態的結構化內容，手機與手錶用自己的語言組；舊版 Mac 不會送，是 nil。
    public var detail: StatusDetail?
    public var locked: Bool
    public var pausedUntil: Date?
    /// 這次通知要提醒的事件；一般狀態更新是 nil。
    public var event: LinkEvent?
    /// 回覆哪一個指令；主動推送是 nil。
    public var replyTo: UUID?
    /// Mac 要解鎖前的在場確認：收到就馬上用 `LinkCommand.confirm` 送回。
    public var challenge: Data?
    /// 簡報遙控的狀態；舊版 Mac 不會送，是 nil。
    public var presenter: PresenterSupport?
    /// 允許簡報遙控時：Mac 最前面的 App（按鍵會送到這裡），以及它是不是能播放簡報的 App。
    public var frontApp: String?
    public var frontAppPresents: Bool?
    /// 簡報計時（見 `LinkCommand.presentationTimer`）。
    public var presentationStartedAt: Date?
    public var presentationMinutes: Int?
    /// 回覆的指令沒有做成時的原因（`CommandRefusal` 的 rawValue）。存成字串：新版 Mac 多了原因，
    /// 舊版 iPhone 也還解得開整則狀態。
    public var refusal: String?
    public var sentAt: Date

    public init(macName: String, presence: MacPresence, summary: String, detail: StatusDetail? = nil, locked: Bool,
                pausedUntil: Date? = nil, event: LinkEvent? = nil, replyTo: UUID? = nil,
                challenge: Data? = nil, presenter: PresenterSupport? = nil, refusal: String? = nil,
                frontApp: String? = nil, frontAppPresents: Bool? = nil,
                presentationStartedAt: Date? = nil, presentationMinutes: Int? = nil,
                sentAt: Date = Date()) {
        self.macName = macName
        self.presence = presence
        self.summary = summary
        self.detail = detail
        self.locked = locked
        self.pausedUntil = pausedUntil
        self.event = event
        self.replyTo = replyTo
        self.challenge = challenge
        self.presenter = presenter
        self.refusal = refusal
        self.frontApp = frontApp
        self.frontAppPresents = frontAppPresents
        self.presentationStartedAt = presentationStartedAt
        self.presentationMinutes = presentationMinutes
        self.sentAt = sentAt
    }
}
