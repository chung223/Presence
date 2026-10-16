import PresenceLink
import StoreKit
import SwiftUI
import VisionKit

@main
struct RemoteApp: App {
    @State private var model = RemoteModel.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if model.pairing == nil {
                    OnboardingView(model: model)
                } else {
                    ControlView(model: model)
                }
            }
            .task { await RemoteModel.requestNotificationPermission() }
            #if DEBUG
            // 宣傳影片的結尾蓋住整個畫面（包括導覽列的設定按鈕）
            .overlay { if model.demoEndCard { DemoEndCard() } }
            .animation(.easeInOut(duration: 0.6), value: model.demoEndCard)
            #endif
        }
    }
}

// MARK: - 配對

struct OnboardingView: View {
    let model: RemoteModel
    @State private var scanning = false
    @State private var invalidCode = false

    /// 模擬器沒有相機；截圖的示範模式照樣顯示成可以按。
    private var scannerAvailable: Bool {
        #if DEBUG
        if RemoteModel.isDemo { return true }
        #endif
        return DataScannerViewController.isSupported
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: 72))
                .foregroundStyle(.tint)
            Text("Presence Remote").font(.largeTitle.bold())
            Text("從 iPhone 和 Apple Watch 鎖定你的 Mac、暫停或恢復 Presence，Mac 鎖定時也會通知你。升級 Presence Pro，還能當簡報筆翻頁。")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Label("在 Mac 打開 Presence，到「手機與手錶」按「配對新的 iPhone」", systemImage: "1.circle")
                Label("點下面的按鈕，掃描 Mac 上的 QR code", systemImage: "2.circle")
            }
            .font(.callout)
            Spacer()
            if invalidCode {
                Text("這不是 Presence 的配對 QR code。").foregroundStyle(.red)
            }
            Button {
                scanning = true
            } label: {
                Label("掃描 QR code", systemImage: "qrcode.viewfinder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!scannerAvailable)
        }
        .padding(28)
        .sheet(isPresented: $scanning) {
            QRScannerView { code in
                scanning = false
                invalidCode = !model.pair(with: code)
            }
            .ignoresSafeArea()
        }
    }
}

/// 用 VisionKit 掃 QR code，掃到第一個就回傳。
struct QRScannerView: UIViewControllerRepresentable {
    let onFound: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onFound: onFound) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onFound: (String) -> Void
        private var done = false

        init(onFound: @escaping (String) -> Void) {
            self.onFound = onFound
        }

        func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !done else { return }
            for item in items {
                if case .barcode(let code) = item, let text = code.payloadStringValue {
                    done = true
                    scanner.stopScanning()
                    onFound(text)
                    return
                }
            }
        }
    }
}

// MARK: - 控制

/// 主畫面：上面是 Mac 的狀態，下面兩張大卡片並排（立即鎖定、簡報遙控），再下面是暫停。
/// 簡報遙控是 Presence Pro 的功能：沒有 Pro 時卡片上有「PRO」標記，點了打開付費畫面。
struct ControlView: View {
    let model: RemoteModel
    @State private var showingSettings = false
    @State private var presenting = false
    @State private var showingPaywall = false
    @State private var showingIntro = false
    @State private var successCount = 0
    @AppStorage("seenPresenterIntro") private var seenPresenterIntro = false
    private var store: ProStore { .shared }

