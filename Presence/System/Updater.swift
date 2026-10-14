import AppKit
import Sparkle

/// Sparkle 自動更新。更新清單是 GitHub Releases 最新一版附的 appcast.xml（Info.plist 的 SUFeedURL），
/// 每個版本都用 EdDSA 私鑰簽章，App 用 SUPublicEDKey 驗證，沒簽對就不會安裝。
///
/// 安裝更新時 Sparkle 會正常結束 Presence（launchd 不會重開），裝好再重新打開；
/// 打開的那一份會把控制權交回 launchd（見 AppDelegate.prepareLoginItem）。
@MainActor
final class Updater {
    static let shared = Updater()

    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastCheck: Date? { controller.updater.lastUpdateCheckDate }

    /// 選單列 App 平常不在前景，要先拉到前面，更新視窗才看得到。
    func checkForUpdates() {
        NSApp.activate()
        controller.checkForUpdates(nil)
    }

    static var versionDescription: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
}
