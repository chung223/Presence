import AppIntents
import PresenceLink

/// App 裡真正執行動作的地方（小工具擴充裡的版本見 MacIntents.swift）。
@MainActor
func runMacCommand(_ command: LinkCommand) async throws -> LinkStatus {
    switch await RemoteModel.shared.perform(command) {
    case .success(let status):
        if let refusal = status.refusalMessage { throw RemoteIntentError(message: refusal) }
        return status
    case .failure(let failure): throw RemoteIntentError(message: failure.message)
    }
}

/// 鎖定畫面的「結束簡報」：同時結束即時動態。
@MainActor
func finishPresentation() async throws {
    await RemoteModel.shared.setPresentation(false)
    if let error = RemoteModel.shared.lastError { throw RemoteIntentError(message: error) }
}

struct RemoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: LockMacIntent(),
                    // Siri 的句子與動作說明不能出現「Mac」（App Store Connect 錯誤 90626），用「電腦」
                    phrases: ["用 \(.applicationName) 鎖定電腦", "\(.applicationName) 鎖定"],
                    shortTitle: "鎖定 Mac", systemImageName: "lock.fill")
        AppShortcut(intent: PauseMacIntent(), phrases: ["用 \(.applicationName) 暫停"],
                    shortTitle: "暫停", systemImageName: "pause.circle")
        AppShortcut(intent: ResumeMacIntent(), phrases: ["用 \(.applicationName) 恢復"],
                    shortTitle: "恢復", systemImageName: "play.circle")
        AppShortcut(intent: MacStatusIntent(), phrases: ["\(.applicationName) 狀態"],
                    shortTitle: "Mac 狀態", systemImageName: "laptopcomputer")
    }
}
