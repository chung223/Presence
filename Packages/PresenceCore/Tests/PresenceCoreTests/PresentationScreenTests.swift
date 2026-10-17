import CoreGraphics
import Testing
@testable import PresenceCore

/// 沒有投影機也能驗證：用真實的螢幕配置（NSScreen 的座標）和 Keynote 播放時的視窗位置（視窗清單的座標）。
struct PresentationScreenTests {
    typealias Screen = PresentationScreen.Screen

    /// 14 吋 MacBook Pro 的內建螢幕（預設解析度），當主螢幕。
    let macBook = Screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), isBuiltin: true)
    /// 筆電螢幕在視窗清單座標裡的位置（全螢幕的簡報者畫面）。
    let macBookWindow = CGRect(x: 0, y: 0, width: 1512, height: 982)

    @Test("教室常見的 1024×768 投影機比筆電小，也要畫在投影機上")
    func smallProjectorWithPresenterDisplay() {
        // 投影機接在筆電右邊、上緣對齊
        let projector = Screen(frame: CGRect(x: 1512, y: 982 - 768, width: 1024, height: 768), isBuiltin: false)
        let slideshow = CGRect(x: 1512, y: 0, width: 1024, height: 768)
        #expect(PresentationScreen.choose(screens: [macBook, projector], windows: [macBookWindow, slideshow]) == 1)
        // 原本「挑最大的視窗」會選到筆電：這正是要修的問題
        let biggest = [macBookWindow, slideshow].max { $0.width * $0.height < $1.width * $1.height }
        #expect(biggest == macBookWindow)
    }

    @Test("1080p 投影機接在筆電下方")
    func fullHDProjectorBelow() {
        let projector = Screen(frame: CGRect(x: 0, y: -1080, width: 1920, height: 1080), isBuiltin: false)
        let slideshow = CGRect(x: 0, y: 982, width: 1920, height: 1080)
        #expect(PresentationScreen.choose(screens: [macBook, projector], windows: [slideshow, macBookWindow]) == 1)
    }

    @Test("投影機被設成主螢幕（選單列在投影機上），筆電在左邊")
    func projectorIsMainDisplay() {
        let projector = Screen(frame: CGRect(x: 0, y: 0, width: 1024, height: 768), isBuiltin: false)
        let laptop = Screen(frame: CGRect(x: -1512, y: 768 - 982, width: 1512, height: 982), isBuiltin: true)
        let slideshow = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let presenter = CGRect(x: -1512, y: 0, width: 1512, height: 982)
        #expect(PresentationScreen.choose(screens: [projector, laptop], windows: [presenter, slideshow]) == 0)
    }

    @Test("沒開簡報者畫面：只有投影機上有全螢幕的視窗")
    func slideshowOnlyOnProjector() {
        let projector = Screen(frame: CGRect(x: 1512, y: 214, width: 1024, height: 768), isBuiltin: false)
        let slideshow = CGRect(x: 1512, y: 0, width: 1024, height: 768)
        #expect(PresentationScreen.choose(screens: [macBook, projector], windows: [slideshow]) == 1)
    }

    @Test("只有筆電、或投影機用鏡像（系統只看到一個螢幕）")
    func singleScreen() {
        #expect(PresentationScreen.choose(screens: [macBook], windows: [macBookWindow]) == 0)
    }

    @Test("桌機接兩台外接螢幕：簡報者畫面在主螢幕，投影片在另一台")
    func desktopWithTwoExternalDisplays() {
        let main = Screen(frame: CGRect(x: 0, y: 0, width: 2560, height: 1440), isBuiltin: false)
        let second = Screen(frame: CGRect(x: 2560, y: 1440 - 1080, width: 1920, height: 1080), isBuiltin: false)
        let presenter = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let slideshow = CGRect(x: 2560, y: 0, width: 1920, height: 1080)
        #expect(PresentationScreen.choose(screens: [main, second], windows: [presenter, slideshow]) == 1)
    }

    @Test("Google 簡報：投影機上全螢幕播放，筆電上是講者備忘稿的小視窗")
    func browserSlidesWithNotesWindow() {
        let projector = Screen(frame: CGRect(x: 1512, y: 214, width: 1024, height: 768), isBuiltin: false)
        let slideshow = CGRect(x: 1512, y: 0, width: 1024, height: 768)
        let notes = CGRect(x: 200, y: 150, width: 900, height: 600)
        #expect(PresentationScreen.choose(screens: [macBook, projector], windows: [notes, slideshow]) == 1)
    }

    @Test("還沒開始播放：沒有全螢幕的視窗，就畫在最大的視窗那個螢幕")
    func notPresentingFallsBackToBiggestWindow() {
        let projector = Screen(frame: CGRect(x: 1512, y: 214, width: 1024, height: 768), isBuiltin: false)
        let editor = CGRect(x: 100, y: 80, width: 1200, height: 780)
        let inspector = CGRect(x: 1600, y: 100, width: 300, height: 400)
        #expect(PresentationScreen.choose(screens: [macBook, projector], windows: [editor, inspector]) == 0)
    }

    @Test("最大化的視窗（少了選單列和 Dock）也算蓋滿")
    func maximizedWindowCounts() {
        let projector = Screen(frame: CGRect(x: 1512, y: 214, width: 1024, height: 768), isBuiltin: false)
        let maximized = CGRect(x: 1512, y: 0, width: 1024, height: 720)
        #expect(PresentationScreen.choose(screens: [macBook, projector], windows: [maximized]) == 1)
    }

    @Test func noWindows() {
        #expect(PresentationScreen.choose(screens: [macBook], windows: []) == nil)
        #expect(PresentationScreen.choose(screens: [], windows: [macBookWindow]) == nil)
    }
}
