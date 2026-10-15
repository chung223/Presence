// 產生 App 圖示：
//   swift scripts/make-icon.swift Presence/Assets.xcassets/AppIcon.appiconset          （Mac）
//   swift scripts/make-icon.swift Remote/Assets.xcassets/AppIcon.appiconset ios        （iPhone）
//   swift scripts/make-icon.swift Watch/Assets.xcassets/AppIcon.appiconset watchos     （手錶）
// 三個平台用同一組漸層。Mac 是「手機發出訊號」；iPhone 與手錶是遙控 App（鎖定、暫停、簡報），
// 畫成「手機發訊號給筆電」，不只代表上鎖。
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let platform = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "mac"
let isMac = platform == "mac"
let canvas: CGFloat = 1024
// macOS 圖示範本：824×824 的圓角方形置中，四周留給陰影。iOS 與手錶要滿版、不透明，圓角由系統裁。
let inset: CGFloat = isMac ? 100 : 0
let radius: CGFloat = isMac ? 185 : 0
// 手錶圖示會被裁成圓形，內容縮小一點
let remoteScale: CGFloat = platform == "watchos" ? 0.84 : 1

/// 單色符號染成白色。用 palette 上色會把手機、筆電的螢幕那一層也填滿。
func symbol(_ name: String, _ size: CGFloat, weight: NSFont.Weight) -> NSImage {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
    let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)!.withSymbolConfiguration(config)!
    return NSImage(size: base.size, flipped: false) { rect in
        base.draw(in: rect)
        NSColor.white.set()
        rect.fill(using: .sourceAtop)
        return true
    }
}

func draw(_ image: NSImage, center: CGPoint) {
    let s = image.size
    image.draw(in: CGRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height))
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: isMac ? 4 : 3, hasAlpha: isMac, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: isMac ? 0 : 32)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let scale = CGFloat(size) / canvas
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: scale, y: scale)

    let body = CGRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
    let path = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

    if isMac {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        NSColor.black.setFill()
        path.fill()
        ctx.restoreGState()
    }

    path.addClip()
    let gradient = NSGradient(colors: [
        NSColor(red: 0.20, green: 0.78, blue: 0.70, alpha: 1),
        NSColor(red: 0.10, green: 0.42, blue: 0.85, alpha: 1),
    ])!
    gradient.draw(in: body, angle: -60)

    if isMac {
        let config = NSImage.SymbolConfiguration(pointSize: 360, weight: .medium).applying(.init(paletteColors: [.white]))
        if let mark = NSImage(systemSymbolName: "iphone.radiowaves.left.and.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            draw(mark, center: CGPoint(x: canvas / 2, y: canvas / 2))
        }
    } else {
        // [手機] ))) [筆電]，以畫布中心縮放
        func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: 512 + (x - 512) * remoteScale, y: 512 + (y - 512) * remoteScale)
        }
        draw(symbol("iphone.gen3", 300 * remoteScale, weight: .bold), center: at(240, 512))
        draw(symbol("wave.3.right", 150 * remoteScale, weight: .bold), center: at(410, 528))
        draw(symbol("laptopcomputer", 300 * remoteScale, weight: .bold), center: at(675, 512))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var images: [[String: String]] = []
if isMac {
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let pixels = points * scale
            let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
            try render(size: pixels).write(to: output.appendingPathComponent(name))
            images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
        }
    }
} else {
    // 新版 Xcode 只要一張 1024，其他尺寸自動產生
    try render(size: 1024).write(to: output.appendingPathComponent("icon-1024.png"))
    images.append(["idiom": "universal", "platform": platform, "size": "1024x1024", "filename": "icon-1024.png"])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appendingPathComponent("Contents.json"))
print("OK")
