import AppIntents
import PresenceLink

/// Siri、「捷徑」、動作按鈕都會用到的動作。可能在 App 沒開的時候於背景執行。
/// 鎖定很安全，鎖著的手機也能執行；暫停與恢復會改變保護，要先解鎖手機。

struct RemoteIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

@MainActor
private func run(_ command: LinkCommand) async throws -> LinkStatus {
    switch await RemoteModel.shared.perform(command) {
    case .success(let status): return status
    case .failure(let failure): throw RemoteIntentError(message: failure.message)
    }
}

struct LockMacIntent: AppIntent {
    static let title: LocalizedStringResource = "鎖定 Mac"
    static let description = IntentDescription("用 Presence 立即鎖定配對的 Mac。")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let status = try await run(.lock)
        return .result(dialog: "\(status.macName) 已鎖定")
    }
}

struct PauseMacIntent: AppIntent {
    static let title: LocalizedStringResource = "暫停 Presence"
    static let description = IntentDescription("在指定的時間內，Mac 不會自動鎖定也不會自動解鎖。")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "分鐘", default: 60, inclusiveRange: (1, 1440))
    var minutes: Int

    static var parameterSummary: some ParameterSummary {
        Summary("暫停 Presence \(\.$minutes) 分鐘")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let status = try await run(.pause(minutes: minutes))
        return .result(dialog: "\(status.macName) 已暫停自動鎖定與解鎖")
    }
}

struct ResumeMacIntent: AppIntent {
    static let title: LocalizedStringResource = "恢復 Presence"
    static let description = IntentDescription("結束暫停，恢復自動鎖定與解鎖。")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let status = try await run(.resume)
        return .result(dialog: "\(status.macName) 已恢復自動鎖定與解鎖")
    }
}

struct MacStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "取得 Mac 狀態"
    static let description = IntentDescription("回傳 Presence 目前的狀態，例如「Weichung 在附近」。")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let status = try await run(.status)
        let text = status.locked ? "\(status.summary)（已鎖定）" : status.summary
        return .result(value: text, dialog: "\(text)")
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
