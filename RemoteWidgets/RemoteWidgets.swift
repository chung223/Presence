import AppIntents
import PresenceLink
import SwiftUI
import WidgetKit

@main
struct RemoteWidgets: WidgetBundle {
    var body: some Widget {
        MacStatusWidget()
        LockMacControl()
        PausePresenceControl()
        PresenterLiveActivity()
    }
}

// MARK: - 狀態小工具

struct MacStatusEntry: TimelineEntry {
    let date: Date
    let shared: SharedStatus?
}

struct MacStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> MacStatusEntry {
        MacStatusEntry(date: Date(), shared: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (MacStatusEntry) -> Void) {
        completion(MacStatusEntry(date: Date(), shared: context.isPreview ? .preview : SharedStatusStore.load()))
    }

    /// App 在狀態改變時會請系統重畫；半小時後再畫一次，好標出「這是舊的狀態」。
    func getTimeline(in context: Context, completion: @escaping (Timeline<MacStatusEntry>) -> Void) {
        let now = Date()
        let entry = MacStatusEntry(date: now, shared: SharedStatusStore.load())
        completion(Timeline(entries: [entry], policy: .after(now.addingTimeInterval(30 * 60))))
    }
}

struct MacStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.chung.presence.remote.status", provider: MacStatusProvider()) { entry in
            MacStatusView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Mac 狀態")
        .description("看 Presence 目前的狀態，一鍵鎖定 Mac。")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

struct MacStatusView: View {
    let entry: MacStatusEntry
    @Environment(\.widgetFamily) private var family

    private var shared: SharedStatus? { entry.shared }
    private var status: LinkStatus? { shared?.status }
    private var presence: MacPresence { status?.presence ?? .waiting }
    private var stale: Bool { shared?.isStale(at: entry.date) ?? true }

    var body: some View {
        if shared?.isPaired != true {
            notPaired
        } else {
            switch family {
            case .accessoryCircular: circular
            case .accessoryRectangular: rectangular
            case .accessoryInline: inline
            case .systemMedium: medium
            default: small
            }
        }
    }

    private var notPaired: some View {
        VStack(spacing: 4) {
            Image(systemName: "laptopcomputer.slash")
            if family != .accessoryCircular {
                Text("先在 App 配對 Mac").font(.caption)
            }
        }
    }

    private var summary: String {
        guard let status else { return String(localized: "還沒有狀態") }
        return status.summary.isEmpty ? status.macName : status.summary
    }

    private var symbol: String { status?.locked == true ? "lock.fill" : presence.symbol }

    // MARK: 主畫面

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .foregroundStyle(stale ? Color.secondary : presence.tint)
            Text(shared?.macName ?? "Mac").font(.headline).lineLimit(1)
        }
    }

    private var footnote: some View {
        Group {
            if shared?.connected == false {
                Text("未連線 · \(Text(shared?.updatedAt ?? entry.date, style: .relative))前")
            } else if status?.locked == true {
                Text("已鎖定")
            } else if let until = status?.pausedUntil, until > entry.date {
                Text("暫停到 \(until.formatted(date: .omitted, time: .shortened))")
            } else {
                Text("\(Text(shared?.updatedAt ?? entry.date, style: .relative))前更新")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            Text(summary).font(.caption).lineLimit(2)
            Spacer(minLength: 0)
            footnote
            Button(intent: LockMacIntent()) {
                Label("鎖定", systemImage: "lock.fill").frame(maxWidth: .infinity)
            }
            .tint(.orange)
        }
    }

    private var medium: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                header
                Text(summary).font(.callout).lineLimit(2)
                Spacer(minLength: 0)
                footnote
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(spacing: 8) {
                Button(intent: LockMacIntent()) {
                    Label("鎖定", systemImage: "lock.fill").frame(maxWidth: .infinity)
                }
                .tint(.orange)
                if shared?.isPaused(at: entry.date) == true {
                    Button(intent: ResumeMacIntent()) {
                        Label("恢復", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                } else {
                    Button(intent: PauseMacIntent(minutes: 60)) {
                        Label("暫停 1 小時", systemImage: "pause.fill").frame(maxWidth: .infinity)
                    }
                }
            }
            .frame(width: 130)
        }
    }

    // MARK: 鎖定畫面

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            Image(systemName: symbol).font(.title3)
        }
        .widgetAccentable()
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(shared?.macName ?? "Mac", systemImage: symbol).font(.headline).widgetAccentable()
            Text(summary).lineLimit(1)
            footnote
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var inline: some View {
        Label(status?.locked == true ? String(localized: "Mac 已鎖定") : summary, systemImage: symbol)
    }
}

extension SharedStatus {
    static let preview = SharedStatus(
        macName: "MacBook Pro",
        status: LinkStatus(macName: "MacBook Pro", presence: .near, summary: "iPhone 在附近 · -52 dBm", locked: false),
        connected: true
    )
}

// MARK: - 控制中心

/// 控制中心、鎖定畫面和動作按鈕都可以放。
struct LockMacControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.chung.presence.remote.lock") {
            ControlWidgetButton(action: LockMacIntent()) {
                Label("鎖定 Mac", systemImage: "lock.laptopcomputer")
            }
        }
        .displayName("鎖定 Mac")
        .description("用 Presence 立即鎖定配對的 Mac。")
    }
}

struct PausePresenceControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "com.chung.presence.remote.pause", provider: PausedValueProvider()) { paused in
            ControlWidgetToggle("暫停 Presence", isOn: paused, action: SetPresencePausedIntent()) { isOn in
                Label(isOn ? "暫停 1 小時" : "自動鎖定中", systemImage: isOn ? "pause.circle.fill" : "lock.shield")
            }
        }
        .displayName("暫停 Presence")
        .description("打開後一小時內，Mac 不會自動鎖定也不會自動解鎖。")
    }
}

struct PausedValueProvider: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        SharedStatusStore.load()?.isPaused() ?? false
    }
}
