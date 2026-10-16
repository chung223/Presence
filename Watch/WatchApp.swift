import Observation
import PresenceLink
import StoreKit
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
    /// iPhone 同步過來的 Presence Pro 狀態（存起來，手錶 App 重開也記得）。
    private(set) var phonePro = UserDefaults.standard.bool(forKey: "proFromPhone")
    /// 手錶自己向 App Store 查到的 Presence Pro（同一個 App 紀錄，iPhone 上買的手錶也查得到）。
    private(set) var ownPro = false
    /// 能不能用簡報遙控。
    var isPro: Bool { phonePro || ownPro }

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
            pairing = PairingInfo(id: UUID(), macName: "MacBook Pro", key: Data(repeating: 7, count: 32))
            status = LinkStatus(macName: "MacBook Pro", presence: .near,
                                summary: String(localized: "Apple Watch 在附近 · -52 dBm"),
                                locked: false)
            lastUpdate = Date()
            lastRoute = String(localized: "經由 iPhone")
            if UserDefaults.standard.string(forKey: "PresenceDemoState") == "presenter" {
                // 講了 12 分半、預定 20 分鐘，Keynote 在最前面
                status?.presenter = .presenting
                status?.presentationStartedAt = Date().addingTimeInterval(-750)
                status?.presentationMinutes = 20
                status?.frontApp = "Keynote"
                status?.frontAppPresents = true
            }
            phonePro = UserDefaults.standard.object(forKey: "PresencePro").map { _ in UserDefaults.standard.bool(forKey: "PresencePro") } ?? true
            demo = true
            return
        }
        #endif
        Task { await checkOwnPurchases() }
        pairing = PairingKeychain.load()
        link.pairing = pairing
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    private func checkOwnPurchases() async {
        var purchases: [ProPurchase] = []
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement else { continue }
            purchases.append(ProPurchase(productID: transaction.productID, expirationDate: transaction.expirationDate,
                                         revocationDate: transaction.revocationDate, isUpgraded: transaction.isUpgraded))
        }
        ownPro = ProAccess.isActive(purchases)
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
        #if DEBUG
        if demo { return true }
        #endif
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
        if let pro = context["pro"] as? Bool, pro != phonePro {
            phonePro = pro
            UserDefaults.standard.set(pro, forKey: "proFromPhone")
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
    @State private var showingPresenter = false

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
                VStack(spacing: 8) {
                    let presence = model.status?.presence ?? .waiting
                    HStack(spacing: 8) {
                        Image(systemName: model.status?.locked == true ? "lock.fill" : presence.symbol)
                            .foregroundStyle(model.status?.locked == true ? .orange : presence.tint)
                            .frame(width: 22)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.status?.summary ?? String(localized: "尚未取得狀態"))
                                .font(.footnote)
                                .lineLimit(2)
                            if let updated = model.lastUpdate {
                                Text("\(Text(updated, style: .relative))前更新").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 0)
                    }

                    // 跟 iPhone 主畫面一樣，兩個主要動作並排
                    HStack(spacing: 6) {
                        Button {
                            Task { await model.perform(.lock) }
                        } label: {
                            WatchTile(title: "鎖定", symbol: "lock.fill", prominent: true)
                        }
                        .buttonStyle(.plain)

                        Button {
                            showingPresenter = true
                        } label: {
                            WatchTile(title: "簡報", symbol: "play.rectangle.fill", prominent: false, badge: model.isPro ? nil : "PRO")
                        }
                        .buttonStyle(.plain)
                    }

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
            .navigationDestination(isPresented: $showingPresenter) {
                if model.isPro { WatchPresenterView(model: model) } else { WatchProView() }
            }
            .task { await model.refreshIfStale() }
            #if DEBUG
            .onAppear {
                if UserDefaults.standard.string(forKey: "PresenceDemoState") == "presenter" { showingPresenter = true }
            }
            #endif
        }
    }
}

/// 主畫面的大按鈕：鎖定是橘色實心，簡報是深色底配橘色圖示（跟 iPhone 一致）。
private struct WatchTile: View {
    let title: LocalizedStringKey
    let symbol: String
    let prominent: Bool
    var badge: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(prominent ? .white : .orange)
                Spacer(minLength: 0)
                if let badge {
                    Text(badge)
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.orange, in: Capsule())
                }
            }
            Spacer(minLength: 0)
            Text(title).font(.headline).foregroundStyle(.white)
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(prominent
                      ? AnyShapeStyle(LinearGradient(colors: [Color(red: 1.0, green: 0.66, blue: 0.24), Color(red: 0.97, green: 0.42, blue: 0.08)],
                                                     startPoint: .top, endPoint: .bottom))
                      : AnyShapeStyle(Color.white.opacity(0.14)))
        }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

/// 沒有 Presence Pro 時，簡報按鈕打開這頁：手錶上不賣，請到 iPhone 升級。
private struct WatchProView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.orange)
                Text("Presence Pro").font(.headline)
                Text("用手錶翻頁、轉錶冠或兩指互點，是 Presence Pro 的功能。")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                Text("請在 iPhone 的 Presence Remote 點「簡報遙控」升級，手錶會自動開通。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .navigationTitle("簡報")
    }
}

