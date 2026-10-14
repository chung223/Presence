import CoreGraphics
// usage: winid <pid> — 印出這個程序在螢幕上的一般視窗：id、寬、高、標題
let pid = Int32(CommandLine.arguments[1])!
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
    let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
    print(w[kCGWindowNumber as String]!, Int(b["Width"] ?? 0), Int(b["Height"] ?? 0), w[kCGWindowName as String] ?? "")
}
