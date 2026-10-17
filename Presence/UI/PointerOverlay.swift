import AppKit
import PresenceCore
import PresenceLink
import QuartzCore

/// 雷射筆、聚光燈與螢光筆：在播放簡報的那個螢幕最上層疊一個透明、點不到的視窗，畫紅點、聚光燈或線。
///
/// 只畫、不點擊，不會改動任何 App，所以 Keynote、PowerPoint、Google 簡報、PDF 都一樣能用。
/// 手機每秒送約 30 筆位置，中間用很短的動畫補平；超過 2.5 秒沒有新位置就自動收起（例如手機斷線）。
/// 螢光筆的線在手指放開後留幾秒再淡掉，翻頁時馬上清掉。
@MainActor
final class PointerOverlay {
    static let shared = PointerOverlay()

    private var window: NSPanel?
    private var root = CALayer()
    /// 跟著手指的紅點與聚光燈，手指放開就淡出。
    private let live = CALayer()
    private let dot = CALayer()
    private let dotCore = CALayer()
    /// 聚光燈：一整片比螢幕大很多的暗色圖層，中間挖一個邊緣柔和的洞，整片跟著手指移動。
    /// 第一版用「洞＋四周四塊暗色」拼起來，移動時幾塊的動畫對不齊，洞的四周會出現方形的接縫（2026-10-17 使用者說效果很差）。
    private let spot = CALayer()
    /// 螢光筆的線，每一筆一個圖層；手指放開後留著，跟紅點分開淡出。
    private let ink = CALayer()
    /// 正在畫的那一筆：手機送的筆畫號碼、圖層、經過的點。
    private var stroke: (id: UInt8, layer: CAShapeLayer, points: [CGPoint])?
    private var inkTask: Task<Void, Never>?
    private var mode: PointerUpdate.Mode = .hidden
    private var size = CGSize.zero
    private var watchdog: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    #if DEBUG
    /// 開發版示範：只蓋這一塊，不蓋整個螢幕（見檔案最後的 runDemo）。
    fileprivate var demoFrame: CGRect?
    #endif

    /// 聚光燈圓圈的半徑（相對螢幕高度）、邊緣從亮到暗的範圍（相對半徑），與四周有多暗。
    /// 2026-10-17 第一版邊緣太寬（像一團白光）、四周 0.72 內容還看得很清楚，改成邊緣窄一點、四周暗一點。
    private static let spotRadius = 0.17
    private static let edge = (inner: 0.9, outer: 1.1)
    private static let dim = 0.8
    /// 兩筆位置之間的補間；比送的間隔（約 33 毫秒）稍長，紅點才不會一頓一頓。
    private static let step = 0.07
    /// 螢光筆：線的粗細（相對螢幕高度）、顏色與透明度，最後一筆畫完多久後淡掉。
    private static let inkWidth = 0.02
    private static let inkColor = CGColor(red: 1, green: 0.8, blue: 0, alpha: 1)
    private static let inkOpacity: Float = 0.68
    private static let inkLinger: Duration = .seconds(4)

