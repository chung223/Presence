import PresenceLink
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
            Text("從 iPhone 和 Apple Watch 鎖定你的 Mac、暫停或恢復 Presence，Mac 鎖定時也會通知你。")
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

struct ControlView: View {
    let model: RemoteModel
    @State private var showingSettings = false
    @State private var successCount = 0

    var body: some View {
        let link = model.link
        let status = link.status
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    StatusCard(status: status, connection: link.state, lastUpdate: link.lastUpdate)

                    Button {
                        run(.lock)
                    } label: {
                        Label("立即鎖定 Mac", systemImage: "lock.fill")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(.orange)

                    if let until = status?.pausedUntil, until > Date() {
                        Button {
                            run(.resume)
                        } label: {
                            Label("恢復自動鎖定與解鎖", systemImage: "play.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    } else {
                        Menu {
                            Button("15 分鐘") { run(.pause(minutes: 15)) }
                            Button("1 小時") { run(.pause(minutes: 60)) }
                            Button("4 小時") { run(.pause(minutes: 240)) }
                        } label: {
                            Label("暫停自動鎖定與解鎖", systemImage: "pause.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }

                    if model.busy {
                        ProgressView()
                    } else if let error = model.lastError {
                        Text(error).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center)
                    }

                    Text("也可以對 Siri 說「用 Presence Remote 鎖定 Mac」，或把「鎖定 Mac」加到動作按鈕、控制中心旁的「捷徑」。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
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
            .sensoryFeedback(.success, trigger: successCount)
        }
    }

    private func run(_ command: LinkCommand) {
        Task {
            if case .success = await model.perform(command) { successCount += 1 }
        }
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

    var body: some View {
        NavigationStack {
            Form {
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
                    Text("Mac 因為你離開而自動鎖定、或你不在附近時被手動解鎖，會發通知給你。")
                }
                Section {
                    Text("Presence Remote 透過藍牙連到 Mac 上的 Presence，指令都經過加密。Apple Watch 會透過這支 iPhone 取得配對。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("設定")
            .toolbar {
                Button("完成") { dismiss() }
            }
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
}
