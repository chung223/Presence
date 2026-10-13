import Foundation
import Testing
@testable import PresenceCore

struct PresenceGroupTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 0)
    let phone = UUID()
    let watch = UUID()
    let phoneSettings = ProximitySettings(unlockRSSI: -50, lockRSSI: -70, lockDelay: 5, signalTimeout: 60)
    let watchSettings = ProximitySettings(unlockRSSI: -62, lockRSSI: -80, lockDelay: 5, signalTimeout: 60)

    func makeGroup() -> PresenceGroup {
        PresenceGroup(devices: [phone: phoneSettings, watch: watchSettings], now: t0)
    }

    /// 兩台裝置交錯送樣本，每 0.5 秒一輪。
    @discardableResult
    func feed(_ group: inout PresenceGroup, phone p: Int?, watch w: Int?, seconds: Double, from start: Double) -> [PresenceChange] {
        var changes: [PresenceChange] = []
        var t = start
        while t < start + seconds {
            let date = t0.addingTimeInterval(t)
            if let p, let c = group.record(device: phone, rssi: p, at: date) { changes.append(c) }
            if let w, let c = group.record(device: watch, rssi: w, at: date) { changes.append(c) }
            if let c = group.tick(at: date) { changes.append(c) }
            t += 0.5
        }
        return changes
    }

    @Test func anyDeviceNearMeansNear() {
        var group = makeGroup()
        feed(&group, phone: -90, watch: -60, seconds: 10, from: 0)
        #expect(group.presence == .near)
    }

    @Test("手錶訊號變弱但手機還在，不會鎖定")
    func doesNotDepartWhileAnotherDeviceIsNear() {
        var group = makeGroup()
        feed(&group, phone: -45, watch: -60, seconds: 3, from: 0)
        let changes = feed(&group, phone: -45, watch: -95, seconds: 20, from: 3)
        #expect(changes.contains { if case .departed = $0 { true } else { false } } == false)
        #expect(group.presence == .near)
    }

    @Test func departsOnceWhenAllDevicesAreAway() {
        var group = makeGroup()
        feed(&group, phone: -45, watch: -60, seconds: 3, from: 0)
        let changes = feed(&group, phone: -90, watch: -95, seconds: 20, from: 3)
        #expect(changes == [.departed(.weakSignal)])
    }

    @Test("每台裝置用自己的門檻：-60 對手錶夠近，對手機不夠")
    func eachDeviceUsesItsOwnThresholds() throws {
        var group = makeGroup()
        feed(&group, phone: -60, watch: nil, seconds: 3, from: 0)
        #expect(group.canUnlock == false)
        feed(&group, phone: -60, watch: -60, seconds: 3, from: 3)
        #expect(group.canUnlock)
        let watchEngine = try #require(group.engine(for: watch))
        #expect(watchEngine.canUnlock)
    }

    @Test func arrivalFromEitherDevice() {
        var group = makeGroup()
        feed(&group, phone: -90, watch: -95, seconds: 20, from: 0)
        let changes = feed(&group, phone: -90, watch: -55, seconds: 3, from: 20)
        #expect(changes.contains(.arrived))
    }

    @Test("新加入的裝置從未知開始，不會讓已離開的狀態直接算回來")
    func newDeviceStartsUnknown() {
        var group = PresenceGroup(devices: [phone: phoneSettings], now: t0)
        feed(&group, phone: -90, watch: nil, seconds: 20, from: 0)
        group.configure([phone: phoneSettings, watch: watchSettings], now: t0.addingTimeInterval(20))
        #expect(group.presence == .unknown)
        #expect(group.canUnlock == false)
    }

    @Test func removingADeviceUpdatesThePresence() {
        var group = makeGroup()
        feed(&group, phone: -90, watch: -55, seconds: 10, from: 0)
        #expect(group.presence == .near)
        group.configure([phone: phoneSettings], now: t0.addingTimeInterval(10))
        guard case .away = group.presence else {
            Issue.record("只剩手機，而手機已離開，應該是 away，實際是 \(group.presence)")
            return
        }
    }

    @Test func emptyGroupIsUnknownAndCannotUnlock() {
        let group = PresenceGroup(now: t0)
        #expect(group.presence == .unknown)
        #expect(group.canUnlock == false)
    }

    @Test func resetMakesEveryDeviceUnknown() {
        var group = makeGroup()
        feed(&group, phone: -45, watch: -55, seconds: 3, from: 0)
        group.reset(at: t0.addingTimeInterval(3))
        #expect(group.presence == .unknown)
        #expect(group.canUnlock == false)
    }
}
