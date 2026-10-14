import AppIntents
import PresenceLink

/// App 裡真正執行動作的地方（小工具擴充裡的版本見 MacIntents.swift）。
@MainActor
func runMacCommand(_ command: LinkCommand) async throws -> LinkStatus {
    switch await RemoteModel.shared.perform(command) {
    case .success(let status): return status
    case .failure(let failure): throw RemoteIntentError(message: failure.message)
    }
}

struct RemoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: LockMacIntent(),
                    phrases: ["用 \(.applicationName) 鎖定 Mac", "\(.applicationName) 鎖定"],
                    shortTitle: "鎖定 Mac", systemImageName: "lock.fill")
        AppShortcut(intent: PauseMacIntent(), phrases: ["用 \(.applicationName) 暫停"],
                    shortTitle: "暫停", systemImageName: "pause.circle")
        AppShortcut(intent: ResumeMacIntent(), phrases: ["用 \(.applicationName) 恢復"],
                    shortTitle: "恢復", systemImageName: "play.circle")
        AppShortcut(intent: MacStatusIntent(), phrases: ["\(.applicationName) Mac 狀態"],
                    shortTitle: "Mac 狀態", systemImageName: "laptopcomputer")
    }
}
