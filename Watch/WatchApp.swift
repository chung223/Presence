import Observation
import PresenceLink
import SwiftUI
import WatchConnectivity
import WidgetKit

@main
struct WatchApp: App {
    @State private var model = WatchModel.shared

    var body: some Scene {
        WindowGroup {
            WatchControlView(model: model)
        }
    }
}

/// 手錶端：配對與狀態由 iPhone 同步過來。
///
/// 送指令時優先經由 iPhone 轉送（iPhone 平常一直連著 Mac，而 Mac 同時只接受一台連線）；
/// iPhone 不在身邊或沒回應時，才直接用藍牙連 Mac，用完就斷，把連線讓回給 iPhone。
@Observable
final class WatchModel: NSObject {
    static let shared = WatchModel()

    private(set) var pairing: PairingInfo?
    private(set) var status: LinkStatus?
    private(set) var lastUpdate: Date?
    private(set) var busy = false
    private(set) var lastError: String?
    private(set) var lastRoute: String?

    @ObservationIgnored private let link = LinkCentral(deviceName: "Apple Watch", keepConnected: false)
    @ObservationIgnored private let launchedAt = Date()

    override private init() {
        super.init()
        pairing = PairingKeychain.load()
        link.pairing = pairing
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func perform(_ command: LinkCommand) async {
        guard pairing != nil else {
            lastError = String(localized: "請先在 iPhone 的 Presence Remote 配對 Mac")
            return
        }
        busy = true
        defer { busy = false }
        let session = WCSession.default
        // App 剛啟動時，跟 iPhone 的即時連線要一下子才建立；這段期間先等，不要馬上改走直接連線
        if Date().timeIntervalSince(launchedAt) < 3, !session.isReachable {
            for _ in 0..<10 where !session.isReachable {
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        LinkLog.write("[手錶] \(command)：WCSession 啟用=\(session.activationState.rawValue) 可達=\(session.isReachable)")
        if session.activationState == .activated, session.isReachable {
            if let result = await sendThroughPhone(command) {
                LinkLog.write("[手錶] 經由 iPhone 成功")
                apply(result, route: String(localized: "經由 iPhone"))
                return
            }
            LinkLog.write("[手錶] 經由 iPhone 失敗，改直接連線")
        }
        switch await link.send(command) {
        case .success(let status):
            LinkLog.write("[手錶] 直接連線成功")
            apply(.success(status), route: String(localized: "直接連線"))
        case .failure(let failure):
            LinkLog.write("[手錶] 直接連線失敗：\(failure)")
            apply(.failure(failure.message), route: nil)
        }
    }

    private enum Outcome {
        case success(LinkStatus)
        case failure(String)
    }

    private func apply(_ outcome: Outcome, route: String?) {
        switch outcome {
        case .success(let status):
            self.status = status
            lastUpdate = Date()
            lastError = nil
            lastRoute = route
            publishWidgetStatus()
        case .failure(let message):
            lastError = message
        }
    }

    /// 錶面複雜功能只能讀 App 存下的狀態；顯示的內容變了才請系統重畫。
    private func publishWidgetStatus() {
        let shared = SharedStatus(macName: pairing?.macName, status: pairing == nil ? nil : status,
                                  connected: status != nil, updatedAt: lastUpdate ?? Date())
        if SharedStatusStore.save(shared) { WidgetCenter.shared.reloadAllTimelines() }
    }

    /// 經由 iPhone 轉送；iPhone 沒回應或回傳錯誤時回傳 nil，改走直接連線。
    private func sendThroughPhone(_ command: LinkCommand) async -> Outcome? {
        guard let data = try? WatchMessage.encode(command) else { return nil }
        let reply: [String: Any]? = await withCheckedContinuation { continuation in
            let once = Once(continuation)
            WCSession.default.sendMessage(["command": data], replyHandler: { once.resume($0) },
                                          errorHandler: { _ in once.resume(nil) })
            Task {
                try? await Task.sleep(for: .seconds(8))
                once.resume(nil)
            }
        }
        if let data = reply?["status"] as? Data, let status = try? WatchMessage.decode(LinkStatus.self, from: data) {
            return .success(status)
        }
        LinkLog.write("[手錶] iPhone 回覆：\(reply?["error"] as? String ?? (reply == nil ? "沒有回覆或逾時" : "格式不對"))")
        return nil
    }

    fileprivate func receive(context: [String: Any]) {
        if let data = context["pairing"] as? Data, let info = try? JSONDecoder().decode(PairingInfo.self, from: data) {
            if info != pairing {
                PairingKeychain.save(info)
                pairing = info
                link.pairing = info
            }
        } else if context["pairing"] == nil, pairing != nil {
            // iPhone 取消了配對
            PairingKeychain.delete()
            pairing = nil
            link.pairing = nil
            status = nil
        }
        if let data = context["status"] as? Data, let status = try? WatchMessage.decode(LinkStatus.self, from: data) {
            self.status = status
            lastUpdate = Date()
        }
        publishWidgetStatus()
    }
}

/// continuation 只能 resume 一次：iPhone 回覆、錯誤、逾時三者先到先用。
private final class Once: @unchecked Sendable {
    private var continuation: CheckedContinuation<[String: Any]?, Never>?
    private let lock = NSLock()

    init(_ continuation: CheckedContinuation<[String: Any]?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: [String: Any]?) {
        nonisolated(unsafe) let value = value
        let pending = lock.withLock { () -> CheckedContinuation<[String: Any]?, Never>? in
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(returning: value)
    }
}

extension WatchModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        nonisolated(unsafe) let context = session.receivedApplicationContext
        Task { @MainActor in self.receive(context: context) }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        nonisolated(unsafe) let context = applicationContext
        Task { @MainActor in self.receive(context: context) }
    }
}

struct WatchControlView: View {
    let model: WatchModel

    var body: some View {
        if model.pairing == nil {
            VStack(spacing: 8) {
                Image(systemName: "iphone.and.arrow.forward").font(.title)
                Text("請先在 iPhone 的 Presence Remote 配對 Mac。")
                    .multilineTextAlignment(.center)
                    .font(.footnote)
            }
        } else {
            ScrollView {
                VStack(spacing: 10) {
                    let presence = model.status?.presence ?? .waiting
                    HStack {
                        Image(systemName: presence.symbol).foregroundStyle(presence.tint)
                        Text(model.status?.summary ?? String(localized: "尚未取得狀態"))
                            .font(.footnote)
                            .lineLimit(2)
                    }
                    if model.status?.locked == true {
                        Label("Mac 已鎖定", systemImage: "lock.fill").font(.caption2).foregroundStyle(.orange)
                    }

                    Button {
                        Task { await model.perform(.lock) }
                    } label: {
                        Label("鎖定 Mac", systemImage: "lock.fill").frame(maxWidth: .infinity)
                    }
                    .tint(.orange)

                    if let until = model.status?.pausedUntil, until > Date() {
                        Button("恢復", systemImage: "play.fill") { Task { await model.perform(.resume) } }
                    } else {
                        Button("暫停 15 分鐘", systemImage: "pause.fill") { Task { await model.perform(.pause(minutes: 15)) } }
                        Button("暫停 1 小時", systemImage: "pause.fill") { Task { await model.perform(.pause(minutes: 60)) } }
                    }

                    if model.busy {
                        ProgressView()
                    } else if let error = model.lastError {
                        Text(error).font(.caption2).foregroundStyle(.red).multilineTextAlignment(.center)
                    } else if let route = model.lastRoute {
                        Text(route).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle(model.pairing?.macName ?? "Presence")
            .task { await model.perform(.status) }
        }
    }
}
