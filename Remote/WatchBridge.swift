import Foundation
import PresenceLink
import WatchConnectivity

/// iPhone ↔ Apple Watch：把配對與最新狀態同步給手錶，並代手錶把指令送到 Mac。
///
/// Mac 當藍牙週邊同時只接受一台連線，iPhone 平常一直連著，所以手錶的指令經由 iPhone 轉送最可靠。
final class WatchBridge: NSObject {
    var onCommand: ((LinkCommand) async -> Result<LinkStatus, LinkCentral.Failure>)?

    private var lastSyncedStatus: Date?
    private var lastSyncedPro: Bool?

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// 配對改變時一定同步；狀態最多每 5 秒同步一次，以免頻繁喚醒手錶。
    func sync(pairing: PairingInfo?, status: LinkStatus?) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isPaired, WCSession.default.isWatchAppInstalled else {
            LinkLog.write("[iPhone] 無法同步給手錶：啟用=\(WCSession.default.activationState.rawValue) 配對=\(WCSession.default.isPaired) 已安裝=\(WCSession.default.isWatchAppInstalled)")
            return
        }
        if let status, status.event == nil, let last = lastSyncedStatus, Date().timeIntervalSince(last) < 5 { return }
        // 手錶靠這個決定簡報遙控能不能用（手錶自己也查 App Store，但開發時的測試購買只在 iPhone 上）。
        // 還沒讀完購買狀態就不要送：系統在背景重開 App 時，一開始 isPro 還是 false，
        // 送過去手錶就以為沒有 Pro、跳出付費畫面（2026-10-17 使用者遇到）
        var context: [String: Any] = [:]
        if ProStore.shared.loaded { context["pro"] = ProStore.shared.isPro }
        if let pro = context["pro"] as? Bool, pro != lastSyncedPro {
            LinkLog.write("[iPhone] 告訴手錶 Pro=\(pro)")
            lastSyncedPro = pro
        }
        if let pairing, let data = try? JSONEncoder().encode(pairing) { context["pairing"] = data }
        if let status, let data = try? WatchMessage.encode(status) {
            context["status"] = data
            lastSyncedStatus = Date()
        }
        try? WCSession.default.updateApplicationContext(context)
    }
}

extension WatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        Task { @MainActor in
            let model = RemoteModel.shared
            self.sync(pairing: model.pairing, status: model.link.status)
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    /// 手錶送來指令：轉給 Mac，再把 Mac 的回覆交回手錶。
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        nonisolated(unsafe) let reply = replyHandler
        guard let data = message["command"] as? Data, let command = try? WatchMessage.decode(LinkCommand.self, from: data) else {
            reply(["error": "bad command"])
            return
        }
        Task { @MainActor in
            LinkLog.write("[iPhone] 收到手錶指令 \(command)")
            let result = await self.onCommand?(command) ?? .failure(.notPaired)
            LinkLog.write("[iPhone] 手錶指令結果：\(result)")
            switch result {
            case .success(let status):
                reply(["status": (try? WatchMessage.encode(status)) ?? Data()])
            case .failure(let failure):
                reply(["error": failure.message])
            }
        }
    }
}
