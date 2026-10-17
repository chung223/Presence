import CoreGraphics

/// 雷射筆、聚光燈、螢光筆要畫在哪個螢幕（Presence 的 `PointerOverlay.targetScreen()` 用）。
///
/// 規則：最前面的 App（播放中的簡報）蓋滿整個畫面的螢幕；接投影機時投影幕和筆電（簡報者畫面）上都有全螢幕的視窗，
/// 優先選外接的、再來選不是主螢幕的那個：投影機一定是外接的。都沒有全螢幕的視窗時，才選最大的視窗所在的螢幕。
///
/// 原本只挑「最大的視窗」：教室常見的 1024×768 投影機比 MacBook 的螢幕小，紅點會畫到筆電的簡報者畫面上，
/// 台下看不到（2026-10-17 推算發現）。這裡不碰 AppKit，沒有投影機也能用各種螢幕配置測試。
public enum PresentationScreen {
    public struct Screen: Sendable, Equatable {
        /// 跟 `NSScreen.frame` 一樣：原點在主螢幕左下角。
        public var frame: CGRect
        public var isBuiltin: Bool

        public init(frame: CGRect, isBuiltin: Bool) {
            self.frame = frame
            self.isBuiltin = isBuiltin
        }
    }

    /// `screens` 的第一個是主螢幕（有選單列的那個，跟 `NSScreen.screens` 一樣）；
    /// `windows` 是最前面那個 App 的視窗，用視窗清單的座標（原點在主螢幕左上角）。
    /// 回傳 `screens` 裡的位置；沒有視窗、或視窗不在任何螢幕上時是 nil。
    public static func choose(screens: [Screen], windows: [CGRect]) -> Int? {
        guard let primary = screens.first else { return nil }
        func flipped(_ frame: CGRect) -> CGRect {
            CGRect(x: frame.minX, y: primary.frame.height - frame.maxY, width: frame.width, height: frame.height)
        }
        // 蓋住九成以上就算：最大化的視窗會少掉選單列和 Dock 那一點
        let covered = screens.indices.filter { index in
            let area = flipped(screens[index].frame)
            return windows.contains { window in
                let overlap = window.intersection(area)
                return !overlap.isNull && overlap.width * overlap.height >= area.width * area.height * 0.9
            }
        }
        func score(_ index: Int) -> Int {
            (screens[index].isBuiltin ? 0 : 2) + (index == 0 ? 0 : 1)
        }
        if let best = covered.max(by: { score($0) < score($1) }) { return best }
        guard let biggest = windows.max(by: { $0.width * $0.height < $1.width * $1.height }) else { return nil }
        let center = CGPoint(x: biggest.midX, y: primary.frame.height - biggest.midY)
        return screens.firstIndex { $0.frame.contains(center) }
    }
}