    var body: some View {
        let link = model.link
        let status = link.status
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    StatusCard(status: status, connection: link.state, lastUpdate: link.lastUpdate)

                    HStack(spacing: 12) {
                        Button { run(.lock) } label: {
                            ActionCard(title: "立即鎖定", detail: Text("鎖定 \(model.pairing?.macName ?? "Mac")"),
                                       symbol: "lock.fill", style: .lock)
                        }
                        .buttonStyle(CardPressStyle())

                        Button { openPresenter() } label: {
                            ActionCard(title: "簡報遙控", detail: Text("翻頁、計時，手錶也能用"),
                                       symbol: "play.rectangle.fill", style: .presenter, badge: store.isPro ? nil : "PRO")
                        }
                        .buttonStyle(CardPressStyle())
                    }

                    PauseRow(status: status) { run($0) }

                    if model.busy {
                        ProgressView()
                    } else if let error = model.lastError {
                        Text(error).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
                    }

                    Text("也可以對 Siri 說「用 Presence Remote 鎖定電腦」，或把「鎖定 Mac」加到動作按鈕、控制中心或「捷徑」。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 6)
                        #if DEBUG
                        // 宣傳影片的字幕放在這附近，不要疊在一起
                        .opacity(model.demoCaption == nil ? 1 : 0)
                        #endif
                }
                .padding()
            }
            .navigationTitle(model.pairing?.macName ?? "Presence")
            .toolbar {
                Button("設定", systemImage: "gearshape") { showingSettings = true }
            }
            .refreshable { await model.perform(.status) }
            .task { await model.perform(.status) }
            .sheet(isPresented: $showingSettings) { SettingsView(model: model) }
            .sheet(isPresented: $showingPaywall) { PaywallView() }
            .sheet(isPresented: $showingIntro) {
                PresenterIntroView(isPro: store.isPro) { wantsPresenter in
                    showingIntro = false
                    if wantsPresenter { openPresenter() }
                }
            }
            .fullScreenCover(isPresented: $presenting) { PresenterView(model: model) }
            .onAppear {
                #if DEBUG
                if RemoteModel.isDemo {
                    switch UserDefaults.standard.string(forKey: "PresenceDemoState") {
                    case "presenter": presenting = true
                    case "paywall": showingPaywall = true
                    case "intro": showingIntro = true
                    case "settings": showingSettings = true
                    default: break
                    }
                    return
                }
                #endif
                // 更新後第一次打開：介紹簡報遙控（只出現一次）
                if !seenPresenterIntro {
                    seenPresenterIntro = true
                    showingIntro = true
                }
            }
            .sensoryFeedback(.success, trigger: successCount)
            #if DEBUG
            .overlay(alignment: .bottom) { DemoCaption(text: model.demoCaption) }
            .onChange(of: model.demoPresenter) { _, on in presenting = on }
            #endif
        }
    }

    private func run(_ command: LinkCommand) {
        Task {
            if case .success = await model.perform(command) { successCount += 1 }
        }
    }

    private func openPresenter() {
        Task {
            // 從介紹頁的按鈕過來時，等介紹頁收起來再打開下一個畫面
            try? await Task.sleep(for: .milliseconds(showingIntro ? 450 : 0))
            if await store.checkPro() { presenting = true } else { showingPaywall = true }
        }
    }
}

/// 主畫面的大卡片。鎖定是橘色實心；簡報遙控用簡報畫面的深色舞台，配橘色圖示。
private struct ActionCard: View {
    enum Style { case lock, presenter }

    let title: LocalizedStringKey
    let detail: Text
    let symbol: String
    let style: Style
    var badge: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: symbol)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background {
                        switch style {
                        case .lock: Circle().fill(.white.opacity(0.22))
                        case .presenter: Circle().fill(LinearGradient.stageOrange)
                        }
                    }
                Spacer(minLength: 4)
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.heavy))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(LinearGradient.stageOrange, in: Capsule())
                } else {
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.top, 4)
                }
            }
            Spacer(minLength: 16)
            Text(title)
                .font(.title3.weight(.bold))
                .foregroundStyle(.white)
            detail
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 168, alignment: .topLeading)
        .background {
            let shape = RoundedRectangle(cornerRadius: 26, style: .continuous)
            switch style {
            case .lock:
                shape.fill(LinearGradient(colors: [Color(red: 1.0, green: 0.62, blue: 0.2), Color(red: 0.93, green: 0.36, blue: 0.06)],
                                          startPoint: .topLeading, endPoint: .bottomTrailing))
            case .presenter:
                ZStack {
                    shape.fill(Color(red: 0.07, green: 0.075, blue: 0.09))
                    shape.fill(RadialGradient(colors: [Color.orange.opacity(0.28), .clear], center: .bottomTrailing,
                                              startRadius: 0, endRadius: 190))
                    shape.strokeBorder(.white.opacity(0.08), lineWidth: 1)
                }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// 卡片按下時縮一點。
private struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
    }
}

