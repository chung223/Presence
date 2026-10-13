import Foundation

/// 判斷「在不在附近」用到的設定。只放判斷邏輯需要的值，介面選項放在 App 那一層。
public struct ProximitySettings: Sendable, Equatable, Codable {
    /// 訊號強於這個值才算夠近、可以解鎖。nil 表示不自動解鎖。
    public var unlockRSSI: Int?
    /// 訊號弱於這個值開始倒數鎖定。nil 表示不自動鎖定。
    public var lockRSSI: Int?
    /// 訊號持續低於鎖定門檻多久才算離開。
    public var lockDelay: TimeInterval
    /// 完全收不到訊號多久才算離開。
    public var signalTimeout: TimeInterval
    /// 取中位數的時間視窗，用來濾掉單筆異常值。
    public var filterWindow: TimeInterval
    /// 視窗內至少要有幾筆樣本，才能判定靠近或遠離。
    public var minimumSamples: Int
    /// 手動鎖定後，要離開多久才恢復自動解鎖。
    public var manualLockRearm: TimeInterval

    public init(
        unlockRSSI: Int? = -60,
        lockRSSI: Int? = -75,
        lockDelay: TimeInterval = 5,
        signalTimeout: TimeInterval = 60,
        filterWindow: TimeInterval = 4,
        minimumSamples: Int = 3,
        manualLockRearm: TimeInterval = 30
    ) {
        self.unlockRSSI = unlockRSSI
        self.lockRSSI = lockRSSI
        self.lockDelay = lockDelay
        self.signalTimeout = signalTimeout
        self.filterWindow = filterWindow
        self.minimumSamples = minimumSamples
        self.manualLockRearm = manualLockRearm
    }

    public static let `default` = ProximitySettings()

    /// 判定「夠近」的門檻：有解鎖門檻就用它，沒有就用鎖定門檻。
    public var arrivalThreshold: Int { unlockRSSI ?? lockRSSI ?? -60 }

    /// 判定「遠離」的門檻：有鎖定門檻就用它，沒有就用解鎖門檻。
    public var departureThreshold: Int { lockRSSI ?? unlockRSSI ?? -75 }

    /// 修正不合理的組合：鎖定門檻不能高於解鎖門檻，數值也要在合理範圍內。
    public func normalized() -> ProximitySettings {
        var s = self
        s.unlockRSSI = s.unlockRSSI.map { min(max($0, -100), -20) }
        s.lockRSSI = s.lockRSSI.map { min(max($0, -100), -20) }
        if let unlock = s.unlockRSSI, let lock = s.lockRSSI, lock > unlock {
            s.lockRSSI = unlock
        }
        s.lockDelay = max(s.lockDelay, 0)
        s.signalTimeout = max(s.signalTimeout, 5)
        s.filterWindow = max(s.filterWindow, 1)
        s.minimumSamples = max(s.minimumSamples, 1)
        s.manualLockRearm = max(s.manualLockRearm, 0)
        return s
    }
}
