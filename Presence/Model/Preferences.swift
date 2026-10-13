import Foundation
import PresenceCore

enum LockMethod: String, Codable, CaseIterable, Identifiable {
    case lockScreen
    case screensaver

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lockScreen: "鎖定螢幕"
        case .screensaver: "啟動螢幕保護程式"
        }
    }
}

/// 使用者設定。整份存成一個 JSON；缺少的欄位用預設值，之後新增欄位也不會讓舊設定失效。
struct Preferences: Equatable {
    var targetID: UUID?
    var targetName: String?

    var lockEnabled = true
    var lockRSSI = -75
    var lockDelay: TimeInterval = 5
    var signalTimeout: TimeInterval = 60
    var lockMethod: LockMethod = .lockScreen
    var notifyOnLock = true

    var unlockEnabled = true
    var unlockRSSI = -60
    var wakeOnProximity = true

    var pauseMedia = false
    var activeMode = false
    var showUnnamedDevices = false

    var proximity: ProximitySettings {
        ProximitySettings(
            unlockRSSI: unlockEnabled ? unlockRSSI : nil,
            lockRSSI: lockEnabled ? lockRSSI : nil,
            lockDelay: lockDelay,
            signalTimeout: signalTimeout
        )
    }

    /// 調整門檻時維持「鎖定門檻低於解鎖門檻」。
    mutating func setUnlockRSSI(_ value: Int) {
        unlockRSSI = value
        if lockRSSI >= value { lockRSSI = value - 1 }
    }

    mutating func setLockRSSI(_ value: Int) {
        lockRSSI = value
        if unlockRSSI <= value { unlockRSSI = value + 1 }
    }
}

extension Preferences: Codable {
    private enum CodingKeys: String, CodingKey {
        case targetID, targetName, lockEnabled, lockRSSI, lockDelay, signalTimeout, lockMethod, notifyOnLock
        case unlockEnabled, unlockRSSI, wakeOnProximity, pauseMedia, activeMode, showUnnamedDevices
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        targetID = try c.decodeIfPresent(UUID.self, forKey: .targetID)
        targetName = try c.decodeIfPresent(String.self, forKey: .targetName)
        lockEnabled = try c.decodeIfPresent(Bool.self, forKey: .lockEnabled) ?? d.lockEnabled
        lockRSSI = try c.decodeIfPresent(Int.self, forKey: .lockRSSI) ?? d.lockRSSI
        lockDelay = try c.decodeIfPresent(TimeInterval.self, forKey: .lockDelay) ?? d.lockDelay
        signalTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .signalTimeout) ?? d.signalTimeout
        lockMethod = (try? c.decodeIfPresent(LockMethod.self, forKey: .lockMethod)) ?? d.lockMethod
        notifyOnLock = try c.decodeIfPresent(Bool.self, forKey: .notifyOnLock) ?? d.notifyOnLock
        unlockEnabled = try c.decodeIfPresent(Bool.self, forKey: .unlockEnabled) ?? d.unlockEnabled
        unlockRSSI = try c.decodeIfPresent(Int.self, forKey: .unlockRSSI) ?? d.unlockRSSI
        wakeOnProximity = try c.decodeIfPresent(Bool.self, forKey: .wakeOnProximity) ?? d.wakeOnProximity
        pauseMedia = try c.decodeIfPresent(Bool.self, forKey: .pauseMedia) ?? d.pauseMedia
        activeMode = try c.decodeIfPresent(Bool.self, forKey: .activeMode) ?? d.activeMode
        showUnnamedDevices = try c.decodeIfPresent(Bool.self, forKey: .showUnnamedDevices) ?? d.showUnnamedDevices
    }
}

struct PreferencesStore {
    private let defaults: UserDefaults
    private let key = "preferences.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> Preferences {
        guard let data = defaults.data(forKey: key),
              let prefs = try? JSONDecoder().decode(Preferences.self, from: data) else { return Preferences() }
        return prefs
    }

    func save(_ prefs: Preferences) {
        if let data = try? JSONEncoder().encode(prefs) {
            defaults.set(data, forKey: key)
        }
    }
}
