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

    private(set) var engine: PresenceEngine
    private(set) var automation = Automation()
    private(set) var samples: [RSSIPoint] = []
    private(set) var smoothed: [RSSIPoint] = []
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
        engine = PresenceEngine(settings: prefs.proximity, now: Date())
    }

    func start() {
        bluetooth.onSample = { [weak self] rssi, date in self?.handleSample(rssi, at: date) }
        bluetooth.onAvailabilityChange = { [weak self] availability in self?.handleAvailability(availability) }
        bluetooth.onTargetName = { [weak self] name in self?.rememberTargetName(name) }
        bluetooth.target = preferences.targetID
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

    var targetDisplayName: String { preferences.targetName ?? "你的裝置" }

    var isPaused: Bool { automation.isPaused(at: now) }

    var status: Status {
        guard preferences.targetID != nil else { return .needsDevice }
        switch bluetooth.availability {
        case .poweredOn: break
        case .unknown: return .waiting
        default: return .bluetoothUnavailable(bluetooth.availability.description)
        }
        if let until = automation.pausedUntil, now < until { return .paused(until: until) }
        switch engine.presence {
        case .unknown: return .waiting
        case .near: return .near
        case .leaving(let since):
            return .leaving(remaining: max(0, preferences.lockDelay - now.timeIntervalSince(since)))
        case .away(let reason, _): return .away(reason)
        }
    }

    /// 啟動時是否該直接打開主視窗。
    var needsAttentionAtLaunch: Bool {
        preferences.targetID == nil || !pendingSetup.isEmpty
    }

    var pendingSetup: [SetupItem] {
        var items: [SetupItem] = []
        if bluetooth.availability == .unauthorized { items.append(.bluetooth) }
        if preferences.targetID == nil { items.append(.device) }
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

    func select(_ device: BluetoothMonitor.NearbyDevice) {
        preferences.targetID = device.id
        preferences.targetName = device.name
        log.add(.info, "監控裝置改為 \(device.name ?? "未命名裝置")")
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

    /// 校準：量一段時間內目標裝置的訊號中位數。樣本太少回傳 nil。
    func measureRSSI(for seconds: Double) async -> Int? {
        let start = Date()
        try? await Task.sleep(for: .seconds(seconds))
        let values = samples.filter { $0.date >= start }.map(\.rssi).sorted()
        guard values.count >= 3 else { return nil }
        return values[values.count / 2]
    }

    // MARK: - 事件處理

    private func tick() {
        let t = Date()
        now = t
        handle(engine.tick(at: t))
        payOwedLock()

        var next = automation
        next.observe(engine.presence, rearm: preferences.proximity.manualLockRearm, at: t)
        if next != automation { automation = next }

        if let value = engine.smoothedRSSI { smoothed.append(RSSIPoint(date: t, rssi: value)) }
        let cutoff = t.addingTimeInterval(-Self.historyDuration)
        if let first = samples.first, first.date < cutoff { samples.removeAll { $0.date < cutoff } }
        if let first = smoothed.first, first.date < cutoff { smoothed.removeAll { $0.date < cutoff } }

        session.refresh()

        tickCount += 1
        if tickCount.isMultiple(of: 5) { refreshStatus() }
    }

    private func handleSample(_ rssi: Int, at date: Date) {
        samples.append(RSSIPoint(date: date, rssi: rssi))
        handle(engine.record(rssi: rssi, at: date))
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
        guard case .away(let reason, _) = engine.presence else {
            lockOwed = false
            return
        }
        handleDeparture(reason)
    }

    private func handleDeparture(_ reason: DepartureReason) {
        guard preferences.targetID != nil, preferences.lockEnabled else {
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
            ? "\(targetDisplayName) 離開了，已自動鎖定"
            : "收不到 \(targetDisplayName) 的訊號，已自動鎖定"
        log.add(.locked, message)
        if preferences.notifyOnLock { Notifier.post("Presence", message, id: Self.lockNotificationID) }
        EventScript.run(reason == .weakSignal ? .away : .lost, rssi: engine.smoothedRSSI)
    }

    private func evaluateUnlock() {
        guard !isUnlocking, preferences.unlockEnabled, preferences.targetID != nil,
              session.isSessionActive, !session.isSystemSleeping else { return }
        guard automation.shouldAttemptUnlock(canUnlock: engine.canUnlock, screenLocked: session.isLocked, at: Date()) else { return }
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
                log.add(.unlocked, "\(targetDisplayName) 在附近，已自動解鎖")
                EventScript.run(.unlocked, rssi: engine.smoothedRSSI)
            } else if case .away = engine.presence, preferences.targetID != nil {
                log.add(.intruded, "\(targetDisplayName) 不在附近時，這台 Mac 被手動解鎖了")
                EventScript.run(.intruded, rssi: engine.smoothedRSSI)
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
            engine.reset(at: t)
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
        engine.reset(at: Date())
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

    private func rememberTargetName(_ name: String) {
        if preferences.targetName != name { preferences.targetName = name }
    }

    private func apply(changesFrom old: Preferences) {
        if preferences.proximity != old.proximity {
            engine.update(settings: preferences.proximity)
        }
        if preferences.targetID != old.targetID {
            bluetooth.target = preferences.targetID
            engine.reset(at: Date())
            samples.removeAll()
            smoothed.removeAll()
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
