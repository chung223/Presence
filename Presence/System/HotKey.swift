import AppKit
import Carbon.HIToolbox

/// 全域快捷鍵。用 Carbon 的 RegisterEventHotKey，不需要輔助使用權限。
struct HotKey: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon 的修飾鍵旗標（cmdKey、optionKey、controlKey、shiftKey）。
    var modifiers: UInt32
    /// 顯示用，例如「⌃⌥⌘L」。
    var display: String

    /// 從按鍵事件建立；至少要有 ⌘、⌥ 或 ⌃，否則會跟一般打字衝突。
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        var carbon: UInt32 = 0
        var symbols = ""
        if flags.contains(.control) { carbon |= UInt32(controlKey); symbols += "⌃" }
        if flags.contains(.option) { carbon |= UInt32(optionKey); symbols += "⌥" }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey); symbols += "⇧" }
        if flags.contains(.command) { carbon |= UInt32(cmdKey); symbols += "⌘" }
        keyCode = UInt32(event.keyCode)
        modifiers = carbon
        display = symbols + Self.name(for: Int(event.keyCode), characters: event.charactersIgnoringModifiers)
    }

    private static func name(for keyCode: Int, characters: String?) -> String {
        let special: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
            kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]
        if let name = special[keyCode] { return name }
        return characters?.uppercased() ?? "?"
    }
}

final class HotKeyCenter {
    static let shared = HotKeyCenter()

    var onPress: (() -> Void)?
    private var registered: EventHotKeyRef?
    private var handlerInstalled = false

    /// 註冊（或換掉）快捷鍵；nil 表示取消。回傳 false 表示被其他 App 佔用了。
    @discardableResult
    func register(_ key: HotKey?) -> Bool {
        if let registered {
            UnregisterEventHotKey(registered)
            self.registered = nil
        }
        guard let key else { return true }
        installHandler()
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x5052_5343), id: 1) // 'PRSC'
        guard RegisterEventHotKey(key.keyCode, key.modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr else {
            return false
        }
        registered = ref
        return true
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), hotKeyPressed, 1, &spec, nil, nil)
        handlerInstalled = true
    }
}

/// Carbon 在主執行緒呼叫這個 C 函式。
private nonisolated func hotKeyPressed(_: EventHandlerCallRef?, _: EventRef?, _: UnsafeMutableRawPointer?) -> OSStatus {
    MainActor.assumeIsolated { HotKeyCenter.shared.onPress?() }
    return noErr
}
