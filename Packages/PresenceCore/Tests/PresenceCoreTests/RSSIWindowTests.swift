import Foundation
import Testing
@testable import PresenceCore

struct RSSIWindowTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 0)

    @Test(arguments: [
        ([-60], -60),
        ([-70, -50, -60], -60),
        ([-60, -61], -61),          // 偶數取兩個中間值的平均，往弱的方向取整
        ([-80, -40, -41, -79], -60),
    ])
    func medianOfSamples(values: [Int], expected: Int) {
        var window = RSSIWindow(duration: 10)
        for (i, v) in values.enumerated() {
            window.add(v, at: t0.addingTimeInterval(Double(i) * 0.1))
        }
        #expect(window.median == expected)
    }

    @Test func emptyWindowHasNoMedian() {
        #expect(RSSIWindow(duration: 4).median == nil)
    }

    @Test(arguments: [0, 5, -127, -200])
    func invalidReadingsAreIgnored(rssi: Int) {
        var window = RSSIWindow(duration: 4)
        window.add(rssi, at: t0)
        #expect(window.count == 0)
    }

    @Test func samplesOlderThanDurationAreDropped() {
        var window = RSSIWindow(duration: 4)
        window.add(-50, at: t0)
        window.add(-70, at: t0.addingTimeInterval(3))
        window.prune(now: t0.addingTimeInterval(4.5))
        #expect(window.count == 1)
        #expect(window.median == -70)
    }

    @Test func singleSpikeDoesNotMoveTheMedian() {
        var window = RSSIWindow(duration: 4)
        for (i, v) in [-80, -79, -30, -81, -80].enumerated() {
            window.add(v, at: t0.addingTimeInterval(Double(i) * 0.5))
        }
        #expect(window.median == -80)
    }
}
