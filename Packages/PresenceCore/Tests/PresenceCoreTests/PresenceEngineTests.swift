import Foundation
import Testing
@testable import PresenceCore

struct PresenceEngineTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 0)
    let settings = ProximitySettings(
        unlockRSSI: -60, lockRSSI: -75, lockDelay: 5, signalTimeout: 60,
        filterWindow: 4, minimumSamples: 3, manualLockRearm: 30
    )

    /// 從 `start` 秒開始，每 0.5 秒送一筆樣本，回傳過程中出現的離開判定。
    @discardableResult
    func feed(_ engine: inout PresenceEngine, _ values: [Int], from start: TimeInterval) -> [DepartureReason] {
        var departures: [DepartureReason] = []
        for (i, v) in values.enumerated() {
            if let d = engine.record(rssi: v, at: t0.addingTimeInterval(start + Double(i) * 0.5)) {
                departures.append(d)
            }
        }
        return departures
    }

    @Test func startsUnknownAndCannotUnlock() {
        let engine = PresenceEngine(settings: settings, now: t0)
        #expect(engine.presence == .unknown)
        #expect(engine.canUnlock == false)
    }

    @Test func becomesNearAfterEnoughSamples() {
        var engine = PresenceEngine(settings: settings, now: t0)
        feed(&engine, [-55, -56], from: 0)
        #expect(engine.presence == .unknown, "兩筆還不夠")
        feed(&engine, [-55], from: 1)
        #expect(engine.presence == .near)
        #expect(engine.canUnlock)
    }

    @Test("單筆異常強訊號不會讓它可以解鎖", .bug("https://github.com/ts1/BLEUnlock/pull/183"))
    func singleSpikeCannotUnlock() {
        var engine = PresenceEngine(settings: settings, now: t0)
        feed(&engine, [-85, -84, -86, -84], from: 0)
        feed(&engine, [-35], from: 2)
        #expect(engine.canUnlock == false)
    }

    @Test func weakSignalLocksAfterDelayOnce() {
        var engine = PresenceEngine(settings: settings, now: t0)
        feed(&engine, [-55, -55, -55], from: 0)
        // 從 2 秒開始變弱，持續 8 秒
        let departures = feed(&engine, Array(repeating: -85, count: 16), from: 2)
        #expect(departures == [.weakSignal])
        guard case .away(.weakSignal, _) = engine.presence else {
            Issue.record("應該是 away(.weakSignal)，實際是 \(engine.presence)")
            return
        }
    }

    @Test func recoveringBeforeDelayCancelsTheCountdown() {
        var engine = PresenceEngine(settings: settings, now: t0)
        feed(&engine, [-55, -55, -55], from: 0)
        var departures = feed(&engine, Array(repeating: -85, count: 6), from: 2)   // 3 秒
        departures += feed(&engine, Array(repeating: -55, count: 12), from: 5)     // 回來
        #expect(departures.isEmpty)
        #expect(engine.presence == .near)
    }

    @Test func signalLostAfterTimeoutOnce() {
        var engine = PresenceEngine(settings: settings, now: t0)
        feed(&engine, [-55, -55, -55], from: 0)
        #expect(engine.tick(at: t0.addingTimeInterval(50)) == nil)
        #expect(engine.tick(at: t0.addingTimeInterval(62)) == .signalLost)
        #expect(engine.tick(at: t0.addingTimeInterval(70)) == nil, "不會重複判定")
    }

    @Test func noSignalAtAllAfterResetCountsAsLost() {
        var engine = PresenceEngine(settings: settings, now: t0)
        #expect(engine.tick(at: t0.addingTimeInterval(59)) == nil)
        #expect(engine.tick(at: t0.addingTimeInterval(60)) == .signalLost)
    }

    @Test("睡眠醒來後不能沿用舊的「在附近」狀態")
    func resetRequiresFreshSamples() throws {
        var engine = PresenceEngine(settings: settings, now: t0)
        feed(&engine, [-50, -50, -50], from: 0)
        try #require(engine.canUnlock)

        engine.reset(at: t0.addingTimeInterval(2))
        #expect(engine.presence == .unknown)
        #expect(engine.canUnlock == false)

        feed(&engine, [-50, -50], from: 3)
        #expect(engine.canUnlock == false, "醒來後只收到兩筆")
        feed(&engine, [-50], from: 4)
        #expect(engine.canUnlock)
    }

    @Test("離開後要超過解鎖門檻才算回來")
    func awayNeedsArrivalThresholdToReturn() {
        var engine = PresenceEngine(settings: settings, now: t0)
        feed(&engine, [-55, -55, -55], from: 0)
        feed(&engine, Array(repeating: -85, count: 16), from: 2)
        feed(&engine, Array(repeating: -70, count: 8), from: 10)    // 介於兩個門檻之間
        guard case .away = engine.presence else {
            Issue.record("介於兩個門檻之間時應該維持離開，實際是 \(engine.presence)")
            return
        }
        feed(&engine, Array(repeating: -58, count: 8), from: 14)
        #expect(engine.presence == .near)
    }

    @Test func oldSamplesExpireSoCanUnlockTurnsOff() throws {
        var engine = PresenceEngine(settings: settings, now: t0)
        feed(&engine, [-50, -50, -50], from: 0)
        try #require(engine.canUnlock)
        engine.tick(at: t0.addingTimeInterval(10))
        #expect(engine.canUnlock == false)
        #expect(engine.smoothedRSSI == nil)
    }

    @Test func unlockDisabledMeansCanUnlockIsAlwaysFalse() {
        var s = settings
        s.unlockRSSI = nil
        var engine = PresenceEngine(settings: s, now: t0)
        feed(&engine, [-40, -40, -40, -40], from: 0)
        #expect(engine.presence == .near)
        #expect(engine.canUnlock == false)
    }

    @Test func startingFarAwayCountsDownToLock() {
        var engine = PresenceEngine(settings: settings, now: t0)
        let departures = feed(&engine, Array(repeating: -90, count: 16), from: 0)
        #expect(departures == [.weakSignal])
    }
}

struct ProximitySettingsTests {
    @Test func lockThresholdAboveUnlockIsClamped() {
        let s = ProximitySettings(unlockRSSI: -70, lockRSSI: -60).normalized()
        #expect(s.lockRSSI == -70)
    }

    @Test(arguments: [
        (Optional(-60), Optional(-75), -60, -75),
        (nil, Optional(-75), -75, -75),
        (Optional(-60), nil, -60, -60),
    ] as [(Int?, Int?, Int, Int)])
    func thresholdsFallBackToEachOther(unlock: Int?, lock: Int?, arrival: Int, departure: Int) {
        let s = ProximitySettings(unlockRSSI: unlock, lockRSSI: lock)
        #expect(s.arrivalThreshold == arrival)
        #expect(s.departureThreshold == departure)
    }

    @Test func outOfRangeValuesAreClamped() {
        let s = ProximitySettings(unlockRSSI: 10, lockRSSI: -150, lockDelay: -1, minimumSamples: 0).normalized()
        #expect(s.unlockRSSI == -20)
        #expect(s.lockRSSI == -100)
        #expect(s.lockDelay == 0)
        #expect(s.minimumSamples == 1)
    }
}
