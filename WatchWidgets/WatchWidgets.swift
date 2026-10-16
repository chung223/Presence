import PresenceLink
import SwiftUI
import WidgetKit

/// 錶面複雜功能與 Smart Stack：顯示手錶 App 從 iPhone 拿到的最新狀態，點一下打開 App。
@main
struct WatchWidgets: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "com.chung.presence.remote.watch.status", provider: WatchStatusProvider()) { entry in
            WatchStatusView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Mac 狀態")
        .description("Presence 目前的狀態。")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

struct WatchStatusEntry: TimelineEntry {
    let date: Date
    let shared: SharedStatus?
}

struct WatchStatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchStatusEntry {
        WatchStatusEntry(date: Date(), shared: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchStatusEntry) -> Void) {
        completion(WatchStatusEntry(date: Date(), shared: SharedStatusStore.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchStatusEntry>) -> Void) {
        let now = Date()
        completion(Timeline(entries: [WatchStatusEntry(date: now, shared: SharedStatusStore.load())],
                            policy: .after(now.addingTimeInterval(30 * 60))))
    }
}

struct WatchStatusView: View {
    let entry: WatchStatusEntry
    @Environment(\.widgetFamily) private var family

    private var status: LinkStatus? { entry.shared?.status }
    private var presence: MacPresence { status?.presence ?? .waiting }
    private var symbol: String {
        guard entry.shared?.isPaired == true else { return "laptopcomputer.slash" }
        return status?.locked == true ? "lock.fill" : presence.symbol
    }
    private var text: String {
        guard entry.shared?.isPaired == true else { return String(localized: "尚未配對") }
        guard let status else { return String(localized: "還沒有狀態") }
        if status.locked { return String(localized: "Mac 已鎖定") }
        return status.displaySummary.isEmpty ? status.macName : status.displaySummary
    }

    var body: some View {
        switch family {
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 2) {
                Label(entry.shared?.macName ?? "Presence", systemImage: symbol)
                    .font(.headline)
                    .widgetAccentable()
                Text(text).lineLimit(2)
                if let updated = entry.shared?.updatedAt {
                    Text("\(Text(updated, style: .relative))前").font(.caption2).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .accessoryInline:
            Label(text, systemImage: symbol)
        case .accessoryCorner:
            Image(systemName: symbol)
                .font(.title3)
                .widgetLabel(text)
        default:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: symbol).font(.title3)
            }
            .widgetAccentable()
        }
    }
}
