import AppKit
import PresenceLink
import QuartzCore

/// 雷射筆與聚光燈：在播放簡報的那個螢幕最上層疊一個透明、點不到的視窗，畫紅點或聚光燈。
///
/// 只畫、不點擊，不會改動任何 App，所以 Keynote、PowerPoint、Google 簡報、PDF 都一樣能用。
/// 手機每秒送約 30 筆位置，中間用很短的動畫補平；超過 2.5 秒沒有新位置就自動收起（例如手機斷線）。
@MainActor
final class PointerOverlay {
    static let shared = PointerOverlay()

    private var window: NSPanel?
    private var root = CALayer()
    private let dot = CALayer()
    private let dotCore = CALayer()
    private let hole = CALayer()
    /// 聚光燈四周變暗的部分：洞的上、下、左、右四塊。
    private let shades = (0..<4).map { _ in CALayer() }
    private var mode: PointerUpdate.Mode = .hidden
    private var size = CGSize.zero
    private var watchdog: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?

    /// 聚光燈圓圈的半徑（相對螢幕高度）與邊緣漸層的寬度。
    private static let spotRadius = 0.17
    private static let feather = 1.35
    private static let dim = 0.72
    /// 兩筆位置之間的補間；比送的間隔（約 33 毫秒）稍長，紅點才不會一頓一頓。
    private static let step = 0.07

    func show(_ update: PointerUpdate) {
        guard update.mode != .hidden else { return hide() }
        hideTask?.cancel()
        let appearing = mode == .hidden || window == nil
        if appearing { prepare(on: Self.targetScreen()) }
        guard let window else { return }

        let point = CGPoint(x: update.x * size.width, y: (1 - update.y) * size.height)
        CATransaction.begin()
        // 剛出現或換模式時直接跳到位置，不要從上一次的地方滑過來
        if appearing || update.mode != mode {
            CATransaction.setDisableActions(true)
        } else {
            CATransaction.setAnimationDuration(Self.step)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        }
        dot.isHidden = update.mode != .laser
        hole.isHidden = update.mode != .spotlight
        shades.forEach { $0.isHidden = update.mode != .spotlight }
        dot.position = point
        if update.mode == .spotlight { placeSpotlight(at: point) }
        CATransaction.commit()

        if appearing || update.mode != mode {
            mode = update.mode
            window.orderFrontRegardless()
            fade(to: 1)
        }
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            if !Task.isCancelled { self?.hide() }
        }
    }

    func hide() {
        guard mode != .hidden else { return }
        mode = .hidden
        watchdog?.cancel()
        fade(to: 0)
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(0.3))
            if !Task.isCancelled { self?.window?.orderOut(nil) }
        }
    }

    /// 要畫在哪個螢幕：Mac 正在使用的 App 最大的那個視窗所在的螢幕（接投影機時就是播放簡報的那個）。
    static func targetScreen() -> NSScreen {
        let screens = NSScreen.screens
        guard let primary = screens.first, let app = NSWorkspace.shared.frontmostApplication else { return NSScreen.main ?? screens[0] }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let biggest = windows
            .filter { ($0[kCGWindowOwnerPID as String] as? pid_t) == app.processIdentifier }
            .compactMap { info -> CGRect? in
                guard let bounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { return nil }
                return CGRect(x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0, width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0)
            }
            .max { $0.width * $0.height < $1.width * $1.height }
        guard let biggest else { return NSScreen.main ?? primary }
        // 視窗清單的座標原點在主螢幕左上角，NSScreen 的在左下角
        let center = CGPoint(x: biggest.midX, y: primary.frame.height - biggest.midY)
        return screens.first { $0.frame.contains(center) } ?? NSScreen.main ?? primary
    }

    // MARK: - 畫面

    private func prepare(on screen: NSScreen) {
        let window = window ?? makeWindow()
        self.window = window
        window.setFrame(screen.frame, display: false)
        size = screen.frame.size
        root.frame = CGRect(origin: .zero, size: size)
        root.contentsScale = screen.backingScaleFactor

        // 投影在教室後排也要看得到：比滑鼠游標大得多（2026-10-17 實測 0.03 偏小）
        let diameter = max(28, size.height * 0.042)
        dot.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        dot.cornerRadius = diameter / 2
        dotCore.frame = dot.bounds.insetBy(dx: diameter * 0.32, dy: diameter * 0.32)
        dotCore.cornerRadius = dotCore.bounds.width / 2
        dot.shadowRadius = diameter * 0.6

        let outer = size.height * Self.spotRadius * Self.feather
        hole.bounds = CGRect(x: 0, y: 0, width: outer * 2, height: outer * 2)
        hole.contents = Self.holeImage(radius: outer, scale: screen.backingScaleFactor)
        hole.contentsScale = screen.backingScaleFactor
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
        root.opacity = 0

        let red = CGColor(red: 1, green: 0.16, blue: 0.1, alpha: 1)
        dot.backgroundColor = red
        dot.shadowColor = red
        dot.shadowOpacity = 0.9
        dot.shadowOffset = .zero
        dotCore.backgroundColor = CGColor(red: 1, green: 0.85, blue: 0.8, alpha: 1)
        dot.addSublayer(dotCore)

        shades.forEach {
            $0.backgroundColor = CGColor(gray: 0, alpha: Self.dim)
            $0.anchorPoint = .zero
            root.addSublayer($0)
        }
        root.addSublayer(hole)
        root.addSublayer(dot)
        return panel
    }

    /// 聚光燈：中間的洞用一張漸層圖（邊緣柔和），洞的四周用四塊暗色補滿整個螢幕，一起移動。
    private func placeSpotlight(at point: CGPoint) {
        hole.position = point
        let r = hole.bounds.width / 2
        let (w, h) = (size.width, size.height)
        let frames = [
            CGRect(x: 0, y: point.y + r, width: w, height: max(0, h - point.y - r)),
            CGRect(x: 0, y: 0, width: w, height: max(0, point.y - r)),
            CGRect(x: 0, y: point.y - r, width: max(0, point.x - r), height: r * 2),
            CGRect(x: point.x + r, y: point.y - r, width: max(0, w - point.x - r), height: r * 2),
        ]
        for (shade, frame) in zip(shades, frames) {
            shade.position = frame.origin
            shade.bounds = CGRect(origin: .zero, size: frame.size)
        }
    }

    /// 洞的圖：中間透明，往外漸暗到跟四周一樣暗。
    private static func holeImage(radius: CGFloat, scale: CGFloat) -> CGImage? {
        let side = Int((radius * 2 * scale).rounded())
        guard side > 0, let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpaceCreateDeviceRGB(),
                                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let center = CGPoint(x: CGFloat(side) / 2, y: CGFloat(side) / 2)
        let inner = CGFloat(side) / 2 / feather
        let colors = [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: dim)] as CFArray
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) else { return nil }
        // 圖的四角在圓外：先塗滿暗色，再畫漸層的圓
        context.setFillColor(CGColor(gray: 0, alpha: dim))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.setBlendMode(.copy)
        context.drawRadialGradient(gradient, startCenter: center, startRadius: inner, endCenter: center,
                                   endRadius: CGFloat(side) / 2, options: [])
        context.setFillColor(CGColor(gray: 0, alpha: 0))
        context.fillEllipse(in: CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2))
        return context.makeImage()
    }

    private func fade(to opacity: Float) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.2)
        root.opacity = opacity
        CATransaction.commit()
    }
}
