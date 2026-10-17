import AppKit
import Observation
import PresenceCore
import PresenceLink

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
        /// 從 iPhone 或手錶簡報中：自動鎖定與解鎖暫停到 until。
        case presenting(until: Date)
        case suspended(ContextRules.Suspension, unlockToo: Bool)
        case lockPending(userActive: Bool)
        case waiting
        case near
        case leaving(remaining: TimeInterval)
        case away(DepartureReason)

        var title: String {
            switch self {
            case .needsDevice: String(localized: "還沒選擇裝置")
            case .bluetoothUnavailable(let reason): String(localized: "藍牙\(reason)")
            case .paused: String(localized: "已暫停")
            case .presenting: String(localized: "簡報中")
            case .suspended(let reason, let unlockToo):
                unlockToo
                    ? String(localized: "\(Self.describe(reason))，暫停自動鎖定與解鎖")
                    : String(localized: "\(Self.describe(reason))，暫停自動鎖定")
            case .lockPending(true): String(localized: "偵測到你還在操作，暫緩鎖定")
            case .lockPending(false): String(localized: "即將鎖定")
            case .waiting: String(localized: "等待訊號")
            case .near: String(localized: "在附近")
            case .leaving(let remaining): String(localized: "離開中，\(Int(remaining.rounded(.up))) 秒後鎖定")
            case .away(.weakSignal): String(localized: "不在附近")
            case .away(.signalLost): String(localized: "收不到訊號")
            }
        }

        var symbol: String {
            switch self {
            case .needsDevice: "questionmark.circle"
            case .bluetoothUnavailable: "exclamationmark.triangle"
            case .paused: "pause.circle"
            case .presenting: "play.rectangle"
            case .suspended(.presenting, _): "play.rectangle"
            case .suspended(.trustedNetwork, _): "house.circle"
            case .suspended(.onACPower, _): "powerplug"
            case .suspended(.outsideSchedule, _): "calendar.badge.clock"
            case .lockPending: "hourglass"
            case .waiting: "ellipsis.circle"
            case .near: "iphone.radiowaves.left.and.right"
            case .leaving: "figure.walk.departure"
            case .away: "iphone.slash"
            }
        }

        static func describe(_ reason: ContextRules.Suspension) -> String {
            switch reason {
            case .presenting(let app): String(localized: "「\(app)」正在播放簡報")
            case .trustedNetwork(let name): String(localized: "在「\(name)」")
            case .onACPower: String(localized: "接著電源")
            case .outsideSchedule: String(localized: "不在設定的時段")
            }
        }
    }

    enum SetupItem: String, CaseIterable, Identifiable {
        case bluetooth, device, accessibility, password, legacyApp, location
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
    /// 示範模式的紀錄不存檔（見 Demo）。
    let log = Demo.isActive ? EventLog(directory: nil) : EventLog()
    /// 讓 iPhone 與 Apple Watch 的 Presence Remote 連進來。
    let link = LinkService()

    private(set) var group: PresenceGroup
    private(set) var automation = Automation()
    /// 每台裝置最近 3 分鐘收到的訊號，以及每秒一點的濾波結果（給訊號圖用）。
    private(set) var samples: [UUID: [RSSIPoint]] = [:]
    private(set) var smoothed: [UUID: [RSSIPoint]] = [:]
    private(set) var now = Date()
    /// 選單列圖示。只在真的換了時才更新：`status` 會讀 `now`，直接讀它會讓選單列每秒重畫。
    private(set) var menuBarSymbol = "ellipsis.circle"
    /// 這台 Mac 的名稱。`Host.current()` 很慢，啟動時查一次就好。
    private static let macName = Demo.isActive ? "MacBook Pro" : Host.current().localizedName ?? "Mac"
    private(set) var isUnlocking = false
    /// 正在自動解鎖的前半段：等 macOS 自己解鎖、等 iPhone 的加密確認。
    private(set) var isConfirmingPresence = false
    /// 已叫醒螢幕，正在給 Apple Watch（或你的 Touch ID）先解鎖的機會。
    private var isWaitingForSystemUnlock = false
    /// 這次自動解鎖是誰加密確認的，寫進事件紀錄用。
    private var unlockConfirmedBy: String?
    /// 上次加密確認失敗的時間：之後一分鐘內只在 iPhone 連上時重試，
    /// 否則「失敗 → 叫醒螢幕 → 螢幕亮起又試一次」會一直循環。
    private var lastUnconfirmedAt: Date?
    private var lastUnconfirmedWarningAt: Date?
    private(set) var hasPassword = PasswordStore.exists
    private(set) var accessibilityGranted = Accessibility.isTrusted
    private(set) var loginItemEnabled = LoginItem.isEnabled
    private(set) var loginItemNeedsApproval = LoginItem.status == .requiresApproval
    private(set) var legacyAppRunning = LegacyBLEUnlock.runningApp != nil
    private(set) var hotKeyConflict = false
    /// 在座時間紀錄。
    private(set) var deskTime = DeskTimeStore.load()
    /// 已判定離開、但還在等（使用者仍在操作，或倒數通知中）的鎖定。
    private(set) var pendingLock: PendingLock?
    /// 簡報開始時設的暫停到期時間（見 isPresenting）。
    private var presentingUntil: Date?
    /// 簡報計時：手機設定，Mac 轉給所有連著的手機與手錶（見 LinkCommand.presentationTimer）。
    private var presentationStartedAt: Date?
    private var presentationMinutes: Int?
    /// 要畫雷射筆的螢幕寬高比，幾秒查一次（見 pointerScreenAspect）。
    @ObservationIgnored private var screenAspectCache: (aspect: Double, at: Date)?
    private(set) var currentNetwork: NetworkIdentity.Current?
    /// 正在播放簡報的 App（見 PresentationDetector）。
    private(set) var presentingApp: String?
    private(set) var onACPower = PowerSource.isOnACPower
    let hasBattery = PowerSource.hasBattery

    @ObservationIgnored private let store: PreferencesStore
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var tickCount = 0
    @ObservationIgnored private var lastAutoUnlockAt: Date?
    @ObservationIgnored private var lastLockAt: Date?
    @ObservationIgnored private var mediaPausedByUs = false
    @ObservationIgnored private var bluetoothWasUnavailable = false
    @ObservationIgnored private var warnedMissingPassword = false
    /// 判定離開時因為暫停、切換使用者等原因沒鎖成；條件恢復後要補鎖。
    @ObservationIgnored private var lockOwed = false
    @ObservationIgnored private var lastSuspension: ContextRules.Suspension?
    /// 這次的鎖定是 Presence 做的：解鎖時要執行「回來時」的捷徑。
    @ObservationIgnored private var lockedByPresence = false
    /// 上次推送給 iPhone／手錶的狀態摘要；有變才推送。
    @ObservationIgnored private var lastLinkSignature = ""

    /// 給「捷徑」動作用：App 啟動後指向唯一的 AppModel。
    static weak var current: AppModel?

    struct PendingLock: Equatable {
        let reason: DepartureReason
        let since: Date
        var warnedAt: Date?
        var loggedActivity = false
    }

    private static let historyDuration: TimeInterval = 180
    private static let lockNotificationID = "presence.locked"
    private static let warningNotificationID = "presence.lock-warning"
    /// 最近這麼多秒內有操作鍵盤或滑鼠，就算「還在操作」。
    private static let activityWindow: TimeInterval = 10
    /// 再怎麼操作，判定離開後最多暫緩這麼久就一定鎖定（避免別人一直動滑鼠讓它不鎖）。
    private static let activityCap: TimeInterval = 120
    /// 鎖定前通知的倒數秒數。
    private static let warningDuration: TimeInterval = 10

    init() {
        #if DEBUG
        store = Demo.isActive ? PreferencesStore(defaults: Demo.defaults) : PreferencesStore()
        let prefs = Demo.isActive ? Demo.preferences : store.load()
        #else
        store = PreferencesStore()
        let prefs = store.load()
        #endif
        preferences = prefs
        group = PresenceGroup(devices: prefs.proximityByDevice, policy: prefs.devicePolicy, now: Date())
    }

    func start(afterUnexpectedExit: Bool = false) {
        Self.current = self
        HotKeyCenter.shared.onPress = { [weak self] in self?.lockNow() }
        registerHotKey()
        bluetooth.onSample = { [weak self] id, rssi, date in self?.handleSample(id, rssi, at: date) }
        bluetooth.onAvailabilityChange = { [weak self] availability in self?.handleAvailability(availability) }
        bluetooth.onTargetName = { [weak self] id, name in self?.preferences.fillName(id, with: name) }
        bluetooth.targets = Set(preferences.devices.map(\.id))
        bluetooth.activeMode = preferences.activeMode
        bluetooth.start()

        session.onEvent = { [weak self] event in self?.handleSession(event) }
        session.start()
        link.statusProvider = { [weak self] in self?.linkStatus ?? LinkStatus(macName: "Mac", presence: .waiting, summary: "", locked: false) }
        link.onCommand = { [weak self] command in self?.handleRemote(command) ?? nil }
        link.onPointer = { [weak self] update in self?.showPointer(update) }
        link.onDeviceConnected = { [weak self] _ in self?.companionDidConnect() }
        link.start()

        // 先讀一次密碼：鑰匙圈要問權限的話，讓對話框趁使用者在電腦前時出現，而不是藏在鎖定畫面後面
        if case .needsPermission = PasswordStore.read(allowUI: true) {
            log.add(.warning, String(localized: "鑰匙圈不允許 Presence 讀取密碼，請到「鎖定與解鎖」重新設定"))
        }

        Task { await refreshNetwork() }
        CameraCapture.removePhotos(olderThan: 30)

        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
        if preferences.unlockEnabled, preferences.unlockMode == .typePassword, !Accessibility.isTrusted {
            log.add(.warning, String(localized: "沒有輔助使用權限，無法自動解鎖。請到「系統設定 › 隱私權與安全性 › 輔助使用」打開 Presence"))
        }
        if afterUnexpectedExit {
            log.add(.warning, String(localized: "Presence 上次沒有正常結束（可能是當機或被系統結束），已重新開啟"))
        }
        log.add(.info, String(localized: "Presence 已啟動"))
        #if DEBUG
        // 開發用：-PresenceTestConfirmation YES 等 iPhone 連上（最多 90 秒）後測一次加密確認，不用鎖定 Mac
        if UserDefaults.standard.bool(forKey: "PresenceTestConfirmation") {
            Task {
                for _ in 0..<90 where link.connected.isEmpty {
                    try? await Task.sleep(for: .seconds(1))
                }
                _ = await testCompanionConfirmation()
            }
        }
        #endif
    }

    // MARK: - 顯示用

    var hasDevices: Bool { !preferences.devices.isEmpty }

    /// 訊息裡用來稱呼「你的裝置」：只有一台就用它的名字。
    var subject: String {
        preferences.devices.count == 1 ? preferences.devices[0].displayName : String(localized: "所有裝置")
    }

    /// 目前判定在附近的裝置名稱。
    var nearDeviceNames: [String] {
        preferences.devices.filter { group.engine(for: $0.id)?.presence == .near }.map(\.displayName)
    }

    func smoothedRSSI(for id: UUID) -> Int? { group.engine(for: id)?.smoothedRSSI }

    /// 所有裝置中最強的濾波後訊號。
    var strongestRSSI: Int? { preferences.devices.compactMap { smoothedRSSI(for: $0.id) }.max() }

    var isPaused: Bool { automation.isPaused(at: now) }

    /// 一行文字的狀態，給選單列和「捷徑」用，例如「Weichung 在附近 · -52 dBm」。
    var statusLine: String {
        let status = status
        guard hasDevices else { return status.title }
        let rssi = strongestRSSI.map { " · \($0) dBm" } ?? ""
        if status == .near {
            return String(localized: "\(Self.list(nearDeviceNames)) 在附近\(rssi)")
        }
        if case .suspended = status { return status.title }
        return String(localized: "\(subject)：\(status.title)\(rssi)")
    }

    /// 依情境暫停自動鎖定的原因；nil 表示照常。
    var suspension: ContextRules.Suspension? {
        preferences.context.suspension(in: .init(networkID: currentNetwork?.id, onACPower: onACPower, date: now,
                                                 presentingApp: presentingApp))
    }

    var status: Status {
        guard hasDevices else { return .needsDevice }
        switch bluetooth.availability {
        case .poweredOn: break
        case .unknown: return .waiting
        default: return .bluetoothUnavailable(bluetooth.availability.description)
        }
        if let until = automation.pausedUntil, now < until { return isPresenting ? .presenting(until: until) : .paused(until: until) }
        if let reason = suspension {
            return .suspended(reason, unlockToo: preferences.context.alsoSuspendUnlock)
        }
        if pendingLock != nil {
            return .lockPending(userActive: Self.idleSeconds < Self.activityWindow)
        }
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
        if preferences.unlockEnabled, preferences.unlockMode == .typePassword {
            if !accessibilityGranted { items.append(.accessibility) }
            if !hasPassword { items.append(.password) }
        }
        if legacyAppRunning { items.append(.legacyApp) }
        if !InstallLocation.isInApplications, !Demo.isActive { items.append(.location) }
        return items
    }

    // MARK: - 使用者操作

    func lockNow() {
        cancelPendingLock()
        automation.didLockManually(at: Date())
        lock(reason: nil)
    }

    func resumeAutoUnlock() {
        automation.resetFailures()
        log.add(.info, String(localized: "已恢復自動解鎖"))
    }

    func pause(for duration: TimeInterval) {
        automation.pause(until: Date().addingTimeInterval(duration))
        now = Date()
        log.add(.info, String(localized: "暫停自動鎖定與解鎖 \(Self.describe(duration))"))
    }

    func resume() {
        automation.pause(until: nil)
        now = Date()
        log.add(.info, String(localized: "恢復自動鎖定與解鎖"))
    }

    func trustCurrentNetwork(named name: String) {
        guard let network = currentNetwork, !preferences.context.trustedNetworks.contains(where: { $0.id == network.id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        preferences.context.trustedNetworks.append(.init(id: network.id, name: trimmed.isEmpty ? (network.ssid ?? String(localized: "信任的網路")) : trimmed))
    }

    func refreshNetwork() async {
        if Demo.isActive { return }
        let network = await NetworkIdentity.current()
        if network != currentNetwork { currentNetwork = network }
    }

    func addDevice(_ device: BluetoothMonitor.NearbyDevice) {
        preferences.addDevice(id: device.id, name: device.name)
        log.add(.info, String(localized: "開始監控 \(device.name ?? MonitoredDevice.unnamed)"))
    }

    func removeDevice(_ id: UUID) {
        let name = preferences.device(id)?.displayName ?? String(localized: "未命名裝置")
        preferences.removeDevice(id)
        log.add(.info, String(localized: "不再監控 \(name)"))
    }

    /// 驗證是正確的登入密碼才存進鑰匙圈。
    func setPassword(_ password: String) -> String? {
        guard PasswordStore.verify(password) else { return String(localized: "密碼不正確，請輸入這個帳號的登入密碼") }
        do {
            try PasswordStore.save(password)
        } catch {
            return String(localized: "無法存入鑰匙圈：\(error.localizedDescription)")
        }
        hasPassword = true
        warnedMissingPassword = false
        automation.resetFailures()
        log.add(.info, String(localized: "已更新登入密碼"))
        return nil
    }

    func removePassword() {
        PasswordStore.delete()
        hasPassword = false
        log.add(.info, String(localized: "已移除登入密碼，不會再自動解鎖"))
    }

    func setLaunchAtLogin(_ enabled: Bool) -> String? {
        defer { refreshStatus() }
        do {
            if enabled {
                // 註冊後 launchd 會立刻開一個新的 Presence 接手（這個會被結束），請它回到設定頁
                AppInstance.requestWindowAfterHandoff()
                try LoginItem.register()
            } else if LoginItem.isRunningAsAgent {
                // 取消註冊會連同目前這個程序一起結束：先開一個一般的 Presence 接手，由它取消註冊
                Task {
                    try? await AppInstance.relaunch(arguments: ["-PresenceUnregisterAgent", "YES",
                                                                "-PresenceInitialSection", MainView.Section.general.rawValue])
                }
            } else {
                try LoginItem.unregister()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// 複製到「應用程式」並從那裡重新開啟；新的那個會結束目前這個。
    func moveToApplications() async -> String? {
        do {
            let url = try InstallLocation.copyToApplications()
            var arguments = ["-PresenceInitialSection", MainView.Section.overview.rawValue]
            if LoginItem.isEnabled { arguments += ["-PresenceReregisterAgent", "YES"] }
            try await AppInstance.relaunch(url, arguments: arguments)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func importLegacySettings() {
        guard let imported = LegacyBLEUnlock.imported(into: preferences) else { return }
        preferences = imported
        log.add(.info, String(localized: "已匯入舊版 BLEUnlock 的設定"))
    }

    func quitLegacyApp() {
        LegacyBLEUnlock.runningApp?.terminate()
        Task {
            try? await Task.sleep(for: .seconds(1))
            refreshStatus()
        }
    }

    func refreshStatus() {
        if Demo.isActive {
            hasPassword = true
            accessibilityGranted = true
            loginItemEnabled = true
            loginItemNeedsApproval = false
            legacyAppRunning = false
            return
        }
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
        let power = PowerSource.isOnACPower
        if power != onACPower { onACPower = power }
        if tickCount.isMultiple(of: 15) { Task { await refreshNetwork() } }
        if tickCount.isMultiple(of: 2), !Demo.isActive {
            let app = PresentationDetector.presentingApp()
            if app != presentingApp { presentingApp = app }
        }
        noteSuspensionChange()
        handle(group.tick(at: t))
        payOwedLock()
        processPendingLock()
        updateDeskTime(at: t)
        pushLinkStatusIfChanged()

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
        let symbol = status.symbol
        if symbol != menuBarSymbol { menuBarSymbol = symbol }

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
        guard session.isSessionActive, !session.isSystemSleeping, suspension == nil,
              automation.shouldLock(lockEnabled: true, screenLocked: false, at: Date()) else {
            lockOwed = true
            return
        }
        lockOwed = false
        beginPendingLock(reason)
    }

    private func beginPendingLock(_ reason: DepartureReason) {
        guard pendingLock == nil else { return }
        pendingLock = PendingLock(reason: reason, since: Date())
        processPendingLock()
    }

    private func cancelPendingLock() {
        guard pendingLock != nil else { return }
        pendingLock = nil
        Notifier.remove(id: Self.warningNotificationID)
    }

    /// 判定離開後真正鎖定之前：使用者還在操作就暫緩（有上限），開了倒數通知就先通知。
    private func processPendingLock() {
        guard var pending = pendingLock else { return }
        let t = Date()
        guard case .away = group.presence, ScreenSession.queryLocked() != true else {
            cancelPendingLock()
            return
        }
        // 暫停、切換使用者或情境改變：改成條件恢復後補鎖
        guard session.isSessionActive, !session.isSystemSleeping, suspension == nil,
              automation.shouldLock(lockEnabled: preferences.lockEnabled, screenLocked: false, at: t) else {
            cancelPendingLock()
            lockOwed = preferences.lockEnabled
            return
        }

        let waitForActivity = preferences.stayUnlockedWhileActive || preferences.warnBeforeLock
        if waitForActivity, t.timeIntervalSince(pending.since) < Self.activityCap, Self.idleSeconds < Self.activityWindow {
            // 已經發出倒數通知後又有操作，就當作取消倒數，等操作停下來再重新開始
            if pending.warnedAt != nil {
                pending.warnedAt = nil
                Notifier.remove(id: Self.warningNotificationID)
            }
            if !pending.loggedActivity {
                pending.loggedActivity = true
                log.add(.info, String(localized: "\(subject) 已離開，但偵測到你還在操作，暫緩鎖定"))
            }
            pendingLock = pending
            return
        }
        if preferences.warnBeforeLock {
            guard let warnedAt = pending.warnedAt else {
                pending.warnedAt = t
                pendingLock = pending
                Notifier.post("Presence", String(localized: "10 秒後鎖定這台 Mac，動一下滑鼠或鍵盤可以取消"), id: Self.warningNotificationID)
                return
            }
            if t.timeIntervalSince(warnedAt) < Self.warningDuration { return }
        }
        pendingLock = nil
        Notifier.remove(id: Self.warningNotificationID)
        lock(reason: pending.reason)
    }

    /// 距離上次操作鍵盤、滑鼠或觸控板過了幾秒。
    static var idleSeconds: TimeInterval {
        if Demo.isActive { return .infinity }
        let types: [CGEventType] = [.keyDown, .flagsChanged, .mouseMoved, .leftMouseDown, .rightMouseDown,
                                    .otherMouseDown, .leftMouseDragged, .scrollWheel]
        return types.map { CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0) }.min() ?? .infinity
    }

    private func updateDeskTime(at t: Date) {
        let atDesk = group.presence == .near && !session.isSystemSleeping
        deskTime.update(near: atDesk, at: t)
        if preferences.sittingReminderEnabled,
           deskTime.shouldRemind(every: preferences.sittingReminderInterval, at: t) {
            Notifier.post(String(localized: "該起來走走了"),
                          String(localized: "你已經連續坐了 \(Self.describe(deskTime.currentDuration(at: t)))"))
        }
        if tickCount.isMultiple(of: 60) { DeskTimeStore.save(deskTime) }
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
        lockedByPresence = true
        if let name = preferences.shortcutOnLeave { ShortcutsRunner.run(name) }
        switch preferences.lockMethod {
        case _ where Demo.isActive:
            ScreenSession.demoLocked = true
        case .lockScreen:
            ScreenControl.lockScreen()
            Task {
                try? await Task.sleep(for: .milliseconds(1500))
                if ScreenSession.queryLocked() == false {
                    log.add(.warning, String(localized: "鎖定失敗：送出鎖定後螢幕仍未鎖定"))
                }
            }
        case .screensaver:
            ScreenControl.startScreensaver()
            // 螢幕保護程式不一定會要求密碼；3 秒後還沒鎖定就直接鎖
            Task {
                try? await Task.sleep(for: .seconds(3))
                if ScreenSession.queryLocked() == false {
                    ScreenControl.lockScreen()
                    log.add(.warning, String(localized: "螢幕保護程式啟動後沒有鎖定，已改用鎖定螢幕。請到系統設定把「螢幕保護程式啟動或螢幕關閉後要求密碼」設為「立即」。"))
                }
            }
        }

        link.broadcast(event: reason == nil ? .lockedManually : .lockedAway)
        guard let reason else {
            log.add(.locked, String(localized: "手動鎖定"))
            return
        }
        let message = reason == .weakSignal
            ? String(localized: "\(subject) 離開了，已自動鎖定")
            : String(localized: "收不到 \(subject) 的訊號，已自動鎖定")
        log.add(.locked, message)
        if preferences.notifyOnLock { Notifier.post("Presence", message, id: Self.lockNotificationID) }
        EventScript.run(reason == .weakSignal ? .away : .lost, rssi: strongestRSSI)
    }

    /// 自動輸入密碼前要不要先等 iPhone 的加密確認。
    var requiresCompanionConfirmation: Bool {
        preferences.requireCompanionConfirmation && !link.devices.isEmpty
            && preferences.unlockEnabled && preferences.unlockMode == .typePassword
    }

    private func evaluateUnlock(afterCompanionConnected: Bool = false) {
        guard !isUnlocking, !isConfirmingPresence, preferences.unlockEnabled, hasDevices,
              session.isSessionActive, !session.isSystemSleeping else { return }
        guard automation.shouldAttemptUnlock(canUnlock: group.canUnlock, screenLocked: session.isLocked, at: Date()) else { return }
        if preferences.context.alsoSuspendUnlock, suspension != nil { return }
        #if DEBUG
        if Demo.isActive {
            demoUnlock()
            return
        }
        #endif
        if preferences.unlockMode == .handOff {
            // 不碰密碼：喚醒螢幕，讓 macOS 內建的 Apple Watch 解鎖或 Touch ID 接手
            automation.didAttemptUnlock(at: Date())
            guard CGDisplayIsAsleep(CGMainDisplayID()) != 0, preferences.wakeOnProximity else { return }
            Unlocker.dismissScreensaver()
            ScreenControl.keepDisplayAwake(for: 60)
            ScreenControl.wakeDisplay()
            log.add(.info, String(localized: "\(Self.list(nearDeviceNames)) 在附近，已喚醒螢幕"))
            return
        }
        // 沒開「靠近時喚醒螢幕」：等使用者自己按鍵盤或滑鼠叫醒螢幕才解鎖
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 && !preferences.wakeOnProximity { return }
        guard accessibilityGranted else { return }
        if requiresCompanionConfirmation, !afterCompanionConnected,
           let last = lastUnconfirmedAt, Date().timeIntervalSince(last) < 60 { return }
        automation.didAttemptUnlock(at: Date())

        isConfirmingPresence = true
        Task {
            // iPhone 的加密確認跟下面等 Apple Watch 同時進行，不多花時間
            let confirmation = requiresCompanionConfirmation
                ? Task { await link.confirmPresence(within: Self.confirmationTimeout) } : nil
            if await waitForSystemUnlock() {
                link.cancelPresenceConfirmation()
                isConfirmingPresence = false
                return
            }
            var confirmedBy: String?
            if let confirmation {
                let result = await confirmation.value
                guard case .confirmed(let name) = result else {
                    isConfirmingPresence = false
                    handleUnconfirmed(result)
                    return
                }
                confirmedBy = name
                lastUnconfirmedAt = nil
            }
            isConfirmingPresence = false
            // 等的期間可能已經被你自己解鎖，或裝置又離開了
            guard session.isLocked, group.canUnlock else { return }
            typePassword(confirmedBy: confirmedBy)
        }
    }

    /// 開了「用 Apple Watch 解鎖」的話，螢幕一亮 macOS 就會自己解鎖（實測 2.1 到 3.0 秒）。
    /// 先給它這個機會，太早打字只會跟它搶。預設等 5 秒；連續 3 次都是 Presence 打字才解開，
    /// 代表這台 Mac 沒用手錶解鎖，就只等 1.5 秒。之後只要再看到系統自己解開，就恢復 5 秒。
    private var systemUnlockHeadStart: Duration {
        UserDefaults.standard.integer(forKey: Self.typedStreakKey) >= 3 ? .milliseconds(1500) : .seconds(5)
    }

    private static let typedStreakKey = "unlock.typedWithoutSystemStreak"

    private func noteSystemUnlock(_ happened: Bool) {
        let defaults = UserDefaults.standard
        defaults.set(happened ? 0 : defaults.integer(forKey: Self.typedStreakKey) + 1, forKey: Self.typedStreakKey)
    }

    /// 叫醒螢幕並等一下，期間被解開（Apple Watch 或你的 Touch ID）就回傳 true。
    private func waitForSystemUnlock() async -> Bool {
        isWaitingForSystemUnlock = true
        defer { isWaitingForSystemUnlock = false }
        Unlocker.dismissScreensaver()
        ScreenControl.keepDisplayAwake(for: 60)
        ScreenControl.wakeDisplay()
        let deadline = ContinuousClock.now + systemUnlockHeadStart
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            if ScreenSession.queryLocked() == false {
                noteSystemUnlock(true)
                return true
            }
        }
        return false
    }

    /// 最多等多久：比解鎖嘗試的間隔（10 秒）長，之後才連上的裝置可以重試（見 companionDidConnect）。
    private static let confirmationTimeout: TimeInterval = 12

    private func handleUnconfirmed(_ result: LinkService.PresenceConfirmation) {
        let now = Date()
        lastUnconfirmedAt = now
        // 你坐在鎖著的 Mac 前、iPhone 一直沒連上時，每分鐘都會再試；警告十分鐘記一次就好
        if let last = lastUnconfirmedWarningAt, now.timeIntervalSince(last) < 600 {
            wakeForManualUnlock()
            return
        }
        lastUnconfirmedWarningAt = now
        let message = switch result {
        case .noDevice:
            String(localized: "已配對的 iPhone 沒有連上，無法加密確認，這次不自動解鎖。可以用 Apple Watch、Touch ID 或密碼解鎖。")
        default:
            String(localized: "iPhone 沒有回應加密確認，這次不自動解鎖。請確認 iPhone 上的 Presence Remote 沒有被關掉，而且是最新版。")
        }
        log.add(.warning, message)
        wakeForManualUnlock()
    }

    /// 沒有自動解鎖時叫醒螢幕，讓你可以馬上用 Apple Watch 或 Touch ID 解鎖。
    private func wakeForManualUnlock() {
        guard preferences.wakeOnProximity, session.isLocked else { return }
        Unlocker.dismissScreensaver()
        ScreenControl.keepDisplayAwake(for: 60)
        ScreenControl.wakeDisplay()
    }

    /// 「手機與手錶」頁的測試按鈕：跟解鎖前一樣請 iPhone 加密確認，回傳結果並寫進紀錄。
    func testCompanionConfirmation() async -> String {
        let started = Date()
        let result = await link.confirmPresence(within: Self.confirmationTimeout)
        let message = switch result {
        case .confirmed(let name):
            String(localized: "\(name) 已加密確認（\(Int(Date().timeIntervalSince(started) * 1000)) 毫秒）")
        case .noDevice:
            String(localized: "沒有已配對的 iPhone 連上")
        case .noResponse:
            String(localized: "iPhone 連著但沒有回應，請更新 Presence Remote")
        }
        log.add(.info, String(localized: "測試加密確認：\(message)"))
        return message
    }

    /// 確認失敗後一分鐘內 iPhone 才連上：再試一次。
    private func companionDidConnect() {
        guard let last = lastUnconfirmedAt, Date().timeIntervalSince(last) < 60 else { return }
        evaluateUnlock(afterCompanionConnected: true)
    }

    private func typePassword(confirmedBy: String?) {
        let password: String
        switch PasswordStore.read(allowUI: false) {
        case .success(let value):
            password = value
        case .notFound:
            hasPassword = false
            warnOnce(String(localized: "還沒設定登入密碼，無法自動解鎖"))
            return
        case .needsPermission:
            warnOnce(String(localized: "鑰匙圈不允許 Presence 讀取密碼，請到「鎖定與解鎖」重新設定"))
            return
        case .failed(let status):
            warnOnce(String(localized: "讀取鑰匙圈失敗（\(status)），這次沒有自動解鎖"))
            return
        }

        isUnlocking = true
        unlockConfirmedBy = confirmedBy
        Task {
            let outcome = await Unlocker.unlock(with: password)
            isUnlocking = false
            switch outcome {
            case .unlocked:
                lastAutoUnlockAt = Date()
                automation.unlockSucceeded()
                noteSystemUnlock(false)
            case .userIsTyping:
                break
            case .stillLocked(let diagnostic):
                automation.unlockAttemptFailed()
                log.add(.info, "unlock diagnostic: \(diagnostic)")
                if automation.isBlockedByFailures {
                    log.add(.unlockFailed, String(localized: "連續 \(Automation.maximumFailures) 次自動解鎖失敗，已停止自動解鎖。如果改過登入密碼，請重新設定；否則可以在「鎖定與解鎖」恢復。"))
                } else {
                    log.add(.unlockFailed, String(localized: "自動解鎖失敗，螢幕仍是鎖定"))
                }
            case .interrupted:
                // 多半是 Apple Watch 比較慢、在我們打字時才解開
                if ScreenSession.queryLocked() == false { noteSystemUnlock(true) }
                log.add(.info, String(localized: "輸入途中螢幕已經解鎖或換了畫面，已停止輸入"))
            case .displayDidNotWake:
                log.add(.warning, String(localized: "螢幕沒有亮起，這次沒有解鎖"))
            case .noAccessibility:
                accessibilityGranted = false
                log.add(.warning, String(localized: "沒有輔助使用權限，無法自動解鎖"))
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
            cancelPendingLock()
            Notifier.remove(id: Self.lockNotificationID)
            if lockedByPresence {
                lockedByPresence = false
                if let name = preferences.shortcutOnReturn { ShortcutsRunner.run(name) }
            }
            if byUs || isWaitingForSystemUnlock || isConfirmingPresence {
                // 你可能還沒坐下：別讓螢幕馬上因為閒置變暗又鎖住
                ScreenControl.keepDisplayAwake(for: 60)
            }
            link.broadcast(event: group.presence.isAway && !byUs ? .unlockedWhileAway : .unlocked)
            if byUs {
                let names = nearDeviceNames
                if let confirmedBy = unlockConfirmedBy {
                    log.add(.unlocked, String(localized: "\(names.isEmpty ? subject : Self.list(names)) 在附近，\(confirmedBy) 已加密確認，已自動解鎖"))
                } else {
                    log.add(.unlocked, String(localized: "\(names.isEmpty ? subject : Self.list(names)) 在附近，已自動解鎖"))
                }
                EventScript.run(.unlocked, rssi: strongestRSSI)
            } else if isWaitingForSystemUnlock || isConfirmingPresence {
                let names = nearDeviceNames
                log.add(.unlocked, String(localized: "\(names.isEmpty ? subject : Self.list(names)) 在附近，已由 Apple Watch 或 Touch ID 解鎖"))
                EventScript.run(.unlocked, rssi: strongestRSSI)
            } else if case .away = group.presence, hasDevices {
                // 可能是你自己用 Touch ID 解鎖、只是裝置訊號太弱，也可能是別人，所以只陳述事實
                log.add(.intruded, String(localized: "手動解鎖（當時偵測不到\(subject)）"))
                EventScript.run(.intruded, rssi: strongestRSSI)
                if preferences.capturePhotoOnIntrusion { captureIntrusionPhoto() }
            } else {
                log.add(.manualUnlock, String(localized: "手動解鎖"))
            }
            if mediaPausedByUs {
                mediaPausedByUs = false
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    MediaControl.play()
                }
            }
        case .locked:
            ScreenControl.releaseDisplayAwake()
            if let last = lastLockAt, t.timeIntervalSince(last) < 5 { break }
            log.add(.locked, String(localized: "螢幕已鎖定"))
        case .displayWoke:
            evaluateUnlock()
        case .systemWillSleep, .systemDidWake:
            // 睡眠前後的訊號都不可信，要重新收集
            group.reset(at: t)
        case .displaySlept, .sessionResigned, .sessionActivated:
            break
        }
    }

    // MARK: - iPhone 與 Apple Watch

    /// 給 iPhone／手錶看的狀態。
    var linkStatus: LinkStatus {
        let presence: MacPresence = switch status {
        case .needsDevice: .noDevice
        case .bluetoothUnavailable: .bluetoothOff
        case .paused, .presenting: .paused
        case .suspended: .suspended
        case .lockPending: .lockPending
        case .waiting: .waiting
        case .near: .near
        case .leaving: .leaving
        case .away: .away
        }
        return LinkStatus(
            macName: Self.macName,
            presence: presence,
            summary: statusLine,
            detail: statusDetail,
            locked: ScreenSession.queryLocked() == true,
            pausedUntil: isPaused ? automation.pausedUntil : nil,
            presenter: preferences.allowPresenter ? (isPresenting ? .presenting : .enabled) : .disabled,
            frontApp: front.name,
            frontAppPresents: front.presents,
            presentationStartedAt: isPresenting ? presentationStartedAt : nil,
            presentationMinutes: isPresenting ? presentationMinutes : nil,
            pointer: preferences.allowPresenter ? true : nil,
            screenAspect: preferences.allowPresenter ? pointerScreenAspect : nil,
            highlighter: preferences.allowPresenter ? true : nil,
            volume: preferences.allowPresenter ? SystemVolume.current : nil
        )
    }

    /// `statusLine` 的結構化版本：手機與手錶用自己的語言組出同一句（見 PresenceLink 的 `StatusDetail`）。
    var statusDetail: StatusDetail {
        let rssi = strongestRSSI
        let subject = preferences.devices.count == 1 ? [preferences.devices[0].displayName] : []
        switch status {
        case .needsDevice: return StatusDetail(kind: .needsDevice)
        case .bluetoothUnavailable: return StatusDetail(kind: .bluetoothOff)
        case .paused: return StatusDetail(kind: .paused, devices: subject, rssi: rssi)
        case .presenting: return StatusDetail(kind: .presenting, devices: subject, rssi: rssi)
        case .suspended(let reason, let unlockToo):
            let suspension: StatusDetail.Suspension = switch reason {
            case .presenting(let app): .presenting(app: app)
            case .trustedNetwork(let name): .trustedNetwork(name: name)
            case .onACPower: .onACPower
            case .outsideSchedule: .outsideSchedule
            }
            return StatusDetail(kind: .suspended, suspension: suspension, suspendsUnlock: unlockToo)
        case .lockPending(let active): return StatusDetail(kind: active ? .lockPendingActive : .lockPending, devices: subject, rssi: rssi)
        case .waiting: return StatusDetail(kind: .waiting, devices: subject, rssi: rssi)
        case .near: return StatusDetail(kind: .near, devices: nearDeviceNames, rssi: rssi)
        case .leaving(let remaining):
            return StatusDetail(kind: .leaving, devices: subject, rssi: rssi, leavingSeconds: Int(remaining.rounded(.up)))
        case .away(.weakSignal): return StatusDetail(kind: .awayWeak, devices: subject, rssi: rssi)
        case .away(.signalLost): return StatusDetail(kind: .awayLost, devices: subject, rssi: rssi)
        }
    }

    /// 允許簡報遙控時才告訴手機 Mac 正在使用哪個 App（按鍵會送到那裡）。
    /// 只算一般的 App：關掉 Keynote 文件後，系統的背景程式（storeuid）曾短暫被當成最前面的 App（2026-10-16 實測）。
    private var front: (name: String?, presents: Bool?) {
        guard preferences.allowPresenter, let app = NSWorkspace.shared.frontmostApplication,
              app.activationPolicy == .regular else { return (nil, nil) }
        return (app.localizedName, app.bundleIdentifier.map(PresenterKeys.presentationApps.contains) ?? false)
    }

    /// 做不成時回傳原因，跟著回覆送回 iPhone 或手錶。
    private func handleRemote(_ command: LinkCommand) -> CommandRefusal? {
        defer { pushLinkStatusIfChanged() }
        switch command {
        case .lock:
            cancelPendingLock()
            automation.didLockManually(at: Date())
            log.add(.info, String(localized: "收到 iPhone 或 Apple Watch 的鎖定指令"))
            lock(reason: nil)
        case .pause(let minutes):
            pause(for: TimeInterval(max(1, min(minutes, 24 * 60)) * 60))
        case .resume:
            resume()
        case .presenter, .goToSlide:
            if let refusal = presenterRefusal { return refusal }
            if !isPresenting { beginPresentation() }
            // 換頁了，螢光筆畫的線不該留在新的那一頁上
            PointerOverlay.shared.clearInk()
            if case .presenter(let action) = command { PresenterKeys.press(action) }
            if case .goToSlide(let slide) = command { Task { await PresenterKeys.goTo(slide: slide) } }
        case .presentation(let active):
            guard preferences.allowPresenter else { return .presenterNotAllowed }
            if active { beginPresentation() } else { endPresentation() }
        case .presentationTimer(let startedAt, let minutes):
            guard preferences.allowPresenter else { return .presenterNotAllowed }
            presentationStartedAt = startedAt
            presentationMinutes = minutes.map { max(1, min($0, 24 * 60)) }
        case .volume(let change):
            // 不送按鍵，不需要輔助使用權限
            guard preferences.allowPresenter else { return .presenterNotAllowed }
            guard SystemVolume.change(change) else { return .volumeNotAdjustable }
        case .hello, .status, .confirm:
            break
        }
        return nil
    }

    // MARK: - 簡報

    /// 送按鍵前的檢查：沒允許、沒有輔助使用權限、或螢幕鎖著就不送。
    private var presenterRefusal: CommandRefusal? {
        guard preferences.allowPresenter else { return .presenterNotAllowed }
        guard Accessibility.isTrusted else {
            accessibilityGranted = false
            return .noAccessibility
        }
        // 狀態不明也當作鎖著：寧可不翻頁，也不要把按鍵打進登入畫面
        guard ScreenSession.queryLocked() == false, !ScreenSession.loginWindowIsFrontmost else { return .screenLocked }
        return nil
    }

    /// 簡報模式最長暫停多久：忘了結束也不會一直不鎖。
    private static let presentationLimit: TimeInterval = 3 * 3600

    /// 正在從 iPhone 或手錶簡報：暫停是簡報開始時設的，而且還沒結束。手動恢復或改暫停時間就不算了。
    var isPresenting: Bool {
        guard let until = presentingUntil else { return false }
        return automation.pausedUntil == until && now < until
    }

    /// 已經在簡報（例如手機重新打開簡報畫面）就只延長時間，不重複記錄。
    private func beginPresentation() {
        let alreadyPresenting = isPresenting
        let until = Date().addingTimeInterval(Self.presentationLimit)
        automation.pause(until: until)
        presentingUntil = until
        now = Date()
        if !alreadyPresenting {
            presentationStartedAt = Date()
            presentationMinutes = nil
            log.add(.info, String(localized: "開始簡報，暫停自動鎖定與解鎖（最多 3 小時）"))
        }
    }

    /// 雷射筆、聚光燈與螢光筆：要允許簡報遙控，螢幕鎖著時不畫。
    private func showPointer(_ update: PointerUpdate) {
        guard preferences.allowPresenter, ScreenSession.queryLocked() != true else {
            PointerOverlay.shared.dismiss()
            return
        }
        if update.mode != .hidden, !isPresenting { beginPresentation() }
        PointerOverlay.shared.show(update)
    }

    /// 要畫雷射筆的螢幕寬高比（手機上的觸控區照這個比例），幾秒才重新查一次。
    private var pointerScreenAspect: Double {
        if let cached = screenAspectCache, Date().timeIntervalSince(cached.at) < 5 { return cached.aspect }
        let frame = PointerOverlay.targetScreen().frame
        let aspect = frame.height > 0 ? Double(frame.width / frame.height) : 16.0 / 9
        screenAspectCache = (aspect, Date())
        return aspect
    }

    private func endPresentation() {
        guard isPresenting else { return }
        presentingUntil = nil
        presentationStartedAt = nil
        presentationMinutes = nil
        PointerOverlay.shared.dismiss()
        automation.pause(until: nil)
        now = Date()
        log.add(.info, String(localized: "結束簡報，恢復自動鎖定與解鎖"))
    }

    /// 狀態有實質改變才推送（訊號強度每秒都在變，不算）。
    private func pushLinkStatusIfChanged() {
        let s = linkStatus
        let signature = [s.presence.rawValue, "\(s.locked)", "\(s.pausedUntil?.timeIntervalSince1970 ?? 0)", "\(nearDeviceNames)",
                         s.presenter?.rawValue ?? "", s.frontApp ?? "", "\(s.presentationStartedAt?.timeIntervalSince1970 ?? 0)",
                         "\(s.presentationMinutes ?? 0)", s.volume.map { "\($0.level)\($0.muted)\($0.adjustable)" } ?? ""]
            .joined(separator: "|")
        guard signature != lastLinkSignature else { return }
        lastLinkSignature = signature
        link.broadcast()
    }

    private func captureIntrusionPhoto() {
        Task {
            guard let url = await CameraCapture.capturePhoto() else {
                log.add(.warning, String(localized: "拍照存證失敗：沒有相機權限或相機無法使用"))
                return
            }
            log.add(.intruded, String(localized: "已拍下解鎖當下的照片"), attachment: url)
            Notifier.post("Presence", String(localized: "你不在時這台 Mac 被手動解鎖了，已拍下照片"))
        }
    }

    private func handleAvailability(_ availability: BluetoothMonitor.Availability) {
        if availability == .poweredOn {
            if bluetoothWasUnavailable { log.add(.info, String(localized: "藍牙已恢復")) }
            bluetoothWasUnavailable = false
            return
        }
        guard availability != .unknown, availability != .resetting else { return }
        group.reset(at: Date())
        if !bluetoothWasUnavailable {
            bluetoothWasUnavailable = true
            log.add(.warning, String(localized: "藍牙\(availability.description)。收不到訊號超過逾時時間後會自動鎖定。"))
        }
    }

    private func noteSuspensionChange() {
        let current = suspension
        guard current != lastSuspension else { return }
        if let current {
            log.add(.info, Status.suspended(current, unlockToo: preferences.context.alsoSuspendUnlock).title)
        } else if let previous = lastSuspension {
            let what = switch previous {
            case .presenting(let app): String(localized: "「\(app)」結束播放")
            case .trustedNetwork(let name): String(localized: "離開「\(name)」")
            case .onACPower: String(localized: "拔掉電源")
            case .outsideSchedule: String(localized: "進入設定的時段")
            }
            log.add(.info, String(localized: "\(what)，恢復自動鎖定"))
        }
        lastSuspension = current
    }

    private func warnOnce(_ message: String) {
        guard !warnedMissingPassword else { return }
        warnedMissingPassword = true
        log.add(.warning, message)
    }

    private func apply(changesFrom old: Preferences) {
        if preferences.devicePolicy != old.devicePolicy {
            group.policy = preferences.devicePolicy
        }
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
        if preferences.lockHotKey != old.lockHotKey {
            registerHotKey()
        }
    }

    private func registerHotKey() {
        hotKeyConflict = !HotKeyCenter.shared.register(preferences.lockHotKey)
        if hotKeyConflict, let key = preferences.lockHotKey {
            log.add(.warning, String(localized: "快捷鍵 \(key.display) 已被其他 App 使用，請換一組"))
        }
    }

    /// 依系統語言格式化時間長度，例如「1 小時 30 分鐘」、「1 hr, 30 min」。
    static func describe(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = duration < 60 ? [.second] : [.hour, .minute]
        formatter.unitsStyle = .short
        return formatter.string(from: duration) ?? ""
    }

    /// 依系統語言串接名稱，例如「Weichung和Apple Watch」、「Weichung and Apple Watch」。
    static func list(_ names: [String]) -> String {
        ListFormatter.localizedString(byJoining: names)
    }
}

// MARK: - 示範模式

#if DEBUG
extension AppModel {
    /// 示範模式的 start()：假裝置、模擬訊號，不碰藍牙、螢幕、鑰匙圈與登入項目（見 Demo）。
    func startDemo() {
        Self.current = self
        let t = Date()
        ScreenSession.demoLocked = false
        log.seedDemo(Demo.logEntries(now: t))
        deskTime = Demo.deskTime(now: t)
        refreshStatus()

        bluetooth.onSample = { [weak self] id, rssi, date in self?.handleSample(id, rssi, at: date) }
        bluetooth.startDemo(Demo.nearby)
        session.onEvent = { [weak self] event in self?.handleSession(event) }
        link.statusProvider = { [weak self] in self?.linkStatus ?? LinkStatus(macName: "Mac", presence: .waiting, summary: "", locked: false) }
        link.startDemo(devices: Demo.pairedDevices, connected: [Demo.pairingID: "iPhone"])

        // 訊號圖先填上過去 3 分鐘一直坐在座位上的訊號；濾波線和真的一樣取最近 4 秒的中位數
        for device in preferences.devices {
            let near = Demo.targetRSSI(for: device.id, elapsed: 0) ?? -60
            let raw = stride(from: Self.historyDuration, to: 0, by: -1).map {
                RSSIPoint(date: t.addingTimeInterval(-$0), rssi: near + Int.random(in: -5...5))
            }
            samples[device.id] = raw
            smoothed[device.id] = raw.indices.map { i in
                let window = raw[max(0, i - 3)...i].map(\.rssi).sorted()
                return RSSIPoint(date: raw[i].date, rssi: window[(window.count - 1) / 2])
            }
        }
        // -PresenceDemoWindowSize 1000x720：截圖用的視窗大小（點）
        if let size = UserDefaults.standard.string(forKey: "PresenceDemoWindowSize")?.split(separator: "x").compactMap({ Double($0) }),
           size.count == 2 {
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
                window.setContentSize(NSSize(width: size[0], height: size[1]))
                window.center()
                // 截圖要作用中的樣子：背景啟動的 App 系統不一定讓它到前景，再要求一次
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                // 「裝置」頁的名稱欄位會自動取得焦點、文字反白；改讓側邊欄取得焦點（選取的項目才是藍色）
                func sidebar(in view: NSView) -> NSTableView? {
                    if let table = view as? NSTableView { return table }
                    return view.subviews.lazy.compactMap(sidebar(in:)).first
                }
                window.makeFirstResponder(window.contentView.flatMap(sidebar(in:)))
            }
        }

        // -PresencePointerDemo spotlight|laser|highlighter：照固定路線走一遍，錄影檢查效果（見 PointerOverlay.runDemo）
        if let name = UserDefaults.standard.string(forKey: "PresencePointerDemo") {
            let mode: PointerUpdate.Mode = switch name {
            case "laser": .laser
            case "highlighter": .highlighter
            default: .spotlight
            }
            Task {
                try? await Task.sleep(for: .seconds(1))
                await PointerOverlay.shared.runDemo(mode)
            }
        }

        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.tick()
            }
        }
        // 模擬訊號：手機大約每秒一筆，手錶比較稀疏
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(Int.random(in: 600...1100)))
                guard let self else { return }
                let elapsed = Date().timeIntervalSince(t)
                for device in preferences.devices where device.id == Demo.iPhoneID || Bool.random() {
                    if let rssi = Demo.targetRSSI(for: device.id, elapsed: elapsed) {
                        bluetooth.demoSample(device.id, rssi: rssi + Int.random(in: -4...4))
                    }
                }
            }
        }
    }

    /// 示範模式的自動解鎖：假裝 iPhone 加密確認後解開。
    private func demoUnlock() {
        automation.didAttemptUnlock(at: Date())
        isConfirmingPresence = true
        Task {
            try? await Task.sleep(for: .milliseconds(1200))
            isConfirmingPresence = false
            guard session.isLocked, group.canUnlock else { return }
            unlockConfirmedBy = "iPhone"
            isUnlocking = true
            ScreenSession.demoLocked = false
            session.refresh()
            isUnlocking = false
            lastAutoUnlockAt = Date()
            automation.unlockSucceeded()
        }
    }
}
#endif

private extension Presence {
    var isAway: Bool {
        if case .away = self { return true }
        return false
    }
}