/// 暫停或恢復自動鎖定與解鎖：一整列，看得出現在的狀態。
private struct PauseRow: View {
    let status: LinkStatus?
    let run: (LinkCommand) -> Void

    var body: some View {
        if let until = status?.pausedUntil, until > Date() {
            Button { run(.resume) } label: {
                row(symbol: "play.circle.fill", tint: .green, title: "恢復自動鎖定與解鎖",
                    detail: Text("暫停到 \(until.formatted(date: .omitted, time: .shortened))"), trailing: nil)
            }
            .buttonStyle(.plain)
        } else {
            Menu {
                Button("15 分鐘") { run(.pause(minutes: 15)) }
                Button("1 小時") { run(.pause(minutes: 60)) }
                Button("4 小時") { run(.pause(minutes: 240)) }
            } label: {
                row(symbol: "pause.circle.fill", tint: .secondary, title: "暫停自動鎖定與解鎖",
                    detail: Text("借別人用電腦、開會時"), trailing: "chevron.up.chevron.down")
            }
            .buttonStyle(.plain)
        }
    }

    private func row(symbol: String, tint: Color, title: LocalizedStringKey, detail: Text, trailing: String?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                detail.font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let trailing {
                Image(systemName: trailing).font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(.background.secondary, in: .rect(cornerRadius: 20))
        .contentShape(.rect(cornerRadius: 20))
    }
}

struct StatusCard: View {
    let status: LinkStatus?
    let connection: LinkCentral.State
    let lastUpdate: Date?