    func show(_ update: PointerUpdate) {
        guard update.mode != .hidden else { return hide() }
        hideTask?.cancel()
        let appearing = mode == .hidden || window == nil
        // 螢光筆的線還在畫面上時不要重新擺視窗，線才不會跑位
        if window?.isVisible != true {
            let screen = Self.targetScreen()
            var frame = screen.frame
            #if DEBUG
            if let demoFrame { frame = demoFrame }
            #endif
            prepare(frame: frame, scale: screen.backingScaleFactor)
        }
        guard let window else { return }

        let point = CGPoint(x: update.x * size.width, y: (1 - update.y) * size.height)
        if update.mode == .highlighter {
            draw(to: point, stroke: update.stroke)
        } else if stroke != nil {
            endStroke()
        }
        CATransaction.begin()
        // 剛出現或換模式時直接跳到位置，不要從上一次的地方滑過來
        if appearing || update.mode != mode {
            CATransaction.setDisableActions(true)
        } else {
            CATransaction.setAnimationDuration(Self.step)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        }
        dot.isHidden = update.mode != .laser
        spot.isHidden = update.mode != .spotlight
        dot.position = point
        spot.position = point
        CATransaction.commit()

        if appearing || update.mode != mode {
            mode = update.mode
            window.orderFrontRegardless()
            fade(live, to: 1)
        }
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { self?.hide() }
        }
    }

    /// 手指放開：紅點、聚光燈淡出；螢光筆的線留幾秒再淡掉。
    func hide() {
        guard mode != .hidden else { return }
        endStroke()
        mode = .hidden
        watchdog?.cancel()
        fade(live, to: 0)
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.3))
            if !Task.isCancelled { self?.orderOutIfIdle() }
        }
    }

    /// 全部收起（結束簡報、Mac 鎖定時），螢光筆的線也馬上清掉。
    func dismiss() {
        hide()
        clearInk()
    }

    /// 清掉螢光筆的線：翻頁時馬上清，畫完幾秒後慢慢淡掉。正在畫的那一筆也清掉，手指繼續移動就從那裡重新開始一筆。
    func clearInk(fade duration: TimeInterval = 0.15) {
        inkTask?.cancel()
        stroke = nil
        guard let layers = ink.sublayers, !layers.isEmpty else { return }
        // 一筆一筆淡出，不淡整個 ink：淡出時又開始畫的新線才不會跟著消失
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        layers.forEach { $0.opacity = 0 }
        CATransaction.commit()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration + 0.05))
            layers.forEach { $0.removeFromSuperlayer() }
            self?.orderOutIfIdle()
        }
    }

    // MARK: - 螢光筆

    private func draw(to point: CGPoint, stroke id: UInt8) {
        inkTask?.cancel()
        if var current = stroke, current.id == id {
            current.points.append(point)
            stroke = current
        } else {
            let layer = CAShapeLayer()
            layer.frame = CGRect(origin: .zero, size: size)
            layer.contentsScale = root.contentsScale
            layer.fillColor = nil
            layer.strokeColor = Self.inkColor
            layer.lineWidth = max(6, size.height * Self.inkWidth)
            layer.lineCap = .round
            layer.lineJoin = .round
            // 透明度放在圖層上、線本身不透明：同一筆自己交疊的地方才不會更深；不同筆交疊會更深，跟真的螢光筆一樣
            layer.opacity = Self.inkOpacity
            ink.addSublayer(layer)
            stroke = (id, layer, [point])
        }
        guard let stroke else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        stroke.layer.path = Self.smoothPath(stroke.points)
        CATransaction.commit()
    }

    /// 這一筆畫完：最後一筆畫完幾秒後全部淡掉，中間又畫就重新計時（圈起來再畫底線，會一起留著）。
    private func endStroke() {
        stroke = nil
        guard ink.sublayers?.isEmpty == false else { return }
        inkTask?.cancel()
        inkTask = Task { [weak self] in
            try? await Task.sleep(for: Self.inkLinger)
            if !Task.isCancelled { self?.clearInk(fade: 0.8) }
        }
    }

    /// 經過每一點的平滑曲線：相鄰兩點的中點相連、原本的點當控制點，手機送的點之間才不會有折角。
    private static func smoothPath(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first, let last = points.last else { return path }
        path.move(to: first)
        if points.count > 2 {
            for i in 1..<points.count - 1 {
                let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2, y: (points[i].y + points[i + 1].y) / 2)
                path.addQuadCurve(to: mid, control: points[i])
            }
        }
        // 只有一點時是長度 0 的線，圓的線頭會畫成一個點
        path.addLine(to: last)
        return path
    }

    /// 紅點、聚光燈都收起、也沒有螢光筆的線了，才把視窗拿掉。
    private func orderOutIfIdle() {
        guard mode == .hidden, ink.sublayers?.isEmpty != false else { return }
        window?.orderOut(nil)
    }

    /// 要畫在哪個螢幕：Mac 正在使用的 App 蓋滿整個螢幕的視窗（播放中的簡報）所在的螢幕。
    /// 接投影機時怎麼挑見 `PresentationScreen`（有各種螢幕配置的測試）。
    static func targetScreen() -> NSScreen {
        let screens = NSScreen.screens
        guard !screens.isEmpty, let app = NSWorkspace.shared.frontmostApplication else { return NSScreen.main ?? screens[0] }
        let windows = (CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? [])
            .filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier }
            .compactMap { info -> CGRect? in
                guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
                return CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            }
        let described = screens.map { screen in
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            return PresentationScreen.Screen(frame: screen.frame, isBuiltin: CGDisplayIsBuiltin(id) != 0)
        }
        guard let index = PresentationScreen.choose(screens: described, windows: windows) else { return NSScreen.main ?? screens[0] }
        return screens[index]
    }

    // MARK: - 畫面

    private func prepare(frame: CGRect, scale: CGFloat) {
        let window = window ?? makeWindow()
        self.window = window
        window.setFrame(frame, display: false)
        size = frame.size
        root.frame = CGRect(origin: .zero, size: size)
        root.contentsScale = scale
        live.frame = root.bounds
        ink.frame = root.bounds

        // 投影在教室後排也要看得到：比滑鼠游標大得多（2026-10-17 實測 0.03 偏小）
        let diameter = max(28, size.height * 0.042)
        dot.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        dot.cornerRadius = diameter / 2
        dotCore.frame = dot.bounds.insetBy(dx: diameter * 0.32, dy: diameter * 0.32)
        dotCore.cornerRadius = dotCore.bounds.width / 2
        dot.shadowRadius = diameter * 0.6

        // 圖只畫洞附近一小塊（邊緣才細緻），外面靠 contentsRect 超出圖的部分延伸最外圈的暗色，
        // 整片要大到洞移到螢幕任何一角，暗色都還蓋得滿整個螢幕
        let radius = size.height * Self.spotRadius
        let patch = (radius * Self.edge.outer + 4).rounded(.up) * 2
        let side = 2 * hypot(size.width, size.height) + patch
        spot.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        spot.contents = Self.spotImage(radius: radius, patch: patch, scale: scale)
        let k = side / patch
        spot.contentsRect = CGRect(x: (1 - k) / 2, y: (1 - k) / 2, width: k, height: k)
    }

    private func makeWindow() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        // 蓋在全螢幕播放的簡報上面，每個桌面空間都在
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isReleasedWhenClosed = false

        let view = NSView()
        view.layer = root
        view.wantsLayer = true
        panel.contentView = view
        live.opacity = 0

        let red = CGColor(red: 1, green: 0.16, blue: 0.1, alpha: 1)
        dot.backgroundColor = red
        dot.shadowColor = red
        dot.shadowOpacity = 0.9
        dot.shadowOffset = .zero
        dotCore.backgroundColor = CGColor(red: 1, green: 0.85, blue: 0.8, alpha: 1)
        dot.addSublayer(dotCore)

        live.addSublayer(spot)
        live.addSublayer(dot)
        root.addSublayer(live)
        // 線畫在聚光燈的暗色上面
        root.addSublayer(ink)
        return panel
    }

    /// 聚光燈的圖：邊長 patch 點的正方形，中間半徑 radius 左右的圓透明，邊緣柔和地變暗，最外圈都是暗色。
    private static func spotImage(radius: CGFloat, patch: CGFloat, scale: CGFloat) -> CGImage? {
        let pixels = Int((patch * scale).rounded(.up))
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: CGFloat(pixels) / patch, y: CGFloat(pixels) / patch)
        let center = CGPoint(x: patch / 2, y: patch / 2)
        let dark = CGColor(gray: 0, alpha: dim)
        context.setFillColor(dark)
        context.fill(CGRect(x: 0, y: 0, width: patch, height: patch))
        context.setBlendMode(.copy)
        let colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: dim * 0.5), dark] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
                                        locations: [0, 0.5, 1]) else { return nil }
        context.drawRadialGradient(gradient, startCenter: center, startRadius: radius * edge.inner, endCenter: center,
                                   endRadius: radius * edge.outer, options: [.drawsBeforeStartLocation])
        return context.makeImage()
    }

    private func fade(_ layer: CALayer, to opacity: Float) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        layer.opacity = opacity
        CATransaction.commit()
    }
}

