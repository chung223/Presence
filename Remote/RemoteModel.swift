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

    @ObservationIgnored private let watch = WatchBridge()

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
        }
        link.onStateChange = { [weak self] _ in self?.publishWidgetStatus() }
        watch.onCommand = { [weak self] command in
            await self?.perform(command) ?? .failure(.notPaired)
        }
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
        case .success: lastError = nil
        case .failure(let failure): lastError = failure.message
        }
        return result
    }

    // MARK: - 通知

    #if DEBUG
    /// App Store 截圖用：-PresenceDemo YES，-PresenceDemoState 選 near（預設）、locked、paused、onboarding。
    static var isDemo: Bool { UserDefaults.standard.bool(forKey: "PresenceDemo") }

    private func startDemo() {
        let state = UserDefaults.standard.string(forKey: "PresenceDemoState") ?? "near"
        guard state != "onboarding" else { return }
        let chinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true
        let demoPairing = PairingInfo(id: UUID(), macName: "MacBook Pro", key: Data(repeating: 7, count: 32))
        var status = LinkStatus(macName: "MacBook Pro", presence: .near,
                                summary: chinese ? "Apple Watch 在附近 · -52 dBm" : "Apple Watch nearby · -52 dBm",
                                locked: false)
        switch state {
        case "locked":
            status.presence = .away
            status.summary = chinese ? "Apple Watch 離開了" : "Apple Watch is away"
            status.locked = true
        case "paused":
            status.presence = .paused
            status.summary = chinese ? "已暫停" : "Paused"
            status.pausedUntil = Date().addingTimeInterval(3600)
        default:
            break
        }
        pairing = demoPairing
        link.startDemo(pairing: demoPairing, status: status)
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
