import AppKit
import Observation
import PresenceCore

/// 把藍牙訊號、判斷邏輯、螢幕狀態和使用者操作串在一起。
@Observable
final class AppModel {
    struct RSSIPoint: Identifiable, Equatable {
        let date: Date
        let rssi: Int
        var id: Date { date }
    }

    enum Status: Equatable {
        case needsDevice
        case bluetoothUnavailable(String)
        case paused(until: Date)
        case waiting
        case near
        case leaving(remaining: TimeInterval)
        case away(DepartureReason)

        var title: String {
            switch self {
            case .needsDevice: "還沒選擇裝置"
            case .bluetoothUnavailable(let reason): "藍牙\(reason)"
            case .paused: "已暫停"
            case .waiting: "等待訊號"
            case .near: "在附近"
            case .leaving(let remaining): "離開中，\(Int(remaining.rounded(.up))) 秒後鎖定"
            case .away(.weakSignal): "不在附近"
            case .away(.signalLost): "收不到訊號"
            }
        }

        var symbol: String {
            switch self {
            case .needsDevice: "questionmark.circle"
            case .bluetoothUnavailable: "exclamationmark.triangle"
            case .paused: "pause.circle"
            case .waiting: "ellipsis.circle"
            case .near: "iphone.radiowaves.left.and.right"
            case .leaving: "figure.walk.departure"
            case .away: "iphone.slash"
            }
        }
    }

    enum SetupItem: String, CaseIterable, Identifiable {
        case bluetooth, device, accessibility, password, legacyApp
        var id: String { rawValue }
    }

    var preferences: Preferences {
        didSet {
            guard preferences != oldValue else { return }
            store.save(preferences)
            apply(changesFrom: oldValue)
        }
    }

    let bluetooth = BluetoothMonitor()
    let session = ScreenSession()
    let log = EventLog()

    private(set) var group: PresenceGroup
    private(set) var automation = Automation()
    /// 每台裝置最近 3 分鐘收到的訊號，以及每秒一點的濾波結果（給訊號圖用）。
    private(set) var samples: [UUID: [RSSIPoint]] = [:]
    private(set) var smoothed: [UUID: [RSSIPoint]] = [:]
    private(set) var now = Date()
    private(set) var isUnlocking = false
    private(set) var hasPassword = PasswordStore.exists
    private(set) var accessibilityGranted = Accessibility.isTrusted
    private(set) var loginItemEnabled = LoginItem.isEnabled
    private(set) var loginItemNeedsApproval = LoginItem.status == .requiresApproval
    private(set) var legacyAppRunning = LegacyBLEUnlock.runningApp != nil

    @ObservationIgnored private let store = PreferencesStore()
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var lastAutoUnlockAt: Date?
    @ObservationIgnored private var lastLockAt: Date?
    @ObservationIgnored private var mediaPausedByUs = false
    @ObservationIgnored private var bluetoothWasUnavailable = false
    @ObservationIgnored private var warnedMissingPassword = false
    /// 判定離開時因為暫停、切換使用者等原因沒鎖成；條件恢復後要補鎖。
    @ObservationIgnored private var lockOwed = false

    private static let historyDuration: TimeInterval = 180
    private static let lockNotificationID = "presence.locked"

    init() {
        let prefs = PreferencesStore().load()
        preferences = prefs
        group = PresenceGroup(devices: prefs.proximityByDevice, now: Date())
    }

    func start() {
        bluetooth.onSample = { [weak self] id, rssi, date in self?.handleSample(id, rssi, at: date) }
        bluetooth.onAvailabilityChange = { [weak self] availability in self?.handleAvailability(availability) }
        bluetooth.onTargetName = { [weak self] id, name in self?.preferences.rename(id, to: name) }
        bluetooth.targets = Set(preferences.devices.map(\.id))
        bluetooth.activeMode = preferences.activeMode
        bluetooth.start()

        session.onEvent = { [weak self] event in self?.handleSession(event) }
        session.start()

        // 先讀一次密碼：鑰匙圈要問權限的話，讓對話框趁使用者在電腦前時出現，而不是藏在鎖定畫面後面
        if case .needsPermission = PasswordStore.read(allowUI: true) {
            log.add(.warning, "鑰匙圈不允許 Presence 讀取密碼，請到「鎖定與解鎖」重新設定")
        }

        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
        log.add(.info, "Presence 已啟動")
    }

