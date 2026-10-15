import PresenceLink
import SwiftUI

/// 簡報遙控：像簡報筆一樣翻頁。打開時 Mac 暫停自動鎖定，鎖定畫面與動態島也有翻頁按鈕；關掉就恢復。
///
/// 一律用深色：會議室多半關燈，亮白的手機畫面很刺眼，也會被台下看見。
struct PresenterView: View {
    let model: RemoteModel
    @Environment(\.dismiss) private var dismiss
    @State private var startedAt = Date()
    @State private var taps = 0
    @State private var failures = 0
    @State private var nextDone = 0
    @State private var previousDone = 0

    var body: some View {
        let support = model.presenterSupport
        let connected = model.link.state == .connected
        let ready = connected && (support == .enabled || support == .presenting)

        VStack(spacing: 14) {
            header(connected: connected)

            if let message = guidance(support, connected: connected) ?? model.lastError {
                Notice(message: message)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Group {
                Button { send(.next) } label: { NextPad(done: nextDone) }
                    .buttonStyle(PadStyle())
                    // 也可以像翻書一樣滑：向左滑下一頁、向右滑上一頁
                    .simultaneousGesture(DragGesture(minimumDistance: 30).onEnded { value in
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        send(value.translation.width < 0 ? .next : .previous)
                    })

                Button { send(.previous) } label: { PreviousBar(done: previousDone) }
                    .buttonStyle(PadStyle())

                HStack(spacing: 10) {
                    tile(.start, title: "開始播放", symbol: "play.fill")
                    tile(.blank, title: "黑畫面", symbol: "eye.slash.fill")
                    tile(.end, title: "結束播放", symbol: "stop.fill")
                }
            }
            .disabled(!ready)
            .opacity(ready ? 1 : 0.4)
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
        .background { StageBackground() }
        .preferredColorScheme(.dark)
        .animation(.snappy, value: model.lastError)
        .sensoryFeedback(.impact(flexibility: .solid, intensity: 0.8), trigger: taps)
        .sensoryFeedback(.error, trigger: failures)
        .onAppear {
            // 簡報中手機不要自動鎖定；鎖了也還有鎖定畫面的翻頁按鈕
            UIApplication.shared.isIdleTimerDisabled = true
            Task { await model.setPresentation(true) }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            Task { await model.setPresentation(false) }
        }
    }

    private func header(connected: Bool) -> some View {
        HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("結束簡報")

            Spacer()

            VStack(spacing: 2) {
                Text(startedAt, style: .timer)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .accessibilityLabel("簡報時間")
                HStack(spacing: 6) {
                    Circle()
                        .fill(connected ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(model.pairing?.macName ?? "Mac")
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityValue(connected ? Text("已連線") : Text("未連線"))
            }

            Spacer()

            Button { startedAt = Date() } label: {
                Image(systemName: "arrow.counterclockwise").font(.headline).frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("重新計時")
        }
        .padding(.top, 4)
    }

    private func tile(_ action: PresenterAction, title: LocalizedStringKey, symbol: String) -> some View {
        Button { send(action) } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                Text(title).font(.caption.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(Card(radius: 20))
        }
        .buttonStyle(PadStyle())
    }

    /// 還不能翻頁時的說明。
    private func guidance(_ support: PresenterSupport?, connected: Bool) -> String? {
        guard connected else { return String(localized: "正在連線到 Mac…") }
        switch support {
        case nil: return String(localized: "請把 Mac 上的 Presence 更新到最新版，才能簡報遙控")
        case .disabled: return CommandRefusal.presenterNotAllowed.message
        case .enabled, .presenting: return nil
        }
    }

    private func send(_ action: PresenterAction) {
        taps += 1
        Task {
            guard await model.present(action) else {
                failures += 1
                return
            }
            switch action {
            case .next: nextDone += 1
            case .previous: previousDone += 1
            default: break
            }
        }
    }
}

// MARK: - 元件

/// 主要的翻頁區：整塊都能按，Mac 翻頁成功時箭頭彈一下。
private struct NextPad: View {
    let done: Int

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(LinearGradient(colors: [Color(red: 1.0, green: 0.66, blue: 0.24), Color(red: 0.97, green: 0.42, blue: 0.08)],
                                         startPoint: .top, endPoint: .bottom))
                    .shadow(color: Color.orange.opacity(0.45), radius: 28, y: 10)
                Image(systemName: "chevron.forward")
                    .font(.system(size: 52, weight: .bold))
                    .foregroundStyle(.white)
                    .symbolEffect(.wiggle.forward, value: done)
            }
            .frame(width: 128, height: 128)

            VStack(spacing: 6) {
                Text("下一頁").font(.title2.weight(.bold))
                Text("點一下，或向左滑").font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Card(radius: 36))
        .contentShape(.rect(cornerRadius: 36))
    }
}

private struct PreviousBar: View {
    let done: Int

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "chevron.backward")
                .font(.system(size: 20, weight: .bold))
                .symbolEffect(.wiggle.backward, value: done)
                .frame(width: 44, height: 44)
                .background(Circle().fill(.white.opacity(0.12)))
            Text("上一頁").font(.headline)
            Spacer()
            Text("或向右滑").font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 72)
        .background(Card(radius: 24))
        .contentShape(.rect(cornerRadius: 24))
    }
}

/// 深色半透明的卡片底。
private struct Card: View {
    let radius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(.white.opacity(0.07))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(.white.opacity(0.09), lineWidth: 1)
            }
    }
}

/// 按下時縮一點、亮一點。
private struct PadStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .brightness(configuration.isPressed ? 0.06 : 0)
            .animation(.spring(duration: 0.25, bounce: 0.4), value: configuration.isPressed)
    }
}

private struct Notice: View {
    let message: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.footnote)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.orange.opacity(0.14)))
    }
}

/// 近乎全黑，底部透一點橘色的光，呼應翻頁按鈕。
private struct StageBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.045, green: 0.05, blue: 0.06)
            RadialGradient(colors: [Color.orange.opacity(0.16), .clear], center: .bottom, startRadius: 0, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}
