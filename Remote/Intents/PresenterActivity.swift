import ActivityKit
import AppIntents
import Foundation
import PresenceLink

/// 簡報中的即時動態：鎖定畫面與動態島顯示翻頁按鈕和計時，手機鎖著也能翻頁。App 與小工具擴充都會編譯這個檔案。
/// 系統在背景執行緒讀寫，不能綁在主執行緒（專案預設是 MainActor）。
nonisolated struct PresenterAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable {
        var startedAt: Date
    }

    var macName: String
}

#if WIDGET_EXTENSION
/// 小工具擴充裡不會真的執行（見 MacIntents.swift），只是讓它編譯得過。
@MainActor
func finishPresentation() async throws {
    throw RemoteIntentError(message: String(localized: "請打開 Presence Remote 再試一次"))
}
#endif

// 說明文字不能出現「Mac」（App Store Connect 錯誤 90626），用「電腦」。

struct NextSlideIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "下一頁"
    static let description = IntentDescription("讓電腦上的簡報翻到下一頁。")

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await runMacCommand(.presenter(.next))
        return .result()
    }
}

struct PreviousSlideIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "上一頁"
    static let description = IntentDescription("讓電腦上的簡報回到上一頁。")

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await runMacCommand(.presenter(.previous))
        return .result()
    }
}

struct EndPresentationIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "結束簡報"
    static let description = IntentDescription("結束簡報遙控，電腦恢復自動鎖定與解鎖。")
    static let isDiscoverable = false

    @MainActor
    func perform() async throws -> some IntentResult {
        try await finishPresentation()
        return .result()
    }
}
