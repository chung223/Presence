import CoreImage.CIFilterBuiltins
import SwiftUI

/// 配對 iPhone 的 Presence Remote；手錶會透過 iPhone 取得同一組配對。
struct RemoteDevicesView: View {
    let model: AppModel
    @State private var showingPairing = false
    @State private var testing = false
    @State private var testResult: String?

    var body: some View {
        let link = model.link
        Form {
            Section {
                if link.devices.isEmpty {
                    Text("還沒有配對任何裝置。").foregroundStyle(.secondary)
                }
                ForEach(link.devices) { device in
                    HStack(spacing: 12) {
                        Image(systemName: "iphone")
                            .font(.title2)
                            .foregroundStyle(link.connected[device.id] != nil ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name ?? String(localized: "未命名裝置"))
                            Text(detail(for: device, connectedName: link.connected[device.id]))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("取消配對", role: .destructive) { link.remove(device.id) }
                    }
                }
                LabeledContent("加入 iPhone") {
                    Button("配對新的 iPhone…") { showingPairing = true }
                }
                if !link.devices.isEmpty {
                    LabeledContent {
                        HStack {
                            if testing { ProgressView().controlSize(.small) }
                            Button("測試") {
                                testing = true
                                Task {
                                    testResult = await model.testCompanionConfirmation()
                                    testing = false
                                }
                            }
                            .disabled(testing)
                        }
                    } label: {
                        Text("加密確認")
                        Text(testResult ?? String(localized: "檢查 iPhone 能不能在解鎖前回應 Mac 的確認"))
                    }
                }
            } header: {
                Text("已配對的裝置")
            } footer: {
                Text("在 iPhone 安裝 Presence Remote 並配對後，可以從手機、Apple Watch、Siri 或「捷徑」立即鎖定這台 Mac、暫停或恢復，Mac 鎖定時也會通知你。連線走藍牙，指令都經過加密；Apple Watch 會透過 iPhone 取得同一組配對。")
            }

            Section {
                Toggle("允許簡報遙控", isOn: Binding(
                    get: { model.preferences.allowPresenter },
                    set: { model.preferences.allowPresenter = $0 }
                ))
                if model.preferences.allowPresenter, !model.accessibilityGranted {
                    LabeledContent("需要輔助使用權限才能翻頁") {
                        Button("打開設定") { Accessibility.openSettings() }
                    }
                }
            } header: {
                Text("簡報遙控")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("讓配對的 iPhone 和 Apple Watch 像簡報筆一樣翻頁、開始與結束播放、把投影畫面變黑。Presence 會對最前面的 App 按方向鍵，Keynote、PowerPoint、Google 簡報和 PDF 都適用；只會送這幾個鍵，螢幕鎖著時也不會送。簡報時暫停自動鎖定（最多 3 小時），在手機上結束簡報就恢復。")
                    Text("手機與手錶上的簡報遙控是 Presence Remote 的付費功能（Presence Pro）；Mac 上的 Presence 一樣免費。")
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("手機與手錶")
        .sheet(isPresented: $showingPairing) { PairingSheet(link: link) }
    }

    private func detail(for device: PairedDevice, connectedName: String?) -> String {
        if let connectedName { return String(localized: "已連線（\(connectedName)）") }
        if let seen = device.lastSeen {
            return String(localized: "上次連線：\(seen.formatted(.relative(presentation: .named)))")
        }
        return String(localized: "配對於 \(device.createdAt.formatted(date: .abbreviated, time: .shortened))")
    }
}

private struct PairingSheet: View {
    let link: LinkService
    @Environment(\.dismiss) private var dismiss
    @State private var qrImage: NSImage?

    var body: some View {
        VStack(spacing: 18) {
            if link.pairingCompleted {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.green)
                Text("配對完成").font(.title2.weight(.semibold))
                Text("之後可以從 iPhone 或 Apple Watch 控制這台 Mac。")
                    .foregroundStyle(.secondary)
                Button("完成") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Text("配對 iPhone").font(.title2.weight(.semibold))
                Text("在 iPhone 打開 Presence Remote，點「掃描 QR code」，對準下面的圖。這個 QR code 含有配對用的金鑰，請不要拍給別人。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let qrImage {
                    Image(nsImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 240, height: 240)
                        .padding(12)
                        .background(.white, in: .rect(cornerRadius: 12))
                }
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("等待 iPhone 連線…").foregroundStyle(.secondary)
                }
                Button("取消", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(28)
        .frame(width: 420)
        .onAppear {
            let pairing = link.beginPairing()
            qrImage = Self.qrCode(pairing.qrString)
        }
        .onDisappear { link.cancelPairing() }
    }

    private static func qrCode(_ text: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: output.extent.width, height: output.extent.height))
    }
}
