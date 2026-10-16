import AppIntents
import PresenceLink

/// Siri、「捷徑」、動作按鈕、控制中心和小工具共用的動作。App 與小工具擴充都會編譯這個檔案。
///
/// 都是 `LiveActivityIntent`：從小工具或控制中心按下時，系統在 App 的程序裡執行（必要時在背景啟動 App），
/// 因為只有 App 連著 Mac 的藍牙；小工具擴充不能自己連。
/// 鎖定很安全，鎖著的手機也能執行；暫停與恢復會改變保護，要先解鎖手機。
/// 說明文字與 Siri 的句子不能出現「Mac」，否則 App Store Connect 會退回（錯誤 90626）。

struct RemoteIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

#if WIDGET_EXTENSION
/// 小工具擴充裡不會真的執行（見上面的說明），只是讓它編譯得過。
@MainActor
func runMacCommand(_ command: LinkCommand) async throws -> LinkStatus {
    throw RemoteIntentError(message: String(localized: "請打開 Presence Remote 再試一次"))
}
#endif

struct LockMacIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "鎖定 Mac"
    static let description = IntentDescription("用 Presence 立即鎖定配對的電腦。")

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let status = try await runMacCommand(.lock)
        return .result(dialog: "\(status.macName) 已鎖定")
    }
}

struct PauseMacIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "暫停 Presence"
    static let description = IntentDescription("在指定的時間內，電腦不會自動鎖定也不會自動解鎖。")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "分鐘", default: 60, inclusiveRange: (1, 1440))
    var minutes: Int

    init() {}

    init(minutes: Int) {
        self.minutes = minutes
    }

    static var parameterSummary: some ParameterSummary {
        Summary("暫停 Presence \(\.$minutes) 分鐘")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let status = try await runMacCommand(.pause(minutes: minutes))
        return .result(dialog: "\(status.macName) 已暫停自動鎖定與解鎖")
    }
}

struct ResumeMacIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "恢復 Presence"
    static let description = IntentDescription("結束暫停，恢復自動鎖定與解鎖。")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let status = try await runMacCommand(.resume)
        return .result(dialog: "\(status.macName) 已恢復自動鎖定與解鎖")
    }
}

/// 控制中心的「暫停 Presence」開關：打開是暫停 1 小時，關掉是恢復。
struct SetPresencePausedIntent: SetValueIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "暫停或恢復 Presence"
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let isDiscoverable = false

    @Parameter(title: "暫停")
    var value: Bool

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await runMacCommand(value ? .pause(minutes: 60) : .resume)
        return .result()
    }
}

struct MacStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "取得 Mac 狀態"
    static let description = IntentDescription("回傳 Presence 目前的狀態，例如「Weichung 在附近」。")

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let status = try await runMacCommand(.status)
        let text = status.locked ? String(localized: "\(status.displaySummary)（已鎖定）") : status.displaySummary
        return .result(value: text, dialog: "\(text)")
    }
}
