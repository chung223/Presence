import Foundation
import PresenceCore

enum LockMethod: String, Codable, CaseIterable, Identifiable {
    case lockScreen
    case screensaver

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lockScreen: String(localized: "鎖定螢幕")
        case .screensaver: String(localized: "啟動螢幕保護程式")
        }
    }
}

enum UnlockMode: String, Codable, CaseIterable, Identifiable {
    /// 用模擬鍵盤輸入登入密碼。
    case typePassword
    /// 只喚醒螢幕，交給 macOS 內建的 Apple Watch 解鎖或 Touch ID。不存密碼。
    case handOff

    var id: String { rawValue }

    var title: String {
        switch self {
        case .typePassword: String(localized: "輸入登入密碼")
        case .handOff: String(localized: "只喚醒螢幕，交給 Apple Watch 或 Touch ID")
        }
    }
}

/// 監控中的一台裝置，各自有門檻：手錶戴在手上的訊號通常比放桌上的手機弱。
struct MonitoredDevice: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String?
    var unlockRSSI = -60
    var lockRSSI = -75

    init(id: UUID, name: String? = nil, unlockRSSI: Int = -60, lockRSSI: Int = -75) {
        self.id = id
        self.name = name
        self.unlockRSSI = unlockRSSI
        self.lockRSSI = lockRSSI
    }

    // 之後新增欄位時，舊設定也讀得進來（否則整份設定會被重設）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        unlockRSSI = try c.decodeIfPresent(Int.self, forKey: .unlockRSSI) ?? -60
        lockRSSI = try c.decodeIfPresent(Int.self, forKey: .lockRSSI) ?? -75
    }

    var displayName: String { name ?? Self.unnamed }

    static var unnamed: String { String(localized: "未命名裝置") }
}

/// 使用者設定。整份存成一個 JSON；缺少的欄位用預設值，之後新增欄位也不會讓舊設定失效。
struct Preferences: Equatable {
    var devices: [MonitoredDevice] = []
    var devicePolicy: PresenceGroup.Policy = .anyNear

    var lockEnabled = true
    var lockDelay: TimeInterval = 5
    var signalTimeout: TimeInterval = 60
    var lockMethod: LockMethod = .lockScreen
    var notifyOnLock = true
    /// 正在操作鍵盤或滑鼠時暫緩鎖定（最多 2 分鐘）。
    var stayUnlockedWhileActive = true
    /// 鎖定前先通知，動一下鍵盤或滑鼠可以取消。
    var warnBeforeLock = false

    var unlockEnabled = true
    var unlockMode: UnlockMode = .typePassword
    var wakeOnProximity = true
    /// 配對了 iPhone 時，自動輸入密碼前要先收到它的加密確認（見 LinkService.confirmPresence）。
    var requireCompanionConfirmation = true

    var pauseMedia = false
    var activeMode = false
    var showUnnamedDevices = false

    var shortcutOnLeave: String?
    var shortcutOnReturn: String?
    var sittingReminderEnabled = false
    var sittingReminderInterval: TimeInterval = 3600
    var capturePhotoOnIntrusion = false

    var context = ContextRules()
    /// 立即鎖定的全域快捷鍵；nil 表示沒有設定。
    var lockHotKey: HotKey?

    func proximity(for device: MonitoredDevice) -> ProximitySettings {
        ProximitySettings(
            unlockRSSI: unlockEnabled ? device.unlockRSSI : nil,
            lockRSSI: lockEnabled ? device.lockRSSI : nil,
            lockDelay: lockDelay,
            signalTimeout: signalTimeout
        )
    }