#if DEBUG
// MARK: - 開發版示範

extension PointerOverlay {
    /// `-PresenceDemo YES -PresencePointerDemo spotlight|laser|highlighter`：在螢幕中間 1280×720 的範圍畫一張假的投影片，
    /// 紅點或聚光燈照固定路線走一遍（慢慢畫 8 字、快速甩到角落、停住、收起），螢光筆畫一條底線再圈一個長條，
    /// 用來錄影檢查效果。
    /// 假投影片畫在同一個視窗裡，只錄這個視窗就看得到結果，不會錄到螢幕上其他東西。
    func runDemo(_ mode: PointerUpdate.Mode) async {
        guard let screen = NSScreen.main else { return }
        // -PresencePointerDemoReal YES：照真正的規則挑螢幕、畫在整個螢幕上，不畫假投影片（接投影機或虛擬螢幕時測）
        if !UserDefaults.standard.bool(forKey: "PresencePointerDemoReal") {
            let size = CGSize(width: 1280, height: 720)
            demoFrame = CGRect(x: screen.frame.midX - size.width / 2, y: screen.frame.midY - size.height / 2,
                               width: size.width, height: size.height)
            let backdrop = CALayer()
            backdrop.frame = CGRect(origin: .zero, size: size)
            backdrop.contents = Self.demoSlide(size: size, scale: screen.backingScaleFactor)
            root.insertSublayer(backdrop, at: 0)
        }
        // 錄影要知道視窗編號：視窗第一次出現時印出來
        var announced = false
        func announce() {
            guard !announced, let window else { return }
            print("pointer-demo-window \(window.windowNumber) frame \(window.frame) screen \(window.screen?.localizedName ?? "?")")
            announced = true
        }

        if mode == .highlighter {
            // 跟手機一樣每 16 毫秒一點；手指放開後線留著，幾秒後淡掉
            let underline = stride(from: 0.0, through: 1, by: 1.0 / 48).map { (u: Double) -> (Double, Double) in
                (0.06 + 0.44 * u, 0.38 + 0.004 * sin(u * 9))
            }
            let circle = stride(from: 0.0, through: 1.08, by: 1.0 / 72).map { u -> (Double, Double) in
                let a = -Double.pi / 2 + u * 2 * .pi
                return (0.906 + 0.06 * cos(a), 0.31 + 0.1 * sin(a))
            }
            for (number, points) in [underline, circle].enumerated() {
                for (x, y) in points {
                    show(PointerUpdate(mode: .highlighter, x: x, y: y, stroke: UInt8(number + 1)))
                    announce()
                    try? await Task.sleep(for: .milliseconds(16))
                }
                hide()
                try? await Task.sleep(for: .milliseconds(400))
            }
            try? await Task.sleep(for: .seconds(6))
            print("pointer-demo-done")
            return
        }

        func point(at t: Double) -> (Double, Double)? {
            switch t {
            case ..<1: return (0.3, 0.4)
            case ..<4:
                let a = (t - 1) / 3 * 2 * .pi
                return (0.5 + 0.3 * sin(a), 0.5 + 0.25 * sin(2 * a))
            case ..<5:
                // 一秒內甩過四個角：洞到了角落，四周還是要整片變暗
                let corners = [(0.5, 0.5), (0.02, 0.03), (0.98, 0.03), (0.02, 0.97), (0.98, 0.97)]
                let u = (t - 4) * 4, i = min(Int(u), 3), f = u - Double(i)
                return (corners[i].0 + (corners[i + 1].0 - corners[i].0) * f,
                        corners[i].1 + (corners[i + 1].1 - corners[i].1) * f)
            case ..<6: return (0.98, 0.97)
            default: return nil
            }
        }
        let start = Date()
        while let (x, y) = point(at: Date().timeIntervalSince(start)) {
            show(PointerUpdate(mode: mode, x: x, y: y))
            announce()
            try? await Task.sleep(for: .milliseconds(33))
        }
        hide()
        try? await Task.sleep(for: .seconds(1))
        print("pointer-demo-done")
    }

