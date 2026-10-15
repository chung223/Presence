import Observation
import PresenceLink
import SwiftUI
import WatchConnectivity
import WatchKit
import WidgetKit

@main
struct WatchApp: App {
    @State private var model = WatchModel.shared

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                WatchControlView(model: model)
            }
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
    #if DEBUG
    @ObservationIgnored private var demo = false
    #endif

    override private init() {
        super.init()
        #if DEBUG
        // App Store 截圖用：-PresenceDemo YES，不連 iPhone 也不連藍牙
        if UserDefaults.standard.bool(forKey: "PresenceDemo") {
            let chinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true
            pairing = PairingInfo(id: UUID(), macName: "MacBook Pro", key: Data(repeating: 7, count: 32))
            status = LinkStatus(macName: "MacBook Pro", presence: .near,
                                summary: chinese ? "Apple Watch 在附近 · -52 dBm" : "Apple Watch nearby · -52 dBm",
                                locked: false)
            lastUpdate = Date()
            lastRoute = String(localized: "經由 iPhone")
            demo = true
            return
        }
        #endif
        pairing = PairingKeychain.load()
        link.pairing = pairing
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    /// 打開 App 時：先顯示 iPhone 同步過來的狀態，超過一分鐘沒更新才在背景悄悄更新。
    func refreshIfStale() async {
        #if DEBUG
        if demo { return }
        #endif
        if let lastUpdate, Date().timeIntervalSince(lastUpdate) < 60 { return }
        await perform(.status, quiet: true)
    }

    /// `quiet`：背景更新，不轉圈、失敗也不顯示錯誤，保留手上的狀態。回傳 Mac 有沒有做成。
    @discardableResult
    func perform(_ command: LinkCommand, quiet: Bool = false) async -> Bool {
        guard pairing != nil else {
            lastError = String(localized: "請先在 iPhone 的 Presence Remote 配對 Mac")
            return false
        }
        if !quiet { busy = true }
        defer { if !quiet { busy = false } }
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
                return apply(result, route: String(localized: "經由 iPhone"))
            }
            LinkLog.write("[手錶] 經由 iPhone 失敗，改直接連線")
        }
        // 背景更新不值得直接連 Mac：耗手錶的電，也會佔用 Mac 的連線
        if quiet { return false }
        switch await link.send(command) {
        case .success(let status):
            LinkLog.write("[手錶] 直接連線成功")
            return apply(.success(status), route: String(localized: "直接連線"))
        case .failure(let failure):
            LinkLog.write("[手錶] 直接連線失敗：\(failure)")
            return apply(.failure(failure.message), route: nil)
        }
    }

    private enum Outcome {
        case success(LinkStatus)
        case failure(String)
    }

    /// 回傳 Mac 有沒有做成：收到回覆但 Mac 拒絕（例如沒允許簡報遙控）也算失敗。
    @discardableResult
    private func apply(_ outcome: Outcome, route: String?) -> Bool {
        switch outcome {
        case .success(let status):
            self.status = status
            lastUpdate = Date()
            lastError = status.refusalMessage
            lastRoute = route
            publishWidgetStatus()
            return status.refusal == nil
        case .failure(let message):
            lastError = message
            return false
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
            // WatchConnectivity 在背景執行緒呼叫這兩個回呼。不標 @Sendable 的話，Swift 6 會把它們當成
            // 主執行緒的程式，執行時檢查失敗就中止 App（2026-10-14 手錶 App 一打開就閃退）。
            WCSession.default.sendMessage(["command": data], replyHandler: { @Sendable reply in once.resume(reply) },
                                          errorHandler: { @Sendable _ in once.resume(nil) })
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
/// 不屬於主執行緒：WatchConnectivity 從背景執行緒呼叫 `resume`，用鎖保護。
nonisolated private final class Once: @unchecked Sendable {
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
                    if let updated = model.lastUpdate {
                        Text("\(Text(updated, style: .relative))前更新").font(.caption2).foregroundStyle(.secondary)
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

                    NavigationLink {
                        WatchPresenterView(model: model)
                    } label: {
                        Label("簡報遙控", systemImage: "play.rectangle").frame(maxWidth: .infinity)
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
            .task { await model.refreshIfStale() }
        }
    }
}

/// 手錶上的簡報遙控：點按、轉數位錶冠，或用雙指互點（Series 9、Ultra 2 以後）翻到下一頁，翻成功會震一下。
/// 打開時 Mac 暫停自動鎖定，離開這頁就恢復。外觀跟 iPhone 的簡報畫面一致：橘色的大「下一頁」。
struct WatchPresenterView: View {
    let model: WatchModel
    @State private var startedAt = Date()
    @State private var crown = 0.0
    @State private var crownStep = 0
    @State private var nextDone = 0

    var body: some View {
        VStack(spacing: 8) {
            Button { send(.next) } label: {
                ZStack {
                    Circle()
                        .fill(LinearGradient(colors: [Color(red: 1.0, green: 0.66, blue: 0.24), Color(red: 0.97, green: 0.42, blue: 0.08)],
                                             startPoint: .top, endPoint: .bottom))
                    VStack(spacing: 2) {
                        Image(systemName: "chevron.forward")
                            .font(.system(size: 34, weight: .bold))
                            .symbolEffect(.wiggle.forward, value: nextDone)
                        Text("下一頁").font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .buttonStyle(.plain)
            .handGestureShortcut(.primaryAction)

            Button { send(.previous) } label: {
                Label("上一頁", systemImage: "chevron.backward")
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonBorderShape(.capsule)

            if let error = model.lastError {
                Text(error).font(.caption2).foregroundStyle(.orange).lineLimit(2).multilineTextAlignment(.center)
            }
        }
        .focusable()
        .digitalCrownRotation($crown, from: -10_000, through: 10_000, by: 1, sensitivity: .low,
                              isContinuous: false, isHapticFeedbackEnabled: true)
        .onChange(of: crown) { _, value in
            // 轉超過幾格才翻一頁，免得碰到錶冠就翻
            let step = Int((value / 4).rounded(.towardZero))
            guard step != crownStep else { return }
            send(step > crownStep ? .next : .previous)
            crownStep = step
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Text(startedAt, style: .timer)
                    .font(.system(.footnote, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.orange)
            }
        }
        .navigationTitle("簡報")
        .task { await model.perform(.presentation(active: true)) }
        .onDisappear {
            // 沒在簡報（例如 Mac 還沒允許）就不必通知 Mac
            guard model.status?.presenter == .presenting else { return }
            Task { await model.perform(.presentation(active: false)) }
        }
    }

    private func send(_ action: PresenterAction) {
        Task {
            let done = await model.perform(.presenter(action))
            WKInterfaceDevice.current().play(done ? .click : .failure)
            if done, action == .next { nextDone += 1 }
        }
    }
}
