import Foundation
import Testing
@testable import PresenceCore

struct PresenceEngineTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 0)
    let settings = ProximitySettings(
        unlockRSSI: -60, lockRSSI: -75, lockDelay: 5, signalTimeout: 60,
        filterWindow: 4, minimumSamples: 3, manualLockRearm: 30
    )

    /// 從 `start` 秒開始，每隔 `interval` 秒送一筆樣本，回傳過程中的狀態變化。
    @discardableResult
    func feed(_ engine: inout PresenceEngine, _ values: [Int], from start: TimeInterval,
              every interval: TimeInterval = 0.5) -> [PresenceChange] {
        values.enumerated().compactMap { i, v in
            engine.record(rssi: v, at: t0.addingTimeInterval(start + Double(i) * interval))
        }
    }

    func departures(_ changes: [PresenceChange]) -> [DepartureReason] {
        changes.compactMap { if case .departed(let r) = $0 { r } else { nil } }
    }

    func arrivals(_ changes: [PresenceChange]) -> Int {
        changes.filter { $0 == .arrived }.count
    }

    @Test func startsUnknownAndCannotUnlock() {
        let engine = PresenceEngine(settings: settings, now: t0)
        #expect(engine.presence == .unknown)
        #expect(engine.canUnlock == false)
    }

    @Test func becomesNearAfterEnoughSamples() {
        var engine = PresenceEngine(settings: settings, now: t0)
        let first = feed(&engine, [-55, -56], from: 0)
        #expect(engine.presence == .unknown, "兩筆還不夠")
        #expect(first.isEmpty)
        let second = feed(&engine, [-55], from: 1)
        #expect(engine.presence == .near)
        #expect(engine.canUnlock)
        #expect(second == [.arrived])
    }

    @Test("單筆異常強訊號不會讓它可以解鎖", .bug("https://github.com/ts1/BLEUnlock/pull/183"))
    func singleSpikeCannotUnlock() {
        var engine = PresenceEngine(settings: settings, now: t0)
        feed(&engine, [-85, -84, -86, -84], from: 0)
        let changes = feed(&engine, [-35], from: 2)
        #expect(engine.canUnlock == false)
        #expect(arrivals(changes) == 0)
    }

    @Test("偶數筆樣本中有兩筆異常強訊號也不能解鎖")
    func twoSpikesInFourSamplesCannotUnlock() {
        var engine = PresenceEngine(settings: settings, now: t0)
        feed(&engine, [-80, -40, -79, -41], from: 0)
        #expect(engine.smoothedRSSI == -79)
        #expect(engine.canUnlock == false)
    }

    @Test("在門檻附近抖動不會重複觸發解鎖，要真的離開過才會再觸發")
    func arrivalFiresOnceUntilReallyLeaving() {
        var engine = PresenceEngine(settings: settings, now: t0)
        var changes = feed(&engine, [-58, -58, -58], from: 0)
        #expect(arrivals(changes) == 1)

        // 在 -60 上下各抖 3 dB，持續 10 秒
        let jitter = (0..<20).map { $0.isMultiple(of: 2) ? -57 : -63 }
        changes = feed(&engine, jitter, from: 2)
        #expect(arrivals(changes) == 0)

        // 掉到鎖定門檻以下再回來，才會再次觸發
        feed(&engine, [-80, -80, -80], from: 13)
        changes = feed(&engine, Array(repeating: -55, count: 10), from: 15)
        #expect(arrivals(changes) == 1)
    }

    @Test func weakSignalLocksAfterDelayOnce() {
        var engine = PresenceEngine(settings: settings, now: t0)
        feed(&engine, [-55, -55, -55], from: 0)
        // 從 2 秒開始變弱，持續 8 秒
        let changes = feed(&engine, Array(repeating: -85, count: 16), from: 2)
        #expect(departures(changes) == [.weakSignal])
        guard case .away(.weakSignal, _) = engine.presence else {
            Issue.record("應該是 away(.weakSignal)，實際是 \(engine.presence)")
            return
        }
    }

    @Test func recoveringBeforeDelayCancelsTheCountdown() {
        var engine = PresenceEngine(settings: settings, now: t0)
        feed(&engine, [-55, -55, -55], from: 0)
        var changes = feed(&engine, Array(repeating: -85, count: 6), from: 2)   // 3 秒
        changes += feed(&engine, Array(repeating: -55, count: 12), from: 5)     // 回來
        #expect(departures(changes).isEmpty)
        #expect(engine.presence == .near)
    }

    @Test func countdownContinuesWhenSamplesStop() {
        var engine = PresenceEngine(settings: settings, now: t0)
        feed(&engine, [-55, -55, -55], from: 0)
        feed(&engine, [-85, -85], from: 2)
        // 之後完全沒有樣本，視窗會清空，但倒數要繼續
        var changes: [PresenceChange] = []
        for second in 4...10 {
            if let change = engine.tick(at: t0.addingTimeInterval(Double(second))) { changes.append(change) }
        }
        #expect(departures(changes) == [.weakSignal])
    }

    @Test("樣本稀疏又微弱時，不能一直停在未知而不鎖定")
    func sparseWeakSamplesStillLeadToDeparture() {
        var engine = PresenceEngine(settings: settings, now: t0)
        var changes: [PresenceChange] = []
        // 每 2.5 秒一筆 -92 dBm，持續 60 秒
        for i in 0..<24 {
            let t = t0.addingTimeInterval(Double(i) * 2.5)
            if let c = engine.record(rssi: -92, at: t) { changes.append(c) }
            if let c = engine.tick(at: t.addingTimeInterval(1)) { changes.append(c) }
        }
        #expect(departures(changes) == [.weakSignal])
    }

    @Test func signalLostAfterTimeoutOnce() {
        var engine = PresenceEngine(settings: settings, now: t0)
        feed(&engine, [-55, -55, -55], from: 0)
        #expect(engine.tick(at: t0.addingTimeInterval(50)) == nil)
        #expect(engine.tick(at: t0.addingTimeInterval(62)) == .departed(.signalLost))
        #expect(engine.tick(at: t0.addingTimeInterval(70)) == nil, "不會重複判定")
    }

    @Test func noSignalAtAllAfterResetCountsAsLost() {
        var engine = PresenceEngine(settings: settings, now: t0)
        #expect(engine.tick(at: t0.addingTimeInterval(59)) == nil)
        #expect(engine.tick(at: t0.addingTimeInterval(60)) == .departed(.signalLost))
    }

    @Test("睡眠醒來後不能沿用舊的「在附近」狀態")
    func resetRequiresFreshSamples() throws {
        var engine = PresenceEngine(settings: settings, now: t0)
        feed(&engine, [-50, -50, -50], from: 0)
        try #require(engine.canUnlock)

        engine.reset(at: t0.addingTimeInterval(2))
        #expect(engine.presence == .unknown)
        #expect(engine.canUnlock == false)

        var changes = feed(&engine, [-50, -50], from: 3)
        #expect(engine.canUnlock == false, "醒來後只收到兩筆")
        changes += feed(&engine, [-50], from: 4)
        #expect(engine.canUnlock)
        #expect(arrivals(changes) == 1, "重設後重新收到足夠樣本，要再觸發一次")
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
        let changes = feed(&engine, Array(repeating: -58, count: 8), from: 14)
        #expect(engine.presence == .near)
        #expect(arrivals(changes) == 1)
    }

    @Test func oldSamplesExpireSoCanUnlockTurnsOff() throws {
        var engine = PresenceEngine(settings: settings, now: t0)
        feed(&engine, [-50, -50, -50], from: 0)
        try #require(engine.canUnlock)
        engine.tick(at: t0.addingTimeInterval(10))
        #expect(engine.canUnlock == false)
        #expect(engine.smoothedRSSI == nil)
    }

    @Test func unlockDisabledMeansNoArrival() {
        var s = settings
        s.unlockRSSI = nil
        var engine = PresenceEngine(settings: s, now: t0)
        let changes = feed(&engine, [-40, -40, -40, -40], from: 0)
        #expect(engine.presence == .near)
        #expect(engine.canUnlock == false)
        #expect(arrivals(changes) == 0)
    }

    @Test("樣本稀疏（手錶放下時約 5 秒一筆）也能判定回來")
    func sparseSamplesStillArrive() {
        var engine = PresenceEngine(settings: settings, now: t0)
        feed(&engine, Array(repeating: -85, count: 16), from: 0)
        #expect(engine.presence != .near)
        let changes = feed(&engine, [-55, -56, -54], from: 20, every: 5)
        #expect(engine.presence == .near)
        #expect(engine.canUnlock)
        #expect(arrivals(changes) == 1)
    }

    @Test("稀疏時間隔太久（超過 12 秒湊不到 3 筆）不算")
    func tooSparseDoesNotArrive() {
        var engine = PresenceEngine(settings: settings, now: t0)
        feed(&engine, Array(repeating: -85, count: 16), from: 0)
        let changes = feed(&engine, [-55, -55, -55], from: 20, every: 7)
        #expect(arrivals(changes) == 0)
        #expect(engine.canUnlock == false)
    }

    @Test("稀疏時單一筆強訊號也不能解鎖")
    func sparseSingleSpikeDoesNotArrive() {
        var engine = PresenceEngine(settings: settings, now: t0)
        feed(&engine, Array(repeating: -85, count: 16), from: 0)
        let changes = feed(&engine, [-85, -40, -85], from: 20, every: 4)
        #expect(arrivals(changes) == 0)
        #expect(engine.canUnlock == false)
    }

    @Test("稀疏時最新一筆要是剛收到的：停止收到訊號後，舊的強訊號不算")
    func sparseEvidenceMustBeFresh() throws {
        var engine = PresenceEngine(settings: settings, now: t0)
        feed(&engine, [-50, -50, -50], from: 0, every: 4)
        try #require(engine.canUnlock)
        engine.tick(at: t0.addingTimeInterval(8 + 5))
        #expect(engine.canUnlock == false)
    }

    @Test func startingFarAwayCountsDownToLock() {
        var engine = PresenceEngine(settings: settings, now: t0)
        let changes = feed(&engine, Array(repeating: -90, count: 16), from: 0)
        #expect(departures(changes) == [.weakSignal])
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