    /// 假投影片：白底、標題、幾行字與長條圖，看得出暗的地方還認不認得出內容。
    private static func demoSlide(size: CGSize, scale: CGFloat) -> CGImage? {
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor.white.setFill()
            rect.fill()
            NSColor(red: 0.12, green: 0.3, blue: 0.6, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: rect.width, height: 110).fill()
            ("季度成果" as NSString).draw(at: NSPoint(x: 60, y: 28), withAttributes: [
                .font: NSFont.boldSystemFont(ofSize: 48), .foregroundColor: NSColor.white])
            for i in 0..<5 {
                ("• 第 \(i + 1) 點：營收成長、使用者增加、成本下降" as NSString).draw(
                    at: NSPoint(x: 60, y: 160 + CGFloat(i) * 70),
                    withAttributes: [.font: NSFont.systemFont(ofSize: 32), .foregroundColor: NSColor.darkGray])
            }
            let colors: [NSColor] = [.systemRed, .systemOrange, .systemGreen, .systemBlue]
            for (i, h) in [180.0, 260, 330, 420].enumerated() {
                colors[i].setFill()
                NSRect(x: 860 + Double(i) * 90, y: 640 - h, width: 60, height: h).fill()
            }
            return true
        }
        var rect = CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale))
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}
#endif