    var body: some View {
        VStack(spacing: 12) {
            let presence = status?.presence ?? .waiting
            Image(systemName: presence.symbol)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(presence.tint)
                .frame(width: 76, height: 76)
                .background(presence.tint.opacity(0.15), in: .circle)
                .contentTransition(.symbolEffect(.replace))
            Text(status?.summary ?? String(localized: "還沒有收到 Mac 的狀態"))
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                if status?.locked == true {
                    Label("Mac 已鎖定", systemImage: "lock.fill")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.orange.opacity(0.15), in: .capsule)
                }
                Label(connection.title, systemImage: connection == .connected ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(minHeight: 24) // 出現「Mac 已鎖定」時，卡片高度不變
            if let lastUpdate {
                Text("更新於 \(lastUpdate.formatted(.relative(presentation: .named)))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(.background.secondary, in: .rect(cornerRadius: 20))
    }
}

struct SettingsView: View {
    let model: RemoteModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingUnpair = false
    @State private var showingPaywall = false
    @State private var managingSubscription = false
    @State private var restoring = false
    @State private var restoreMessage: String?
    private var store: ProStore { .shared }

    var body: some View {
        NavigationStack {
            Form {
                proSection
                Section("配對的 Mac") {
                    LabeledContent("名稱", value: model.pairing?.macName ?? "—")
                    LabeledContent("連線", value: model.link.state.title)
                    Button("取消配對", role: .destructive) { confirmingUnpair = true }
                }
                Section {
                    Button("打開通知設定") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                } header: {
                    Text("通知")
                } footer: {
                    Text("Mac 因為你離開而自動鎖定、或你不在附近時被手動解鎖，會發通知給你。簡報設了演講長度時，剩 5 分鐘和時間到也會通知。")
                }
                Section {
                    Link("隱私權政策", destination: LegalLinks.privacy)
                    Link("使用條款", destination: LegalLinks.terms)
                } header: {
                    Text("關於")
                } footer: {
                    Text("Presence Remote 透過藍牙連到 Mac 上的 Presence，指令都經過加密。Apple Watch 會透過這支 iPhone 取得配對。")
                }
            }
            .navigationTitle("設定")
            .toolbar {
                Button("完成") { dismiss() }
            }
            .sheet(isPresented: $showingPaywall) { PaywallView() }
            .manageSubscriptionsSheet(isPresented: $managingSubscription)
            .task { await store.refresh() }
            .confirmationDialog("要取消與這台 Mac 的配對嗎？", isPresented: $confirmingUnpair, titleVisibility: .visible) {
                Button("取消配對", role: .destructive) {
                    model.unpair()
                    dismiss()
                }
            } message: {
                Text("之後要重新掃描 QR code 才能再控制這台 Mac。Apple Watch 也會一起取消。")
            }
        }
    }

    @ViewBuilder
    private var proSection: some View {
        Section {
            if store.isPro {
                LabeledContent("方案", value: planName)
                if let renewal = store.renewalDate, !store.isLifetime {
                    LabeledContent("下次續訂", value: renewal.formatted(date: .abbreviated, time: .omitted))
                }
                // 買斷不用管理；家人共享的訂閱只能由購買的家人管理
                if store.subscription != nil, !store.isLifetime, !store.isFamilyShared {
                    Button("管理訂閱") { managingSubscription = true }
                }
            } else {
                Button {
                    showingPaywall = true
                } label: {
                    Label("升級 Presence Pro", systemImage: "play.rectangle.fill")
                }
                Button(restoring ? "正在恢復購買…" : "恢復購買") {
                    Task {
                        restoring = true
                        defer { restoring = false }
                        do {
                            let restored = try await store.restore()
                            restoreMessage = restored ? String(localized: "已恢復 Presence Pro。")
                                : String(localized: "這個 Apple 帳號沒有 Presence Pro 的購買紀錄。")
                        } catch {
                            restoreMessage = String(localized: "恢復購買沒有完成（\(error.localizedDescription)）。")
                        }
                    }
                }
                .disabled(restoring)
            }
        } header: {
            Text("Presence Pro")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if let restoreMessage { Text(restoreMessage) }
                Text("簡報遙控（iPhone、Apple Watch、鎖定畫面翻頁）是 Presence Pro 的功能，可以和家人共享。鎖定、暫停、小工具，以及 Mac 上的 Presence 都免費。")
            }
        }
    }

    private var planName: String {
        if store.isLifetime { return String(localized: "一次買斷") }
        let name = switch store.subscription {
        case .monthly: String(localized: "月訂閱")
        case .yearly: String(localized: "年訂閱")
        case .lifetime, nil: String(localized: "已啟用")
        }
        return store.isFamilyShared ? String(localized: "\(name)（家人共享）") : name
    }
}

#if DEBUG
// MARK: - 宣傳影片（開發版的示範腳本）

struct DemoCaption: View {
    let text: String?
    /// 放在畫面上方（簡報畫面的下半部都是按鈕）。
    var top = false

    var body: some View {
        ZStack {
            if let text {
                Text(text)
                    .font(.system(size: 30, weight: .bold))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    // 舊的先淡出、新的再淡入，兩句不會疊在一起
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 16)).animation(.easeOut(duration: 0.35).delay(0.25)),
                        removal: .opacity.animation(.easeIn(duration: 0.2))))
                    .id(text)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(top ? .top : .bottom, top ? 120 : 150)
        .animation(.default, value: text)
    }
}

/// 結尾：跟 App 圖示同一組漸層與符號。
struct DemoEndCard: View {
    var body: some View {
        VStack(spacing: 22) {
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.20, green: 0.78, blue: 0.70), Color(red: 0.10, green: 0.42, blue: 0.85)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 150, height: 150)
                .overlay {
                    // 跟 App 圖示一樣：[手機] ))) [筆電]（scripts/make-icon.swift 的位置縮成 150 點）
                    ZStack {
                        Image(systemName: "iphone.gen3").font(.system(size: 44, weight: .bold)).offset(x: -40)
                        Image(systemName: "wave.3.right").font(.system(size: 22, weight: .bold)).offset(x: -15, y: 2)
                        Image(systemName: "laptopcomputer").font(.system(size: 44, weight: .bold)).offset(x: 24)
                    }
                    .foregroundStyle(.white)
                }
            Text("Presence Remote").font(.system(size: 38, weight: .bold))
            Text("搭配 Mac 上的免費 Presence")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .transition(.opacity)
    }
}
#endif
