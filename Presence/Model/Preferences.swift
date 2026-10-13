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

/// 監控中的一台裝置，各自有門檻：手錶戴在手上的訊號通常比放桌上的手機弱。
struct MonitoredDevice: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String?
    var unlockRSSI = -60
    var lockRSSI = -75

    var displayName: String { name ?? "未命名裝置" }
}

/// 使用者設定。整份存成一個 JSON；缺少的欄位用預設值，之後新增欄位也不會讓舊設定失效。
struct Preferences: Equatable {
    var devices: [MonitoredDevice] = []

    var lockEnabled = true
    var lockDelay: TimeInterval = 5
    var signalTimeout: TimeInterval = 60
    var lockMethod: LockMethod = .lockScreen
    var notifyOnLock = true

    var unlockEnabled = true
    var wakeOnProximity = true

    var pauseMedia = false
    var activeMode = false
    var showUnnamedDevices = false

    var context = ContextRules()

    func proximity(for device: MonitoredDevice) -> ProximitySettings {
        ProximitySettings(
            unlockRSSI: unlockEnabled ? device.unlockRSSI : nil,
            lockRSSI: lockEnabled ? device.lockRSSI : nil,
            lockDelay: lockDelay,
            signalTimeout: signalTimeout
        )
    }

    var proximityByDevice: [UUID: ProximitySettings] {
        Dictionary(uniqueKeysWithValues: devices.map { ($0.id, proximity(for: $0)) })
    }

    func device(_ id: UUID) -> MonitoredDevice? {
        devices.first { $0.id == id }
    }

    mutating func addDevice(id: UUID, name: String?) {
        guard device(id) == nil else { return }
        devices.append(MonitoredDevice(id: id, name: name))
    }

    mutating func removeDevice(_ id: UUID) {
        devices.removeAll { $0.id == id }
    }

    mutating func rename(_ id: UUID, to name: String) {
        guard let i = devices.firstIndex(where: { $0.id == id }), devices[i].name != name else { return }
        devices[i].name = name
    }

    /// 調整門檻時維持「鎖定門檻低於解鎖門檻」。
    mutating func setUnlockRSSI(_ value: Int, for id: UUID) {
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[i].unlockRSSI = value
        if devices[i].lockRSSI >= value { devices[i].lockRSSI = value - 1 }
    }

    mutating func setLockRSSI(_ value: Int, for id: UUID) {
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[i].lockRSSI = value
        if devices[i].unlockRSSI <= value { devices[i].unlockRSSI = value + 1 }
    }
}

extension Preferences: Codable {
    private enum CodingKeys: String, CodingKey {
        case devices, lockEnabled, lockDelay, signalTimeout, lockMethod, notifyOnLock
        case unlockEnabled, wakeOnProximity, pauseMedia, activeMode, showUnnamedDevices, context
        // 0.1 版只有一台裝置，門檻放在最外層
        case targetID, targetName, unlockRSSI, lockRSSI
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        if let devices = try c.decodeIfPresent([MonitoredDevice].self, forKey: .devices) {
            self.devices = devices
        } else if let id = try c.decodeIfPresent(UUID.self, forKey: .targetID) {
            devices = [MonitoredDevice(
                id: id,
                name: try c.decodeIfPresent(String.self, forKey: .targetName),
                unlockRSSI: try c.decodeIfPresent(Int.self, forKey: .unlockRSSI) ?? -60,
                lockRSSI: try c.decodeIfPresent(Int.self, forKey: .lockRSSI) ?? -75
            )]
        }
        lockEnabled = try c.decodeIfPresent(Bool.self, forKey: .lockEnabled) ?? d.lockEnabled
        lockDelay = try c.decodeIfPresent(TimeInterval.self, forKey: .lockDelay) ?? d.lockDelay
        signalTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .signalTimeout) ?? d.signalTimeout
        lockMethod = (try? c.decodeIfPresent(LockMethod.self, forKey: .lockMethod)) ?? d.lockMethod
        notifyOnLock = try c.decodeIfPresent(Bool.self, forKey: .notifyOnLock) ?? d.notifyOnLock
        unlockEnabled = try c.decodeIfPresent(Bool.self, forKey: .unlockEnabled) ?? d.unlockEnabled
        wakeOnProximity = try c.decodeIfPresent(Bool.self, forKey: .wakeOnProximity) ?? d.wakeOnProximity
        pauseMedia = try c.decodeIfPresent(Bool.self, forKey: .pauseMedia) ?? d.pauseMedia
        activeMode = try c.decodeIfPresent(Bool.self, forKey: .activeMode) ?? d.activeMode
        showUnnamedDevices = try c.decodeIfPresent(Bool.self, forKey: .showUnnamedDevices) ?? d.showUnnamedDevices
        context = (try? c.decodeIfPresent(ContextRules.self, forKey: .context)) ?? d.context
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(devices, forKey: .devices)
        try c.encode(lockEnabled, forKey: .lockEnabled)
        try c.encode(lockDelay, forKey: .lockDelay)
        try c.encode(signalTimeout, forKey: .signalTimeout)
        try c.encode(lockMethod, forKey: .lockMethod)
        try c.encode(notifyOnLock, forKey: .notifyOnLock)
        try c.encode(unlockEnabled, forKey: .unlockEnabled)
        try c.encode(wakeOnProximity, forKey: .wakeOnProximity)
        try c.encode(pauseMedia, forKey: .pauseMedia)
        try c.encode(activeMode, forKey: .activeMode)
        try c.encode(showUnnamedDevices, forKey: .showUnnamedDevices)
        try c.encode(context, forKey: .context)
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