    var proximityByDevice: [UUID: ProximitySettings] {
        Dictionary(devices.map { ($0.id, proximity(for: $0)) }, uniquingKeysWith: { first, _ in first })
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

    /// 使用者自己改名。
    mutating func rename(_ id: UUID, to name: String) {
        guard let i = devices.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        devices[i].name = trimmed.isEmpty ? nil : trimmed
    }

    /// 藍牙廣播的名稱只用來補上還沒有名稱的裝置，不覆蓋使用者取的名字。
    mutating func fillName(_ id: UUID, with name: String) {
        guard let i = devices.firstIndex(where: { $0.id == id }), devices[i].name == nil else { return }
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
        case devices, devicePolicy, lockEnabled, lockDelay, signalTimeout, lockMethod, notifyOnLock
        case stayUnlockedWhileActive, warnBeforeLock, unlockEnabled, unlockMode, wakeOnProximity, requireCompanionConfirmation
        case pauseMedia, activeMode, showUnnamedDevices, context, lockHotKey
        case shortcutOnLeave, shortcutOnReturn, sittingReminderEnabled, sittingReminderInterval, capturePhotoOnIntrusion
        // 0.1 版只有一台裝置，門檻放在最外層
        case targetID, targetName, unlockRSSI, lockRSSI
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Preferences()
        if let devices = try? c.decodeIfPresent([MonitoredDevice].self, forKey: .devices) {
            // 去掉重複的裝置
            var seen = Set<UUID>()
            self.devices = devices.filter { seen.insert($0.id).inserted }
        } else if let id = try c.decodeIfPresent(UUID.self, forKey: .targetID) {
            devices = [MonitoredDevice(
                id: id,
                name: try c.decodeIfPresent(String.self, forKey: .targetName),
                unlockRSSI: try c.decodeIfPresent(Int.self, forKey: .unlockRSSI) ?? -60,
                lockRSSI: try c.decodeIfPresent(Int.self, forKey: .lockRSSI) ?? -75
            )]
        }
        devicePolicy = (try? c.decodeIfPresent(PresenceGroup.Policy.self, forKey: .devicePolicy)) ?? d.devicePolicy
        stayUnlockedWhileActive = try c.decodeIfPresent(Bool.self, forKey: .stayUnlockedWhileActive) ?? d.stayUnlockedWhileActive
        warnBeforeLock = try c.decodeIfPresent(Bool.self, forKey: .warnBeforeLock) ?? d.warnBeforeLock
        unlockMode = (try? c.decodeIfPresent(UnlockMode.self, forKey: .unlockMode)) ?? d.unlockMode
        shortcutOnLeave = try c.decodeIfPresent(String.self, forKey: .shortcutOnLeave)
        shortcutOnReturn = try c.decodeIfPresent(String.self, forKey: .shortcutOnReturn)
        sittingReminderEnabled = try c.decodeIfPresent(Bool.self, forKey: .sittingReminderEnabled) ?? d.sittingReminderEnabled
        sittingReminderInterval = try c.decodeIfPresent(TimeInterval.self, forKey: .sittingReminderInterval) ?? d.sittingReminderInterval
        capturePhotoOnIntrusion = try c.decodeIfPresent(Bool.self, forKey: .capturePhotoOnIntrusion) ?? d.capturePhotoOnIntrusion
        lockEnabled = try c.decodeIfPresent(Bool.self, forKey: .lockEnabled) ?? d.lockEnabled
        lockDelay = try c.decodeIfPresent(TimeInterval.self, forKey: .lockDelay) ?? d.lockDelay
        signalTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .signalTimeout) ?? d.signalTimeout
        lockMethod = (try? c.decodeIfPresent(LockMethod.self, forKey: .lockMethod)) ?? d.lockMethod
        notifyOnLock = try c.decodeIfPresent(Bool.self, forKey: .notifyOnLock) ?? d.notifyOnLock
        unlockEnabled = try c.decodeIfPresent(Bool.self, forKey: .unlockEnabled) ?? d.unlockEnabled
        wakeOnProximity = try c.decodeIfPresent(Bool.self, forKey: .wakeOnProximity) ?? d.wakeOnProximity
        requireCompanionConfirmation = try c.decodeIfPresent(Bool.self, forKey: .requireCompanionConfirmation)
            ?? d.requireCompanionConfirmation
        pauseMedia = try c.decodeIfPresent(Bool.self, forKey: .pauseMedia) ?? d.pauseMedia
        activeMode = try c.decodeIfPresent(Bool.self, forKey: .activeMode) ?? d.activeMode
        showUnnamedDevices = try c.decodeIfPresent(Bool.self, forKey: .showUnnamedDevices) ?? d.showUnnamedDevices
        context = (try? c.decodeIfPresent(ContextRules.self, forKey: .context)) ?? d.context
        lockHotKey = try? c.decodeIfPresent(HotKey.self, forKey: .lockHotKey)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(devices, forKey: .devices)
        try c.encode(devicePolicy, forKey: .devicePolicy)
        try c.encode(stayUnlockedWhileActive, forKey: .stayUnlockedWhileActive)
        try c.encode(warnBeforeLock, forKey: .warnBeforeLock)
        try c.encode(unlockMode, forKey: .unlockMode)
        try c.encodeIfPresent(shortcutOnLeave, forKey: .shortcutOnLeave)
        try c.encodeIfPresent(shortcutOnReturn, forKey: .shortcutOnReturn)
        try c.encode(sittingReminderEnabled, forKey: .sittingReminderEnabled)
        try c.encode(sittingReminderInterval, forKey: .sittingReminderInterval)
        try c.encode(capturePhotoOnIntrusion, forKey: .capturePhotoOnIntrusion)
        try c.encode(lockEnabled, forKey: .lockEnabled)
        try c.encode(lockDelay, forKey: .lockDelay)
        try c.encode(signalTimeout, forKey: .signalTimeout)
        try c.encode(lockMethod, forKey: .lockMethod)
        try c.encode(notifyOnLock, forKey: .notifyOnLock)
        try c.encode(unlockEnabled, forKey: .unlockEnabled)
        try c.encode(wakeOnProximity, forKey: .wakeOnProximity)
        try c.encode(requireCompanionConfirmation, forKey: .requireCompanionConfirmation)
        try c.encode(pauseMedia, forKey: .pauseMedia)
        try c.encode(activeMode, forKey: .activeMode)
        try c.encode(showUnnamedDevices, forKey: .showUnnamedDevices)
        try c.encode(context, forKey: .context)
        try c.encodeIfPresent(lockHotKey, forKey: .lockHotKey)
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
