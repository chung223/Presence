import AppIntents
import SwiftUI
import UserNotifications

@main
struct PresenceRemoteApp: App {
    var body: some Scene {
        WindowGroup {
            RemoteView(link: .shared)
                .task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        }
    }
}

/// 可行性驗證畫面：連線狀態、送指令、紀錄。
struct RemoteView: View {
    let link: LinkClient

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("連線", value: link.state.rawValue)
                    LabeledContent("Mac 最後的訊息", value: link.lastStatus)
                    Button("連線到 Mac") { link.connect() }
                    Button("送出 ping") { link.send("ping") }
                    Button("送出 lock（測試，不會真的鎖）") { link.send("lock") }
                }
                Section("紀錄") {
                    ForEach(link.lines.reversed()) { line in
                        HStack(alignment: .firstTextBaseline) {
                            Text(line.time).font(.caption.monospaced()).foregroundStyle(.secondary)
                            Text(line.text).font(.callout)
                        }
                    }
                }
            }
            .navigationTitle("Presence Remote")
        }
    }
}

/// 測背景觸發：從「捷徑」或 Spotlight 執行，不打開 App。
struct PingMacIntent: AppIntent {
    static let title: LocalizedStringResource = "Ping Mac"
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = await LinkClient.shared.sendAndWait("ping from intent")
        return .result(dialog: "\(result)")
    }
}

struct RemoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PingMacIntent(), phrases: ["Ping Mac with \(.applicationName)"],
                    shortTitle: "Ping Mac", systemImageName: "antenna.radiowaves.left.and.right")
    }
}
