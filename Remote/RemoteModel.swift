import ActivityKit
import Foundation
import Observation
import PresenceLink
import UIKit
import UserNotifications
import WidgetKit

/// iPhone 端的核心：保存配對、維持與 Mac 的連線、發通知、把狀態同步給手錶並代手錶轉送指令。
/// App Intents 可能在 App 沒開的時候執行，所以用單一的 `shared`。
@Observable
final class RemoteModel {
    static let shared = RemoteModel()

    let link: LinkCentral
    private(set) var pairing: PairingInfo?
    private(set) var busy = false
    private(set) var lastError: String?
    /// 宣傳影片的字幕與結尾畫面（只有開發版的示範腳本會設定）。
    private(set) var demoCaption: String?
    private(set) var demoEndCard = false
    /// 宣傳影片打開簡報畫面、翻頁（每加一就翻一頁的動畫）。
    private(set) var demoPresenter = false
    private(set) var demoSlideTick = 0

    @ObservationIgnored private let watch = WatchBridge()
    /// 簡報中的即時動態。App 被系統結束後再被叫醒時，接手還在顯示的那一個。
    @ObservationIgnored private var presenterActivity = Activity<PresenterAttributes>.activities.first

    private init() {
        link = LinkCentral(deviceName: UIDevice.current.name, keepConnected: true, restoreIdentifier: "presence-remote")
        #if DEBUG
        if Self.isDemo {
            startDemo()
            return
        }
        #endif
        pairing = PairingKeychain.load()
        link.pairing = pairing
        link.onEvent = { status in Self.notify(status) }
        link.onStatus = { [weak self] status in
            self?.watch.sync(pairing: self?.pairing, status: status)
            self?.publishWidgetStatus()
            self?.presentationChanged(status)
        }
        link.onStateChange = { [weak self] _ in self?.publishWidgetStatus() }
        watch.onCommand = { [weak self] command in
            guard let self else { return .failure(.notPaired) }
            // 手錶的簡報遙控也要 Pro（手錶畫面本來就擋，這裡再擋一次）
            if command.needsPro, await !ProStore.shared.checkPro() {
                guard var status = link.status else { return .failure(.notPaired) }
                status.refusal = CommandRefusal.proRequired.rawValue
                return .success(status)
            }
            return await perform(command)
        }
        ProStore.shared.onChange = { [weak self] _ in self?.watch.sync(pairing: self?.pairing, status: nil) }
        link.start()
        watch.activate()
        watch.sync(pairing: pairing, status: nil)
        publishWidgetStatus()
    }

    /// 掃到 QR code：回傳 false 表示不是 Presence 的配對碼。
    func pair(with text: String) -> Bool {
        guard let info = PairingInfo(qrString: text) else { return false }
        PairingKeychain.save(info)
        pairing = info
        link.pairing = info
        watch.sync(pairing: info, status: nil)
        lastError = nil
        publishWidgetStatus()
        return true
    }

    func unpair() {
        PairingKeychain.delete()
        pairing = nil
        link.pairing = nil
        watch.sync(pairing: nil, status: nil)
        publishWidgetStatus()
    }

    /// 小工具與控制中心只能讀 App 存下的狀態；顯示的內容變了才請系統重畫（有次數限額）。
    private func publishWidgetStatus() {
        let shared = SharedStatus(macName: pairing?.macName, status: pairing == nil ? nil : link.status,
                                  connected: link.state == .connected)
        guard SharedStatusStore.save(shared) else { return }
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
    }

    @discardableResult
    func perform(_ command: LinkCommand) async -> Result<LinkStatus, LinkCentral.Failure> {
        busy = true
        defer { busy = false }
        let result = await link.send(command)
        switch result {
        case .success(let status): lastError = status.refusalMessage
        case .failure(let failure): lastError = failure.message
        }
        return result
    }

    // MARK: - 簡報遙控

    /// Mac 對簡報遙控的支援；nil 表示還沒收到狀態，或 Mac 上的 Presence 太舊。
    var presenterSupport: PresenterSupport? { link.status?.presenter }

    /// 翻頁等按鍵：不轉圈，做不成時把原因放在 `lastError`。
    @discardableResult
    func present(_ action: PresenterAction) async -> Bool {
        switch await link.send(.presenter(action), timeout: 5) {
        case .success(let status):
            lastError = status.refusalMessage
            // 一開始 Mac 還沒允許、後來才打開：第一次翻頁時 Mac 會開始簡報，這裡補上鎖定畫面的按鈕
            if status.refusal == nil { startPresenterActivity() }
            return status.refusal == nil
        case .failure(let failure):
            lastError = failure.message
            return false
        }
    }

    /// 跳到第幾頁（問答時常用）。
    @discardableResult
    func goToSlide(_ slide: Int) async -> Bool {
        switch await link.send(.goToSlide(slide), timeout: 5) {
        case .success(let status):
            lastError = status.refusalMessage
            return status.refusal == nil
        case .failure(let failure):
            lastError = failure.message
            return false
        }
    }

