import AppIntents

/// 「捷徑」App 的動作。也能在終端機用 `shortcuts run` 執行，或接進其他自動化。
/// 刻意不提供 URL scheme：任何網頁都能觸發，等於讓網頁可以暫停你的自動鎖定。

enum PresenceIntentError: Error, CustomLocalizedStringResourceConvertible {
    case notRunning

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notRunning: "Presence 還沒有啟動"
        }
    }
}

@MainActor
private func runningModel() throws -> AppModel {
    guard let model = AppModel.current else { throw PresenceIntentError.notRunning }
    return model
}

struct LockNowIntent: AppIntent {
    static let title: LocalizedStringResource = "立即鎖定 Mac"
    static let description = IntentDescription("用 Presence 鎖定這台 Mac。之後要離開一段時間再回來，才會自動解鎖。")

    @MainActor
    func perform() async throws -> some IntentResult {
        try runningModel().lockNow()
        return .result()
    }
}

struct PauseIntent: AppIntent {
    static let title: LocalizedStringResource = "暫停 Presence"
    static let description = IntentDescription("在指定的時間內不自動鎖定，也不自動解鎖。")

    @Parameter(title: "分鐘", default: 60, inclusiveRange: (1, 1440))
    var minutes: Int

    static var parameterSummary: some ParameterSummary {
        Summary("暫停自動鎖定與解鎖 \(\.$minutes) 分鐘")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        try runningModel().pause(for: TimeInterval(minutes * 60))
        return .result()
    }
}

struct ResumeIntent: AppIntent {
    static let title: LocalizedStringResource = "恢復 Presence"
    static let description = IntentDescription("結束暫停，恢復自動鎖定與解鎖。")

    @MainActor
    func perform() async throws -> some IntentResult {
        try runningModel().resume()
        return .result()
    }
}

struct GetStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "取得 Presence 狀態"
    static let description = IntentDescription("回傳目前的狀態，例如「Weichung 在附近 · -52 dBm」。")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let line = try runningModel().statusLine
        return .result(value: line, dialog: "\(line)")
    }
}

struct PresenceShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LockNowIntent(),
            phrases: ["用 \(.applicationName) 鎖定", "\(.applicationName) 立即鎖定"],
            shortTitle: "立即鎖定",
            systemImageName: "lock.fill"
        )
        AppShortcut(
            intent: PauseIntent(),
            phrases: ["暫停 \(.applicationName)"],
            shortTitle: "暫停",
            systemImageName: "pause.circle"
        )
        AppShortcut(
            intent: ResumeIntent(),
            phrases: ["恢復 \(.applicationName)"],
            shortTitle: "恢復",
            systemImageName: "play.circle"
        )
        AppShortcut(
            intent: GetStatusIntent(),
            phrases: ["\(.applicationName) 狀態"],
            shortTitle: "狀態",
            systemImageName: "iphone.radiowaves.left.and.right"
        )
    }
}