    // MARK: - 顯示用

    var hasDevices: Bool { !preferences.devices.isEmpty }

    /// 訊息裡用來稱呼「你的裝置」：只有一台就用它的名字。
    var subject: String {
        preferences.devices.count == 1 ? preferences.devices[0].displayName : "所有裝置"
    }

    /// 目前判定在附近的裝置名稱。
    var nearDeviceNames: [String] {
        preferences.devices.filter { group.engine(for: $0.id)?.presence == .near }.map(\.displayName)
    }

    func smoothedRSSI(for id: UUID) -> Int? { group.engine(for: id)?.smoothedRSSI }

    /// 所有裝置中最強的濾波後訊號。
    var strongestRSSI: Int? { preferences.devices.compactMap { smoothedRSSI(for: $0.id) }.max() }

    var isPaused: Bool { automation.isPaused(at: now) }

    var status: Status {
        guard hasDevices else { return .needsDevice }
        switch bluetooth.availability {
        case .poweredOn: break
        case .unknown: return .waiting
        default: return .bluetoothUnavailable(bluetooth.availability.description)
        }
        if let until = automation.pausedUntil, now < until { return .paused(until: until) }
        switch group.presence {
        case .unknown: return .waiting
        case .near: return .near
        case .leaving(let since):
            return .leaving(remaining: max(0, group.lockDelay - now.timeIntervalSince(since)))
        case .away(let reason, _): return .away(reason)
        }
    }

    /// 啟動時是否該直接打開主視窗。
    var needsAttentionAtLaunch: Bool { !pendingSetup.isEmpty }

    var pendingSetup: [SetupItem] {
        var items: [SetupItem] = []
        if bluetooth.availability == .unauthorized { items.append(.bluetooth) }
        if !hasDevices { items.append(.device) }
        if preferences.unlockEnabled {
            if !accessibilityGranted { items.append(.accessibility) }
            if !hasPassword { items.append(.password) }
        }
        if legacyAppRunning { items.append(.legacyApp) }
        return items
    }

    // MARK: - 使用者操作

    func lockNow() {
        automation.didLockManually(at: Date())
        lock(reason: nil)
    }

    func resumeAutoUnlock() {
        automation.resetFailures()
        log.add(.info, "已恢復自動解鎖")
    }

    func pause(for duration: TimeInterval) {
        automation.pause(until: Date().addingTimeInterval(duration))
        now = Date()
        log.add(.info, "暫停自動鎖定與解鎖 \(Self.describe(duration))")
    }

    func resume() {
        automation.pause(until: nil)
        now = Date()
        log.add(.info, "恢復自動鎖定與解鎖")
    }

    func addDevice(_ device: BluetoothMonitor.NearbyDevice) {
        preferences.addDevice(id: device.id, name: device.name)
        log.add(.info, "開始監控 \(device.name ?? "未命名裝置")")
    }

    func removeDevice(_ id: UUID) {
        let name = preferences.device(id)?.displayName ?? "未命名裝置"
        preferences.removeDevice(id)
        log.add(.info, "不再監控 \(name)")
    }

    /// 驗證是正確的登入密碼才存進鑰匙圈。
    func setPassword(_ password: String) -> String? {
        guard PasswordStore.verify(password) else { return "密碼不正確，請輸入這個帳號的登入密碼" }
        do {
            try PasswordStore.save(password)
        } catch {
            return "無法存入鑰匙圈：\(error.localizedDescription)"
        }
        hasPassword = true
        warnedMissingPassword = false
        automation.resetFailures()
        log.add(.info, "已更新登入密碼")
        return nil
    }

