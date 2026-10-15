import AppKit
import Carbon
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

    static let keynote: Set<String> = ["com.apple.iWork.Keynote", "com.apple.Keynote"]  // 後者是 Creator Studio 版
    static let powerPoint = "com.microsoft.Powerpoint"

    /// 能播放簡報的 App：簡報軟體、PDF 閱讀器（含 Folium），以及能播放 Google 簡報的瀏覽器。
    /// 最前面不是這些時，手機會提醒「按鍵會送到別的 App」。
    static let presentationApps: Set<String> = keynote.union([
        powerPoint, "com.apple.Preview", "com.adobe.Acrobat.Pro", "com.adobe.Reader", "com.chung.folium",
        "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser", "com.microsoft.edgemac",
        "org.mozilla.firefox", "com.brave.Browser", "com.operasoftware.Opera", "com.vivaldi.Vivaldi", "ai.perplexity.comet",
    ])

    /// 數字鍵 0～9 的虛擬鍵碼。
    private static let digitCodes: [CGKeyCode] = [29, 18, 19, 20, 21, 23, 22, 26, 28, 25]

    /// 開始播放的快捷鍵依 App 不同；其他 App（例如瀏覽器裡的 Google 簡報）用 ⌘↩。
    private static func startKey(for bundleID: String?) -> Key {
        if let bundleID, keynote.contains(bundleID) { return Key(code: 35, flags: [.maskCommand, .maskAlternate]) }  // ⌥⌘P 播放幻燈片秀
        if bundleID == powerPoint { return Key(code: 36, flags: [.maskCommand, .maskShift]) }                        // ⇧⌘↩ 從頭播放
        return Key(code: 36, flags: .maskCommand)                                                                    // ⌘↩
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
        press(key(for: action, frontmost: NSWorkspace.shared.frontmostApplication?.bundleIdentifier))
    }

    /// 跳到第幾頁：輸入頁碼再按 Return。Keynote、PowerPoint、Google 簡報播放時都這樣跳頁。
    ///
    /// 2026-10-15 實測 Keynote：按下第一個數字會打開投影片導覽和頁碼欄，但用中文輸入法（Rime）時，
    /// Return 被輸入法吃掉，導覽停在那裡不跳頁；換成英文鍵盤就正常。所以跳頁時先換成英文鍵盤，送完再換回來。
    /// 導覽打開有動畫，也稍等一下再打下一個字和 Return。
    static func goTo(slide: Int) async {
        let previous = TISCopyCurrentKeyboardInputSource().takeRetainedValue()
        TISSelectInputSource(TISCopyCurrentASCIICapableKeyboardInputSource().takeRetainedValue())
        let digits = String(max(1, slide)).compactMap(\.wholeNumberValue)
        for (index, digit) in digits.enumerated() {
            press(Key(code: digitCodes[digit]))
            try? await Task.sleep(for: .milliseconds(index == 0 ? 400 : 80))
        }
        try? await Task.sleep(for: .milliseconds(150))
        press(Key(code: 36))
        try? await Task.sleep(for: .milliseconds(250))
        TISSelectInputSource(previous)
    }

    private static func press(_ key: Key) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key.code, keyDown: down) else { continue }
            event.flags = key.flags
            event.post(tap: .cghidEventTap)
        }
    }
}
