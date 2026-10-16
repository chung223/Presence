import Foundation

/// Mac 狀態的結構化內容，讓 iPhone、手錶、小工具用自己的語言組出那一行狀態。
/// `LinkStatus.summary` 是 Mac 用 Mac 的語言組好的文字：手機換成別的語言時會對不上（2026-10-16 使用者發現）。
/// 種類存成字串：新版 Mac 多了種類時，舊版 iPhone 認不得就退回 `summary`。
public struct StatusDetail: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case needsDevice, bluetoothOff, paused, presenting, suspended, lockPending, lockPendingActive
        case waiting, near, leaving, awayWeak, awayLost
    }

    /// 依情境暫停的原因（對應 PresenceCore 的 `ContextRules.Suspension`）。
    public enum Suspension: Codable, Sendable, Equatable {
        case presenting(app: String)
        case trustedNetwork(name: String)
        case onACPower
        case outsideSchedule
    }

    public var kind: String
    /// 在附近時是在附近的裝置；其他狀態只監控一台時是那一台，空的表示「所有裝置」。
    public var devices: [String]
    public var rssi: Int?
    /// 離開中：還有幾秒鎖定。
    public var leavingSeconds: Int?
    public var suspension: Suspension?
    /// 依情境暫停時，自動解鎖也一起暫停。
    public var suspendsUnlock: Bool?

    public init(kind: Kind, devices: [String] = [], rssi: Int? = nil, leavingSeconds: Int? = nil,
                suspension: Suspension? = nil, suspendsUnlock: Bool? = nil) {
        self.kind = kind.rawValue
        self.devices = devices
        self.rssi = rssi
        self.leavingSeconds = leavingSeconds
        self.suspension = suspension
        self.suspendsUnlock = suspendsUnlock
    }

    /// 和 Mac 選單列的狀態同一套句子（字串鍵與翻譯跟 Mac 版相同）；認不得的種類回傳 nil。
    public var localizedSummary: String? {
        guard let kind = Kind(rawValue: kind) else { return nil }
        let subject = devices.isEmpty ? String(localized: "所有裝置", bundle: .module) : ListFormatter.localizedString(byJoining: devices)
        let rssi = rssi.map { " · \($0) dBm" } ?? ""
        let title: String
        switch kind {
        case .needsDevice: return String(localized: "還沒選擇裝置", bundle: .module)
        case .bluetoothOff: return String(localized: "藍牙無法使用", bundle: .module)
        case .suspended:
            let reason = switch suspension {
            case .presenting(let app): String(localized: "「\(app)」正在播放簡報", bundle: .module)
            case .trustedNetwork(let name): String(localized: "在「\(name)」", bundle: .module)
            case .onACPower: String(localized: "接著電源", bundle: .module)
            case .outsideSchedule, nil: String(localized: "不在設定的時段", bundle: .module)
            }
            return suspendsUnlock == true
                ? String(localized: "\(reason)，暫停自動鎖定與解鎖", bundle: .module)
                : String(localized: "\(reason)，暫停自動鎖定", bundle: .module)
        case .near: return String(localized: "\(subject) 在附近\(rssi)", bundle: .module)
        case .paused: title = String(localized: "已暫停", bundle: .module)
        case .presenting: title = String(localized: "簡報中", bundle: .module)
        case .lockPending: title = String(localized: "即將鎖定", bundle: .module)
        case .lockPendingActive: title = String(localized: "偵測到你還在操作，暫緩鎖定", bundle: .module)
        case .waiting: title = String(localized: "等待訊號", bundle: .module)
        case .leaving: title = String(localized: "離開中，\(leavingSeconds ?? 0) 秒後鎖定", bundle: .module)
        case .awayWeak: title = String(localized: "不在附近", bundle: .module)
        case .awayLost: title = String(localized: "收不到訊號", bundle: .module)
        }
        return String(localized: "\(subject)：\(title)\(rssi)", bundle: .module)
    }
}

extension LinkStatus {
    /// 要顯示的那一行狀態：Mac 有送結構化內容就用這台裝置的語言組，否則用 Mac 組好的文字。
    public var displaySummary: String {
        detail?.localizedSummary ?? summary
    }
}