/// 手錶上的簡報遙控：點按、轉數位錶冠，或用雙指互點（Series 9、Ultra 2 以後）翻到下一頁，翻成功會震一下。
/// 打開時 Mac 暫停自動鎖定，離開這頁就恢復。計時跟 iPhone 設的演講長度同步，剩 5 分鐘、時間到時震動。
struct WatchPresenterView: View {
    let model: WatchModel
    @State private var openedAt = Date()
    @State private var crown = 0.0
    @State private var crownStep = 0
    @State private var nextDone = 0

    var body: some View {
        let status = model.status
        let presenting = status?.presenter == .presenting
        let endsAt = presenting ? status?.presentationEndsAt : nil
        VStack(spacing: 6) {
            if let notice = model.lastError ?? wrongApp(status) {
                Label(notice, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            // 跟 iPhone 的簡報畫面一樣：「下一頁」佔大部分畫面，「上一頁」小一點放下面
            Button { send(.next) } label: {
                VStack(spacing: 2) {
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 40, weight: .bold))
                        .symbolEffect(.wiggle.forward, value: nextDone)
                    Text("下一頁").font(.headline)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 1.0, green: 0.66, blue: 0.24), Color(red: 0.97, green: 0.42, blue: 0.08)],
                                             startPoint: .top, endPoint: .bottom))
                }
                .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            }
            .buttonStyle(WatchPressStyle())
            .handGestureShortcut(.primaryAction)

            Button { send(.previous) } label: {
                Label("上一頁", systemImage: "chevron.backward")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .background(Capsule().fill(.white.opacity(0.14)))
                    .contentShape(Capsule())
            }
            .buttonStyle(WatchPressStyle())
        }
        .padding(.horizontal, 2)
        .padding(.bottom, 6)
        // 用到螢幕最下面：下面留白的話「下一頁」會變小
        .ignoresSafeArea(edges: .bottom)
        .focusable()
        .digitalCrownRotation($crown, from: -10_000, through: 10_000, by: 1, sensitivity: .low,
                              isContinuous: false, isHapticFeedbackEnabled: true)
        // 錶冠只拿來翻頁，不用顯示捲動的指示條
        .digitalCrownAccessory(.hidden)
        .onChange(of: crown) { _, value in
            // 轉超過幾格才翻一頁，免得碰到錶冠就翻
            let step = Int((value / 4).rounded(.towardZero))
            guard step != crownStep else { return }
            send(step > crownStep ? .next : .previous)
            crownStep = step
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                WatchClock(start: presenting ? status?.presentationStartedAt ?? openedAt : openedAt,
                           minutes: presenting ? status?.presentationMinutes : nil)
            }
        }
        .task { await model.perform(.presentation(active: true)) }
        // 剩 5 分鐘、時間到時輕敲手腕（手錶 App 開著時；手機鎖著時 iPhone 的通知也會轉到手錶）
        .task(id: endsAt) {
            guard let endsAt else { return }
            for offset in [-300.0, 0] {
                let wait = endsAt.addingTimeInterval(offset).timeIntervalSinceNow
                guard wait > 0 else { continue }
                try? await Task.sleep(for: .seconds(wait))
                if Task.isCancelled { return }
                WKInterfaceDevice.current().play(.notification)
            }
        }
        .onDisappear {
            // 沒在簡報（例如 Mac 還沒允許）就不必通知 Mac
            guard model.status?.presenter == .presenting else { return }
            Task { await model.perform(.presentation(active: false)) }
        }
    }

    /// Mac 最前面不是簡報 App 時提醒：翻頁的按鍵會送到那裡。
    private func wrongApp(_ status: LinkStatus?) -> String? {
        guard status?.frontAppPresents == false, let app = status?.frontApp else { return nil }
        return String(localized: "最前面是「\(app)」")
    }

    private func send(_ action: PresenterAction) {
        Task {
            let done = await model.perform(.presenter(action))
            WKInterfaceDevice.current().play(done ? .click : .failure)
            if done, action == .next { nextDone += 1 }
        }
    }
}

/// 按下時縮一點、亮一點。
private struct WatchPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .brightness(configuration.isPressed ? 0.08 : 0)
            .animation(.spring(duration: 0.2, bounce: 0.4), value: configuration.isPressed)
    }
}

/// 有設演講長度就倒數（剩 5 分鐘變橘色、超時變紅色），沒設就顯示講了多久。
private struct WatchClock: View {
    let start: Date
    let minutes: Int?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = minutes.map { start.addingTimeInterval(TimeInterval($0 * 60)).timeIntervalSince(context.date) }
            let seconds = Int((remaining.map(abs) ?? context.date.timeIntervalSince(start)).rounded(.down))
            let text = (remaining.map { $0 < 0 } == true ? "+" : "") + String(format: "%d:%02d", seconds / 60, seconds % 60)
            Text(text)
                .font(.system(.footnote, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(remaining.map { $0 < 0 ? Color.red : $0 <= 300 ? Color.orange : Color.white } ?? Color.orange)
        }
    }
}
