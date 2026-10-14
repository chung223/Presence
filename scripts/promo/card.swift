import AppKit

// 宣傳影片用的畫面（1920×1080 PNG）。
//   card bg <out>                                  淺色漸層背景
//   card title <out> <icon> <title> <subtitle>     片頭
//   card end <out> <icon> <line1> <line2> <line3>  片尾
//   card caption <out> <text>                      上方字幕（透明背景，1920×170）
//   card lock <out> <text>                         鎖定畫面（深色半透明＋鎖頭）
//   card shadow <out> <x> <y> <w> <h>              視窗陰影
//   card frame <out> <w> <h> <radius>              圓角遮罩（白色＝保留）
//   card lights <out>                              補回錄影時被換掉的紅黃綠按鈕（152×58）

let args = CommandLine.arguments
let mode = args[1], out = args[2]
let W: CGFloat = 1920, H: CGFloat = 1080

func render(width: CGFloat = W, height: CGFloat = H, _ draw: (CGRect) -> Void) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width), pixelsHigh: Int(height), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(CGRect(x: 0, y: 0, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
}

func background(_ rect: CGRect) {
    NSGradient(colors: [NSColor(red: 0.965, green: 0.973, blue: 0.992, alpha: 1),
                        NSColor(red: 0.886, green: 0.918, blue: 0.976, alpha: 1)])!.draw(in: rect, angle: -90)
    // 右上角淡淡的綠光，呼應「在附近」的綠色
    let glow = NSGradient(colors: [NSColor(red: 0.35, green: 0.80, blue: 0.55, alpha: 0.18), .clear])!
    glow.draw(fromCenter: CGPoint(x: rect.maxX * 0.85, y: rect.maxY * 0.9), radius: 0,
              toCenter: CGPoint(x: rect.maxX * 0.85, y: rect.maxY * 0.9), radius: 900, options: [])
}

func text(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, in rect: CGRect, align: NSTextAlignment = .center) {
    let para = NSMutableParagraphStyle()
    para.alignment = align
    para.lineBreakMode = .byWordWrapping
    para.lineSpacing = size * 0.15
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                .foregroundColor: color, .paragraphStyle: para]
    let str = NSAttributedString(string: s, attributes: attrs)
    let bounds = str.boundingRect(with: rect.size, options: [.usesLineFragmentOrigin, .usesFontLeading])
    str.draw(with: CGRect(x: rect.minX, y: rect.midY - bounds.height / 2, width: rect.width, height: bounds.height),
             options: [.usesLineFragmentOrigin, .usesFontLeading])
}

func icon(_ path: String, center: CGPoint, size: CGFloat) {
    guard let image = NSImage(contentsOfFile: path) else { return }
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.25)
    shadow.shadowBlurRadius = 30
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    image.draw(in: CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
}

let ink = NSColor(red: 0.08, green: 0.10, blue: 0.14, alpha: 1)
let secondary = NSColor(red: 0.33, green: 0.37, blue: 0.45, alpha: 1)

switch mode {
case "bg":
    render { background($0) }
case "title":
    render { r in
        background(r)
        icon(args[3], center: CGPoint(x: r.midX, y: 640), size: 300)
        text(args[4], size: 110, weight: .bold, color: ink, in: CGRect(x: 0, y: 330, width: r.width, height: 160))
        text(args[5], size: 50, weight: .medium, color: secondary, in: CGRect(x: 160, y: 200, width: r.width - 320, height: 120))
    }
case "end":
    render { r in
        background(r)
        icon(args[3], center: CGPoint(x: r.midX, y: 700), size: 240)
        text(args[4], size: 76, weight: .bold, color: ink, in: CGRect(x: 0, y: 440, width: r.width, height: 120))
        text(args[5], size: 46, weight: .semibold, color: NSColor(red: 0.13, green: 0.40, blue: 0.85, alpha: 1),
             in: CGRect(x: 0, y: 330, width: r.width, height: 80))
        text(args[6], size: 38, weight: .regular, color: secondary, in: CGRect(x: 0, y: 240, width: r.width, height: 70))
    }
case "caption":
    render(height: 170) { r in
        text(args[3], size: 58, weight: .bold, color: ink, in: r.insetBy(dx: 80, dy: 0))
    }
case "lock":
    render { r in
        NSColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 0.82).setFill()
        r.fill()
        let config = NSImage.SymbolConfiguration(pointSize: 150, weight: .semibold)
        if let lock = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            let tinted = NSImage(size: lock.size, flipped: false) { rect in
                lock.draw(in: rect)
                NSColor.white.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: CGRect(x: r.midX - lock.size.width / 2, y: 560, width: lock.size.width, height: lock.size.height))
        }
        text(args[3], size: 64, weight: .semibold, color: .white, in: CGRect(x: 0, y: 380, width: r.width, height: 120))
    }
case "shadow":
    let x = CGFloat(Double(args[3])!), y = CGFloat(Double(args[4])!), w = CGFloat(Double(args[5])!), h = CGFloat(Double(args[6])!)
    render { r in
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
        shadow.shadowBlurRadius = 60
        shadow.shadowOffset = NSSize(width: 0, height: -20)
        NSGraphicsContext.saveGraphicsState()
        shadow.set()
        NSColor.white.setFill()
        // ffmpeg 的 y 從上往下，AppKit 從下往上
        NSBezierPath(roundedRect: CGRect(x: x, y: r.height - y - h, width: w, height: h), xRadius: 24, yRadius: 24).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
case "frame":
    let w = CGFloat(Double(args[3])!), h = CGFloat(Double(args[4])!), radius = CGFloat(Double(args[5])!)
    render(width: w, height: h) { r in
        NSColor.black.setFill()
        r.fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
    }
case "lights":
    // 錄影時 macOS 會把紅黃綠按鈕換成「正在錄製」標記，補畫回去。蓋住錄影座標 (24,24) 起 152×58 的區域
    render(width: 152, height: 58) { r in
        NSColor(white: 0.98, alpha: 1).setFill()
        r.fill()
        let colors: [(NSColor, NSColor)] = [
            (NSColor(red: 0.925, green: 0.404, blue: 0.396, alpha: 1), NSColor(red: 0.906, green: 0.224, blue: 0.208, alpha: 1)),
            (NSColor(red: 0.949, green: 0.792, blue: 0.267, alpha: 1), NSColor(red: 0.933, green: 0.729, blue: 0.043, alpha: 1)),
            (NSColor(red: 0.396, green: 0.769, blue: 0.400, alpha: 1), NSColor(red: 0.208, green: 0.698, blue: 0.216, alpha: 1)),
        ]
        for (i, (fill, edge)) in colors.enumerated() {
            let cx = 27.5 + Double(i) * 46, cy = r.height - 27.5
            let circle = NSBezierPath(ovalIn: CGRect(x: cx - 13.5, y: cy - 13.5, width: 27, height: 27))
            fill.setFill(); circle.fill()
            edge.setStroke(); circle.lineWidth = 1; circle.stroke()
        }
    }
default:
    fatalError("unknown mode \(mode)")
}
