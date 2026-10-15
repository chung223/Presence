import AppKit
import IOKit.pwr_mgt

/// 偵測有沒有簡報正在播放：Keynote、PowerPoint、Folium 播放時會要求螢幕保持亮著。
///
/// 2026-10-15 實測：Keynote 播放時有「PreventUserIdleDisplaySleep named: Displaying Keynote slideshow」，
/// 編輯時沒有。預覽程式的幻燈片秀沒有提出要求，只有全螢幕視窗，和一般全螢幕分不出來，所以不偵測。
/// 也不看瀏覽器：看 YouTube 會提出同樣的要求，算進來的話，全螢幕看影片時離開座位也不會鎖。
enum PresentationDetector {
    static let apps: Set<String> = PresenterKeys.keynote.union([PresenterKeys.powerPoint, "com.chung.folium"])

    private static let displayAssertions: Set<String> = ["PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion"]

    /// 正在播放簡報的 App 名稱；沒有是 nil。
    static func presentingApp() -> String? {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let byProcess = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return nil }
        for (pid, assertions) in byProcess {
            let keepsDisplayOn = assertions.contains {
                ($0[kIOPMAssertionTypeKey as String] as? String).map(displayAssertions.contains) == true
            }
            guard keepsDisplayOn, let app = NSRunningApplication(processIdentifier: pid.int32Value),
                  let id = app.bundleIdentifier, apps.contains(id) else { continue }
            return app.localizedName ?? id
        }
        return nil
    }
}
