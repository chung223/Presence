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

    static func requestNotificationPermission() async {
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