    /// 設定演講長度（nil 是不限）；`restart` 從現在重新計時。存在 Mac 上，手錶與鎖定畫面一起更新。
    func setPresentationTimer(minutes: Int?, restart: Bool = false) async {
        let start = restart ? Date() : link.status?.presentationStartedAt ?? Date()
        switch await link.send(.presentationTimer(startedAt: start, minutes: minutes)) {
        case .success(let status): lastError = status.refusalMessage
        case .failure(let failure): lastError = failure.message
        }
    }

    /// 開始或結束簡報：Mac 暫停或恢復自動鎖定，鎖定畫面顯示或收起翻頁按鈕。
    func setPresentation(_ active: Bool) async {
        if !active {
            endPresenterActivity()
            // 沒在簡報（例如 Mac 還沒允許）就不必通知 Mac，免得多一則錯誤訊息
            guard presenterSupport == .presenting else { return }
        }
        switch await link.send(.presentation(active: active)) {
        case .success(let status):
            lastError = status.refusalMessage
            if active, status.refusal == nil { startPresenterActivity() }
        case .failure(let failure):
            lastError = failure.message
        }
    }

    private func startPresenterActivity() {
        guard presenterActivity == nil else { return }
        #if DEBUG
        // 截圖用的示範模式不開即時動態：模擬器第一次開會跳出通知權限的對話框蓋住畫面
        if Self.isDemo, !UserDefaults.standard.bool(forKey: "PresenceDemoActivity") { return }
        #endif
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            LinkLog.write("即時動態已關閉，鎖定畫面不會有翻頁按鈕")
            return
        }
        let attributes = PresenterAttributes(macName: pairing?.macName ?? "Mac")
        let state = PresenterAttributes.ContentState(startedAt: link.status?.presentationStartedAt ?? Date(),
                                                     endsAt: link.status?.presentationEndsAt)
        do {
            presenterActivity = try Activity.request(attributes: attributes, content: .init(state: state, staleDate: nil))
            activityState = state
        } catch {
            LinkLog.write("無法顯示簡報的即時動態：\(error)")
        }
    }

    private func endPresenterActivity() {
        presenterActivity = nil
        activityState = nil
        Task { await Self.endPresenterActivities() }
    }

    /// Activity 不是 Sendable：在同一個非隔離的函式裡取得並結束，不跨執行緒傳遞。
    nonisolated private static func endPresenterActivities() async {
        for activity in Activity<PresenterAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    nonisolated private static func updatePresenterActivities(_ state: PresenterAttributes.ContentState) async {
        for activity in Activity<PresenterAttributes>.activities {
            await activity.update(.init(state: state, staleDate: nil))
        }
    }

    // MARK: - 簡報時間提醒

    @ObservationIgnored private var activityState: PresenterAttributes.ContentState?
    @ObservationIgnored private var scheduledEnd: Date?
    private static let fiveMinutesID = "presence.presentation.five-minutes"
    private static let timeUpID = "presence.presentation.time-up"

    /// Mac 送來新的簡報狀態：更新鎖定畫面的倒數，重排「剩 5 分鐘」「時間到」的通知。
    /// App 在前景時系統不顯示通知（簡報畫面自己會震動）；手機鎖著時通知會轉到手錶，輕敲手腕。
    private func presentationChanged(_ status: LinkStatus) {
        let presenting = status.presenter == .presenting
        if presenting, presenterActivity != nil, let start = status.presentationStartedAt {
            let state = PresenterAttributes.ContentState(startedAt: start, endsAt: status.presentationEndsAt)
            if state != activityState {
                activityState = state
                Task { await Self.updatePresenterActivities(state) }
            }
        }
        let endsAt = presenting ? status.presentationEndsAt : nil
        guard endsAt != scheduledEnd else { return }
        scheduledEnd = endsAt
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.fiveMinutesID, Self.timeUpID])
        guard let endsAt, let minutes = status.presentationMinutes else { return }
        func schedule(_ id: String, at date: Date, title: String, body: String) {
            let wait = date.timeIntervalSinceNow
            guard wait > 1 else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            center.add(UNNotificationRequest(identifier: id, content: content,
                                             trigger: UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false)))
        }
        if minutes > 5 {
            schedule(Self.fiveMinutesID, at: endsAt.addingTimeInterval(-300),
                     title: String(localized: "簡報剩 5 分鐘"), body: String(localized: "預定講 \(minutes) 分鐘。"))
        }
        schedule(Self.timeUpID, at: endsAt,
                 title: String(localized: "簡報時間到了"), body: String(localized: "已經講了 \(minutes) 分鐘。"))
    }

    // MARK: - 通知

    #if DEBUG
    /// App Store 截圖用：-PresenceDemo YES，-PresenceDemoState 選 near（預設）、locked、paused、onboarding、presenter。
    static var isDemo: Bool { UserDefaults.standard.bool(forKey: "PresenceDemo") }

    private func startDemo() {
        let state = UserDefaults.standard.string(forKey: "PresenceDemoState") ?? "near"
        guard state != "onboarding" else { return }
        let chinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true
        let demoPairing = PairingInfo(id: UUID(), macName: "MacBook Pro", key: Data(repeating: 7, count: 32))
        var status = LinkStatus(macName: "MacBook Pro", presence: .near,
                                summary: chinese ? "Apple Watch 在附近 · -52 dBm" : "Apple Watch nearby · -52 dBm",
                                locked: false, presenter: .enabled)
        switch state {
        case "locked":
            status.presence = .away
            status.summary = chinese ? "Apple Watch 離開了" : "Apple Watch is away"
            status.locked = true
        case "paused":
            status.presence = .paused
            status.summary = chinese ? "已暫停" : "Paused"
            status.pausedUntil = Date().addingTimeInterval(3600)
        case "presenter":
            // 講了 12 分半、預定 20 分鐘，Keynote 在最前面
            status.presenter = .presenting
            status.presentationStartedAt = Date().addingTimeInterval(-750)
            status.presentationMinutes = 20
            status.frontApp = "Keynote"
            status.frontAppPresents = true
        default:
            break
        }
        pairing = demoPairing
        link.startDemo(pairing: demoPairing, status: status)
        if state == "script" { Task { await runDemoScript(chinese: chinese, start: status) } }
    }

    /// 宣傳影片：在座位 → 離開自動鎖定 → 回來自動解鎖 → 從 iPhone 鎖定 → 簡報遙控翻頁 → 結尾，約 26 秒。
    private func runDemoScript(chinese: Bool, start: LinkStatus) async {
        func t(_ zh: String, _ en: String) -> String { chinese ? zh : en }
        var status = start
        func step(_ caption: String, seconds: Double, _ change: (inout LinkStatus) -> Void = { _ in }) async {
            change(&status)
            status.sentAt = Date()
            link.updateDemo(status)
            demoCaption = caption
            try? await Task.sleep(for: .seconds(seconds))
        }
        // 第一句字幕到結尾畫面固定 21 秒（scripts/app-preview.sh 依這個長度剪片）
        try? await Task.sleep(for: .seconds(1))
        await step(t("Presence 會知道\n你在不在座位上", "Presence knows when\nyou're at your desk"), seconds: 3.5)
        await step(t("離開座位，Mac 自動鎖定", "Walk away and your Mac locks"), seconds: 1.5) {
            $0.presence = .leaving
            $0.summary = t("Apple Watch 離開中…", "Apple Watch is leaving…")
        }
        await step(t("離開座位，Mac 自動鎖定", "Walk away and your Mac locks"), seconds: 2.5) {
            $0.presence = .away
            $0.summary = t("Apple Watch 離開了", "Apple Watch is away")
            $0.locked = true
        }
        await step(t("回來時，自動解鎖", "Come back and it unlocks"), seconds: 3.5) {
            $0.presence = .near
            $0.summary = t("Apple Watch 在附近 · -55 dBm", "Apple Watch nearby · -55 dBm")
            $0.locked = false
        }
        await step(t("從 iPhone 一鍵鎖定", "Lock it from your iPhone"), seconds: 3.5) {
            $0.summary = t("已從 iPhone 鎖定", "Locked from iPhone")
            $0.locked = true
        }
        // Presence Pro：打開簡報畫面翻三頁
        await step(t("Presence Pro\n手機就是簡報筆", "Presence Pro turns\nyour iPhone into a clicker"), seconds: 0) {
            $0.locked = false
            $0.presence = .paused
            $0.summary = t("簡報中", "Presenting")
            $0.presenter = .presenting
            $0.presentationStartedAt = Date().addingTimeInterval(-750)
            $0.presentationMinutes = 20
            $0.frontApp = "Keynote"
            $0.frontAppPresents = true
        }
        demoPresenter = true
        for _ in 0..<3 {
            try? await Task.sleep(for: .seconds(1.6))
            demoSlideTick += 1
        }
        try? await Task.sleep(for: .seconds(1.7))
        demoCaption = nil
        demoEndCard = true
    }
    #endif

    static func requestNotificationPermission() async {
        #if DEBUG
        if isDemo { return }
        #endif
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    /// App 不在前景時，把 Mac 的重要事件發成通知。從手機自己鎖定的不通知。
    private static func notify(_ status: LinkStatus) {
        guard UIApplication.shared.applicationState != .active, let event = status.event else { return }
        let body: String
        switch event {
        case .lockedAway: body = String(localized: "\(status.macName) 已自動鎖定：你離開了")
        case .unlockedWhileAway: body = String(localized: "你不在附近時，\(status.macName) 被手動解鎖了")
        case .lockedManually, .unlocked: return
        }
        let content = UNMutableNotificationContent()
        content.title = "Presence"
        content.body = body
        content.sound = event == .unlockedWhileAway ? .default : nil
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
