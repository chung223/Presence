import AppKit
import PresenceLink

/// 簡報遙控：把 iPhone、手錶送來的翻頁指令變成按鍵，送給目前在最前面的 App。
///
/// Keynote、PowerPoint、瀏覽器裡的 Google 簡報、PDF 都用方向鍵翻頁，所以不必個別支援。
/// 只有固定幾個鍵（見 `PresenterAction`），不接受任意按鍵；螢幕鎖著時呼叫端不會送（免得打進登入畫面）。
/// 送按鍵要有輔助使用權限，和自動解鎖輸入密碼相同。
enum PresenterKeys {
    private struct Key {
        let code: CGKeyCode
        var flags: CGEventFlags = []
    }

    /// 開始播放的快捷鍵依 App 不同；其他 App（例如瀏覽器裡的 Google 簡報）用 ⌘↩。
    private static func startKey(for bundleID: String?) -> Key {
        switch bundleID {
        case "com.apple.iWork.Keynote": Key(code: 35, flags: [.maskCommand, .maskAlternate])   // ⌥⌘P 播放幻燈片秀
        case "com.microsoft.Powerpoint": Key(code: 36, flags: [.maskCommand, .maskShift])     // ⇧⌘↩ 從頭播放
        default: Key(code: 36, flags: .maskCommand)                                            // ⌘↩
        }
    }

    private static func key(for action: PresenterAction, frontmost: String?) -> Key {
        switch action {
        case .next: Key(code: 124)      // →
        case .previous: Key(code: 123)  // ←
        case .start: startKey(for: frontmost)
        case .end: Key(code: 53)        // Esc
        case .blank: Key(code: 11)      // B
        }
    }

    static func press(_ action: PresenterAction) {
        let key = key(for: action, frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: down) else { continue }
            event.flags = key.flags
            event.post(tap: .cghidEventTap)
        }
    }
}