    func removePassword() {
        PasswordStore.delete()
        hasPassword = false
        log.add(.info, "已移除登入密碼，不會再自動解鎖")
    }

    func setLaunchAtLogin(_ enabled: Bool) -> String? {
        defer { refreshStatus() }
        do {
            try LoginItem.setEnabled(enabled)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func importLegacySettings() {
        guard let imported = LegacyBLEUnlock.imported(into: preferences) else { return }
        preferences = imported
        log.add(.info, "已匯入舊版 BLEUnlock 的設定")
    }

    func quitLegacyApp() {
        LegacyBLEUnlock.runningApp?.terminate()
        Task {
            try? await Task.sleep(for: .seconds(1))
            refreshStatus()
        }
    }

    func refreshStatus() {
        hasPassword = PasswordStore.exists
        accessibilityGranted = Accessibility.isTrusted
        let loginStatus = LoginItem.status
        loginItemEnabled = loginStatus == .enabled
        loginItemNeedsApproval = loginStatus == .requiresApproval
        legacyAppRunning = LegacyBLEUnlock.runningApp != nil
    }

    /// 校準：同時量每台裝置一段時間內的訊號中位數。樣本太少的裝置不會出現在結果裡。
    func measureRSSI(for seconds: Double) async -> [UUID: Int] {
        let start = Date()
        try? await Task.sleep(for: .seconds(seconds))
        var result: [UUID: Int] = [:]
        for (id, points) in samples {
            let values = points.filter { $0.date >= start }.map(\.rssi).sorted()
            if values.count >= 3 { result[id] = values[(values.count - 1) / 2] }
        }
        return result
    }

    // MARK: - 事件處理

    private func tick() {
        let t = Date()
        now = t
        handle(group.tick(at: t))
        payOwedLock()

        var next = automation
        next.observe(group.presence, rearm: ProximitySettings.default.manualLockRearm, at: t)
        if next != automation { automation = next }

        let cutoff = t.addingTimeInterval(-Self.historyDuration)
        for device in preferences.devices {
            if let value = smoothedRSSI(for: device.id) {
                smoothed[device.id, default: []].append(RSSIPoint(date: t, rssi: value))
            }
        }
        for id in samples.keys where samples[id]?.first.map({ $0.date < cutoff }) == true {
            samples[id]?.removeAll { $0.date < cutoff }
        }
        for id in smoothed.keys where smoothed[id]?.first.map({ $0.date < cutoff }) == true {
            smoothed[id]?.removeAll { $0.date < cutoff }
        }

        session.refresh()

        tickCount += 1
        if tickCount.isMultiple(of: 5) { refreshStatus() }
    }

    private func handleSample(_ id: UUID, _ rssi: Int, at date: Date) {
        samples[id, default: []].append(RSSIPoint(date: date, rssi: rssi))
        handle(group.record(device: id, rssi: rssi, at: date))
    }

    /// 只在兩個時機嘗試解鎖（和 BLEUnlock 相同）：判斷邏輯回報「走回來了」（要真的離開過才會再回報），
    /// 或螢幕被喚醒（你碰了鍵盤滑鼠）。不是每秒都試，否則你在座位上按 ⌃⌘Q 鎖定後會立刻被解鎖。
    private func handle(_ change: PresenceChange?) {
        switch change {
        case .departed(let reason): handleDeparture(reason)
        case .arrived: lockOwed = false; evaluateUnlock()
        case nil: break
        }
    }

    private func payOwedLock() {
        guard lockOwed else { return }
        guard case .away(let reason, _) = group.presence else {
            lockOwed = false
            return
        }
        handleDeparture(reason)
    }

    private func handleDeparture(_ reason: DepartureReason) {
        guard hasDevices, preferences.lockEnabled else {
            lockOwed = false
            return
        }
        if ScreenSession.queryLocked() == true {
            lockOwed = false
            return
        }
        guard session.isSessionActive, !session.isSystemSleeping,
              automation.shouldLock(lockEnabled: true, screenLocked: false, at: Date()) else {
            lockOwed = true
            return
        }
        lockOwed = false
        lock(reason: reason)
    }

    /// reason 為 nil 表示使用者手動鎖定。
    private func lock(reason: DepartureReason?) {
        if preferences.pauseMedia, MediaControl.isAudioPlaying() {
            MediaControl.pause()
            // 只有暫停後聲音真的停了，才代表是我們停的；否則（例如視訊會議開著）解鎖後不要亂播
            Task {
                try? await Task.sleep(for: .seconds(1))
                mediaPausedByUs = !MediaControl.isAudioPlaying()
            }
        }
        lastLockAt = Date()
        switch preferences.lockMethod {
        case .lockScreen:
            ScreenControl.lockScreen()
            Task {
                try? await Task.sleep(for: .milliseconds(1500))
                if ScreenSession.queryLocked() == false {
                    log.add(.warning, "鎖定失敗：送出鎖定後螢幕仍未鎖定")
                }
            }
        case .screensaver:
            ScreenControl.startScreensaver()
            // 螢幕保護程式不一定會要求密碼；3 秒後還沒鎖定就直接鎖
            Task {
                try? await Task.sleep(for: .seconds(3))
                if ScreenSession.queryLocked() == false {
                    ScreenControl.lockScreen()
                    log.add(.warning, "螢幕保護程式啟動後沒有鎖定，已改用鎖定螢幕。請到系統設定把「螢幕保護程式啟動或螢幕關閉後要求密碼」設為「立即」。")
                }
            }
        }

        guard let reason else {
            log.add(.locked, "手動鎖定")
            return
        }
        let message = reason == .weakSignal
            ? "\(subject) 離開了，已自動鎖定"
            : "收不到 \(subject) 的訊號，已自動鎖定"
        log.add(.locked, message)
        if preferences.notifyOnLock { Notifier.post("Presence", message, id: Self.lockNotificationID) }
        EventScript.run(reason == .weakSignal ? .away : .lost, rssi: strongestRSSI)
    }

    private func evaluateUnlock() {
        guard !isUnlocking, preferences.unlockEnabled, hasDevices,
              session.isSessionActive, !session.isSystemSleeping else { return }
        guard automation.shouldAttemptUnlock(canUnlock: group.canUnlock, screenLocked: session.isLocked, at: Date()) else { return }
        // 沒開「靠近時喚醒螢幕」：等使用者自己按鍵盤或滑鼠叫醒螢幕才解鎖
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 && !preferences.wakeOnProximity { return }
        guard accessibilityGranted else { return }
        let password: String
        switch PasswordStore.read(allowUI: false) {
        case .success(let value):
            password = value
        case .notFound:
            hasPassword = false
            warnOnce("還沒設定登入密碼，無法自動解鎖")
            return
        case .needsPermission:
            warnOnce("鑰匙圈不允許 Presence 讀取密碼，請到「鎖定與解鎖」重新設定")
            return
        case .failed(let status):
            warnOnce("讀取鑰匙圈失敗（\(status)），這次沒有自動解鎖")
            return
        }

        isUnlocking = true
        automation.didAttemptUnlock(at: Date())
        Task {
            let outcome = await Unlocker.unlock(with: password)
            isUnlocking = false
            switch outcome {
            case .unlocked:
                lastAutoUnlockAt = Date()
                automation.unlockSucceeded()
            case .userIsTyping:
                break
            case .stillLocked:
                automation.unlockAttemptFailed()
                if automation.isBlockedByFailures {
                    log.add(.unlockFailed, "連續 \(Automation.maximumFailures) 次自動解鎖失敗，已停止自動解鎖。如果改過登入密碼，請重新設定；否則可以在「鎖定與解鎖」恢復。")
                } else {
                    log.add(.unlockFailed, "自動解鎖失敗，螢幕仍是鎖定")
                }
            case .interrupted:
                log.add(.info, "輸入途中螢幕已經解鎖或換了畫面，已停止輸入")
            case .displayDidNotWake:
                log.add(.warning, "螢幕沒有亮起，這次沒有解鎖")
            case .noAccessibility:
                accessibilityGranted = false
                log.add(.warning, "沒有輔助使用權限，無法自動解鎖")
            case .notLocked:
                break
            }
        }
    }

    private func handleSession(_ event: ScreenSession.Event) {
        let t = Date()
        switch event {
        case .unlocked:
            let byUs = isUnlocking || (lastAutoUnlockAt.map { t.timeIntervalSince($0) < 10 } ?? false)
            automation.screenDidUnlock()
            lockOwed = false
            Notifier.remove(id: Self.lockNotificationID)
            if byUs {
                let names = nearDeviceNames
                log.add(.unlocked, "\(names.isEmpty ? subject : names.joined(separator: "、")) 在附近，已自動解鎖")
                EventScript.run(.unlocked, rssi: strongestRSSI)
            } else if case .away = group.presence, hasDevices {
                // 可能是你自己用 Touch ID 解鎖、只是裝置訊號太弱，也可能是別人，所以只陳述事實
                log.add(.intruded, "手動解鎖（當時偵測不到\(subject)）")
                EventScript.run(.intruded, rssi: strongestRSSI)
            } else {
                log.add(.manualUnlock, "手動解鎖")
            }
            if mediaPausedByUs {
                mediaPausedByUs = false
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    MediaControl.play()
                }
            }
        case .locked:
            if let last = lastLockAt, t.timeIntervalSince(last) < 5 { break }
            log.add(.locked, "螢幕已鎖定")
        case .displayWoke:
            evaluateUnlock()
        case .systemWillSleep, .systemDidWake:
            // 睡眠前後的訊號都不可信，要重新收集
            group.reset(at: t)
        case .displaySlept, .sessionResigned, .sessionActivated:
            break
        }
    }

    private func handleAvailability(_ availability: BluetoothMonitor.Availability) {
        if availability == .poweredOn {
            if bluetoothWasUnavailable { log.add(.info, "藍牙已恢復") }
            bluetoothWasUnavailable = false
            return
        }
        guard availability != .unknown, availability != .resetting else { return }
        group.reset(at: Date())
        if !bluetoothWasUnavailable {
            bluetoothWasUnavailable = true
            log.add(.warning, "藍牙\(availability.description)。收不到訊號超過逾時時間後會自動鎖定。")
        }
    }

    private func warnOnce(_ message: String) {
        guard !warnedMissingPassword else { return }
        warnedMissingPassword = true
        log.add(.warning, message)
    }

    private func apply(changesFrom old: Preferences) {
        let proximity = preferences.proximityByDevice
        if proximity != old.proximityByDevice {
            group.configure(proximity, now: Date())
        }
        let ids = Set(preferences.devices.map(\.id))
        if ids != Set(old.devices.map(\.id)) {
            bluetooth.targets = ids
            for id in samples.keys where !ids.contains(id) { samples[id] = nil }
            for id in smoothed.keys where !ids.contains(id) { smoothed[id] = nil }
        }
        if preferences.activeMode != old.activeMode {
            bluetooth.activeMode = preferences.activeMode
        }
    }

    static func describe(_ duration: TimeInterval) -> String {
        let minutes = Int(duration / 60)
        if minutes < 60 { return "\(minutes) 分鐘" }
        if minutes % 60 == 0 { return "\(minutes / 60) 小時" }
        return "\(minutes / 60) 小時 \(minutes % 60) 分鐘"
    }
}
