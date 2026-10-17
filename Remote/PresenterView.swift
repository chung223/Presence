import PresenceLink
import SwiftUI

/// 簡報遙控：像簡報筆一樣翻頁。打開時 Mac 暫停自動鎖定，鎖定畫面與動態島也有翻頁按鈕；關掉就恢復。
///
/// 一律用深色：會議室多半關燈，亮白的手機畫面很刺眼，也會被台下看見。
struct PresenterView: View {
    let model: RemoteModel
    @Environment(\.dismiss) private var dismiss
    @State private var openedAt = Date()
    @State private var taps = 0
    @State private var failures = 0
    @State private var alerts = 0
    @State private var nextDone = 0
    @State private var previousDone = 0
    @State private var jumping = false
    @State private var tool: Tool = .slides
    @State private var pointerTouches = 0
    @GestureState private var padPressed = false

    private static let lengths = [10, 15, 20, 30, 45, 60]

    var body: some View {
        let status = model.link.status
        let support = model.presenterSupport
        let connected = model.link.state == .connected
        let ready = connected && (support == .enabled || support == .presenting)
        let endsAt = status?.presenter == .presenting ? status?.presentationEndsAt : nil

        VStack(spacing: 14) {
            header(status: status, connected: connected)

            if let message = guidance(support, connected: connected) ?? model.lastError ?? wrongApp(status) {
                Notice(message: message)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Group {
                // 雷射筆、聚光燈要 Mac 0.3 以後；舊版 Mac 只有翻頁
                if model.pointerAvailable {
                    ToolPicker(tool: $tool)
                }
                let tool = model.pointerAvailable ? tool : .slides
                if tool == .slides {
                    // 點一下下一頁，也可以像翻書一樣滑：向左滑下一頁、向右滑上一頁。
                    // 點和滑用同一個手勢判斷；用 Button 加滑動手勢的話，滑一下會被當成點一下再滑一下，翻兩頁。
                    NextPad(done: nextDone)
                        .foregroundStyle(.white)
                        .scaleEffect(padPressed ? 0.97 : 1)
                        .brightness(padPressed ? 0.06 : 0)
                        .animation(.spring(duration: 0.25, bounce: 0.4), value: padPressed)
                        .gesture(DragGesture(minimumDistance: 0)
                            .updating($padPressed) { _, pressed, _ in pressed = true }
                            .onEnded { value in
                                let dx = value.translation.width, dy = value.translation.height
                                if abs(dx) > 40, abs(dx) > abs(dy) {
                                    send(dx < 0 ? .next : .previous)
                                } else if hypot(dx, dy) < 20 {
                                    send(.next)
                                }
                            })
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { send(.next) }

                    Button { send(.previous) } label: { PreviousBar(done: previousDone) }
                        .buttonStyle(PadStyle())
                } else {
                    let mode: PointerUpdate.Mode = tool == .laser ? .laser : .spotlight
                    PointerPad(mode: mode, aspect: model.pointerAspect) { x, y, began in
                        if began { pointerTouches += 1 }
                        model.movePointer(mode, x: x, y: y)
                    } end: {
                        model.endPointer()
                    }
                    HStack(spacing: 10) {
                        Button { send(.previous) } label: { TurnButton(title: "上一頁", symbol: "chevron.backward") }
                        Button { send(.next) } label: { TurnButton(title: "下一頁", symbol: "chevron.forward", prominent: true) }
                    }
                    .buttonStyle(PadStyle())
                }

                // Mac 0.3 以後、允許簡報遙控時才有
                if let volume = model.macVolume {
                    VolumeBar(volume: volume) { level in
                        model.setVolume(level)
                    } mute: { muted in
                        taps += 1
                        Task { if await !model.changeVolume(.mute(muted)) { failures += 1 } }
                    }
                }

                HStack(spacing: 10) {
                    tile(title: "開始播放", symbol: "play.fill") { send(.start) }
                    tile(title: "黑畫面", symbol: "eye.slash.fill") { send(.blank) }
                    tile(title: "跳頁", symbol: "number") { jumping = true }
                    tile(title: "結束播放", symbol: "stop.fill") { send(.end) }
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
        .sensoryFeedback(.impact(weight: .light), trigger: pointerTouches)
        .animation(.snappy, value: tool)
        .sensoryFeedback(.warning, trigger: alerts)
        .sheet(isPresented: $jumping) {
            JumpSheet { slide in
                taps += 1
                Task { if await !model.goToSlide(slide) { failures += 1 } }
            }
        }
        // 剩 5 分鐘、時間到時在手上震一下（App 在前景時系統不顯示通知）
        .task(id: endsAt) {
            guard let endsAt else { return }
            for offset in [-300.0, 0] {
                let wait = endsAt.addingTimeInterval(offset).timeIntervalSinceNow
                guard wait > 0 else { continue }
                try? await Task.sleep(for: .seconds(wait))
                if Task.isCancelled { return }
                alerts += 1
            }
        }
        .onAppear {
            // 簡報中手機不要自動鎖定；鎖了也還有鎖定畫面的翻頁按鈕
            UIApplication.shared.isIdleTimerDisabled = true
            Task { await model.setPresentation(true) }
        }
        .onDisappear {
            model.endPointer()
            UIApplication.shared.isIdleTimerDisabled = false
            Task { await model.setPresentation(false) }
        }
        #if DEBUG
        // 宣傳影片：字幕、自動翻頁、結尾畫面（簡報畫面蓋在主畫面上，主畫面的字幕和結尾看不到）
        .overlay(alignment: .top) { DemoCaption(text: model.demoCaption, top: true) }
        .overlay { if model.demoEndCard { DemoEndCard().environment(\.colorScheme, .light) } }
        .animation(.easeInOut(duration: 0.6), value: model.demoEndCard)
        .onChange(of: model.demoSlideTick) {
            taps += 1
            nextDone += 1
        }
        #endif
    }

    private func header(status: LinkStatus?, connected: Bool) -> some View {
        let presenting = status?.presenter == .presenting
        let start = presenting ? status?.presentationStartedAt ?? openedAt : openedAt
        let minutes = presenting ? status?.presentationMinutes : nil
        return HStack {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("結束簡報")

            Spacer()

            VStack(spacing: 2) {
                PresentationClock(start: start, minutes: minutes)
                HStack(spacing: 6) {
                    Circle()
                        .fill(connected ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(status?.frontApp.map { String(localized: "正在控制「\($0)」") } ?? model.pairing?.macName ?? "Mac")
                        .lineLimit(1)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                .accessibilityValue(connected ? Text("已連線") : Text("未連線"))
            }

            Spacer()

            Menu {
                Picker("演講長度", selection: Binding(
                    get: { minutes },
                    set: { value in Task { await model.setPresentationTimer(minutes: value) } }
                )) {
                    Text("不限時間").tag(Int?.none)
                    ForEach(Self.lengths, id: \.self) { Text("\($0) 分鐘").tag(Int?.some($0)) }
                }
                Divider()
                Button("重新計時", systemImage: "arrow.counterclockwise") {
                    Task { await model.setPresentationTimer(minutes: minutes, restart: true) }
                }
            } label: {
                Image(systemName: "timer").font(.headline).frame(width: 44, height: 44)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("演講長度")
            .disabled(!presenting)
        }
        .padding(.top, 4)
    }

    private func tile(title: LocalizedStringKey, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                Text(title).font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
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

    /// Mac 最前面不是簡報 App 時提醒：按鍵會送到那個 App。
    private func wrongApp(_ status: LinkStatus?) -> String? {
        guard status?.frontAppPresents == false, let app = status?.frontApp else { return nil }
        return String(localized: "Mac 正在使用「\(app)」，翻頁會送到這個 App。請先切回簡報。")
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

/// 有設演講長度就倒數（剩 5 分鐘變橘色、超時變紅色並顯示超過多久），沒設就顯示講了多久。
private struct PresentationClock: View {
    let start: Date
    let minutes: Int?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = context.date
            let remaining = minutes.map { start.addingTimeInterval(TimeInterval($0 * 60)).timeIntervalSince(now) }
            let (text, color): (String, Color) = switch remaining {
            case nil: (Self.format(now.timeIntervalSince(start)), .primary)
            case let r? where r < 0: ("+" + Self.format(-r), .red)
            case let r? where r <= 300: (Self.format(r), .orange)
            case let r?: (Self.format(r), .primary)
            }
            Text(text)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(color)
                .contentTransition(.numericText())
                .accessibilityLabel(minutes == nil ? Text("簡報時間") : Text("剩餘時間"))
                .accessibilityValue(text)
        }
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

/// 主要的翻頁區：整塊都能按，Mac 翻頁成功時箭頭動一下。
private struct NextPad: View {
    let done: Int

    var body: some View {
        VStack(spacing: 22) {
            ZStack {
                Circle()
                    .fill(LinearGradient.stageOrange)
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

/// 問答時跳到某一頁：輸入頁碼後 Mac 會打頁碼再按 Return。
private struct JumpSheet: View {
    let go: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var digits = ""

    var body: some View {
        VStack(spacing: 18) {
            Text("跳到第幾頁").font(.headline).foregroundStyle(.secondary)
            Text(digits.isEmpty ? "–" : digits)
                .font(.system(size: 56, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .frame(height: 64)
                .contentTransition(.numericText())
                .animation(.snappy, value: digits)

            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                ForEach([["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"]], id: \.self) { row in
                    GridRow { ForEach(row, id: \.self) { key($0) } }
                }
                GridRow {
                    keyButton(Image(systemName: "delete.backward"), label: Text("刪除")) { digits = String(digits.dropLast()) }
                    key("0")
                    Button {
                        guard let slide = Int(digits), slide > 0 else { return }
                        go(slide)
                        dismiss()
                    } label: {
                        Text("前往").font(.title3.weight(.bold)).frame(maxWidth: .infinity, minHeight: 60)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.roundedRectangle(radius: 18))
                    .tint(.orange)
                    .disabled(Int(digits) ?? 0 < 1)
                }
            }
        }
        .padding(24)
        .presentationDetents([.height(520)])
        .presentationBackground(Color(red: 0.08, green: 0.085, blue: 0.1))
        .preferredColorScheme(.dark)
    }

    private func key(_ digit: String) -> some View {
        keyButton(Text(verbatim: digit), label: Text(verbatim: digit)) {
            if digits.count < 4 { digits = digits == "0" ? digit : digits + digit }
        }
    }

    private func keyButton(_ content: some View, label: Text, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            content
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 60)
                .background(Card(radius: 18))
        }
        .buttonStyle(PadStyle())
        .accessibilityLabel(label)
    }
}

/// 深色半透明的卡片底。
struct Card: View {
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
struct PadStyle: ButtonStyle {
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

/// 近乎全黑，底部透一點橘色的光，呼應翻頁按鈕。付費畫面也用這個底。
struct StageBackground: View {
    var body: some View {
        ZStack {
            Color(red: 0.045, green: 0.05, blue: 0.06)
            RadialGradient(colors: [Color.orange.opacity(0.16), .clear], center: .bottom, startRadius: 0, endRadius: 520)
        }
        .ignoresSafeArea()
    }
}

// MARK: - 雷射筆與聚光燈

private enum Tool: Hashable, CaseIterable {
    case slides, laser, spotlight

    var title: LocalizedStringKey {
        switch self {
        case .slides: "翻頁"
        case .laser: "雷射筆"
        case .spotlight: "聚光燈"
        }
    }

    var symbol: String {
        switch self {
        case .slides: "hand.tap.fill"
        case .laser: "dot.circle.and.hand.point.up.left.fill"
        case .spotlight: "flashlight.on.fill"
        }
    }
}

/// 翻頁、雷射筆、聚光燈三選一；選到的是橘色。
private struct ToolPicker: View {
    @Binding var tool: Tool

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Tool.allCases, id: \.self) { item in
                let selected = item == tool
                Button { tool = item } label: {
                    Label(item.title, systemImage: item.symbol)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selected ? Color.black : Color.white.opacity(0.75))
                        .frame(maxWidth: .infinity, minHeight: 38)
                        .background {
                            if selected { Capsule().fill(LinearGradient.stageOrange) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(4)
        .background(Capsule().fill(.white.opacity(0.08)))
    }
}

/// 雷射筆的觸控區：形狀跟 Mac 上播放簡報的螢幕一樣，手指按在哪裡，紅點（或聚光燈）就出現在投影畫面上的同一個位置。
private struct PointerPad: View {
    let mode: PointerUpdate.Mode
    let aspect: Double
    /// x、y 是 0～1；began 是剛按下。
    let move: (Double, Double, Bool) -> Void
    let end: () -> Void
    @State private var touch: CGPoint?

    var body: some View {
        GeometryReader { geo in
            let size = fitted(in: geo.size)
            ZStack {
                Card(radius: 22)
                if let touch {
                    indicator.position(x: touch.x * size.width, y: touch.y * size.height)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: mode == .laser ? "dot.circle.and.hand.point.up.left.fill" : "flashlight.on.fill")
                            .font(.system(size: 34))
                            .foregroundStyle(.orange)
                        Text(mode == .laser ? "按住並移動手指，紅點會出現在投影畫面上的同一個位置"
                                            : "按住並移動手指，聚光燈會照亮投影畫面上的同一個位置")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let point = CGPoint(x: min(max(value.location.x / size.width, 0), 1),
                                        y: min(max(value.location.y / size.height, 0), 1))
                    let began = touch == nil
                    touch = point
                    move(point.x, point.y, began)
                }
                .onEnded { _ in
                    touch = nil
                    end()
                })
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityElement()
        .accessibilityLabel(mode == .laser ? Text("雷射筆觸控區") : Text("聚光燈觸控區"))
    }

    /// 在可用的空間裡放下跟螢幕一樣比例、最大的長方形。
    private func fitted(in space: CGSize) -> CGSize {
        let ratio = max(0.5, min(aspect, 3))
        let width = min(space.width, space.height * ratio)
        return CGSize(width: width, height: width / ratio)
    }

    @ViewBuilder private var indicator: some View {
        if mode == .laser {
            Circle()
                .fill(Color(red: 1, green: 0.16, blue: 0.1))
                .frame(width: 22, height: 22)
                .shadow(color: .red, radius: 10)
        } else {
            Circle()
                .strokeBorder(.white.opacity(0.8), lineWidth: 2)
                .frame(width: 76, height: 76)
        }
    }
}

// MARK: - 音量

/// Mac 的音量（簡報裡的影片太大聲或太小聲時）：拖拉調整，點喇叭靜音。
/// 聲音輸出不能從 Mac 調（例如接 HDMI 的電視）時只顯示說明。
private struct VolumeBar: View {
    let volume: MacVolume
    let set: (Double) -> Void
    let mute: (Bool) -> Void
    /// 手指拉到的位置與時間：最後一次拉動後 1.5 秒內顯示這個，不要被 Mac 回報的中間值拉回去；之後一律顯示 Mac 的音量。
    /// 不靠 Slider 的 onEditingChanged 判斷放開：那樣做時實測放開後音量條一直停在手指的位置，Mac 的音量變了也不動（2026-10-17）。
    @State private var dragged: (level: Double, at: Date)?

    var body: some View {
        let level = dragged.flatMap { Date().timeIntervalSince($0.at) < 1.5 ? $0.level : nil } ?? volume.level
        let silent = volume.muted || level == 0
        HStack(spacing: 12) {
            Button { mute(!volume.muted) } label: {
                Image(systemName: silent ? "speaker.slash.fill" : "speaker.wave.3.fill", variableValue: level)
                    .font(.system(size: 17, weight: .semibold))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.white.opacity(0.12)))
            }
            .buttonStyle(PadStyle())
            .accessibilityLabel(volume.muted ? Text("取消靜音") : Text("靜音"))

            if volume.adjustable {
                Slider(value: Binding(get: { level }, set: { value in
                    dragged = (value, Date())
                    set(value)
                }), in: 0...1)
                .tint(.orange)
                .opacity(volume.muted ? 0.45 : 1)
                .accessibilityLabel("Mac 的音量")

                Text(level, format: .percent.precision(.fractionLength(0)))
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(volume.muted ? .secondary : .primary)
                    .frame(minWidth: 44, alignment: .trailing)
            } else {
                Text("Mac 現在的聲音輸出不能從這裡調音量")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 14)
        .frame(minHeight: 60)
        .background(Card(radius: 20))
    }
}

/// 雷射筆模式下的上一頁、下一頁。
private struct TurnButton: View {
    let title: LocalizedStringKey
    let symbol: String
    var prominent = false

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.headline)
            .foregroundStyle(prominent ? Color.black : Color.white)
            .frame(maxWidth: .infinity, minHeight: 56)
            .background {
                if prominent {
                    RoundedRectangle(cornerRadius: 18, style: .continuous).fill(LinearGradient.stageOrange)
                } else {
                    Card(radius: 18)
                }
            }
    }
}

extension LinearGradient {
    /// 「下一頁」與 Presence Pro 的橘色。
    static let stageOrange = LinearGradient(colors: [Color(red: 1.0, green: 0.66, blue: 0.24), Color(red: 0.97, green: 0.42, blue: 0.08)],
                                            startPoint: .top, endPoint: .bottom)
}
