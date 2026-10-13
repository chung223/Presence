import Foundation
import Testing
@testable import PresenceCore

struct AutomationTests {
    let t0 = Date(timeIntervalSinceReferenceDate: 0)

    @Test func attemptsUnlockWhenCloseAndLocked() {
        let automation = Automation()
        #expect(automation.shouldAttemptUnlock(canUnlock: true, screenLocked: true, at: t0))
    }

    @Test(arguments: [(false, true), (true, false), (false, false)])
    func doesNotAttemptWithoutEvidenceOrLock(canUnlock: Bool, screenLocked: Bool) {
        let automation = Automation()
        #expect(automation.shouldAttemptUnlock(canUnlock: canUnlock, screenLocked: screenLocked, at: t0) == false)
    }

    @Test("手動鎖定後，短暫訊號變弱不會解除保留", .bug("https://github.com/ts1/BLEUnlock/issues/137"))
    func manualLockSurvivesBriefDeparture() {
        var automation = Automation()
        automation.didLockManually(at: t0)
        automation.observe(.away(.weakSignal, since: t0), rearm: 30, at: t0.addingTimeInterval(10))
        #expect(automation.shouldAttemptUnlock(canUnlock: true, screenLocked: true, at: t0.addingTimeInterval(11)) == false)
    }

    @Test func manualLockIsReleasedAfterBeingAwayLongEnough() {
        var automation = Automation()
        automation.didLockManually(at: t0)
        automation.observe(.away(.signalLost, since: t0), rearm: 30, at: t0.addingTimeInterval(30))
        #expect(automation.manualHold == false)
    }

    @Test("早在手動鎖定之前就離開的時間不算數")
    func awayTimeBeforeManualLockDoesNotCount() {
        var automation = Automation()
        automation.didLockManually(at: t0.addingTimeInterval(100))
        automation.observe(.away(.signalLost, since: t0), rearm: 30, at: t0.addingTimeInterval(101))
        #expect(automation.manualHold)
        automation.observe(.away(.signalLost, since: t0), rearm: 30, at: t0.addingTimeInterval(130))
        #expect(automation.manualHold == false)
    }

    @Test func manualLockIsReleasedWhenScreenUnlocks() {
        var automation = Automation()
        automation.didLockManually(at: t0)
        automation.screenDidUnlock()
        #expect(automation.manualHold == false)
    }

    @Test func cooldownBetweenAttempts() {
        var automation = Automation()
        automation.didAttemptUnlock(at: t0)
        #expect(automation.shouldAttemptUnlock(canUnlock: true, screenLocked: true, at: t0.addingTimeInterval(5)) == false)
        #expect(automation.shouldAttemptUnlock(canUnlock: true, screenLocked: true, at: t0.addingTimeInterval(10)))
    }

    @Test("密碼錯誤時，手動解鎖不會讓失敗次數歸零")
    func failuresSurviveManualUnlock() {
        var automation = Automation()
        automation.unlockAttemptFailed()
        automation.unlockAttemptFailed()
        #expect(automation.shouldAttemptUnlock(canUnlock: true, screenLocked: true, at: t0) == false)
        automation.screenDidUnlock()
        #expect(automation.shouldAttemptUnlock(canUnlock: true, screenLocked: true, at: t0) == false)
        automation.resetFailures()
        #expect(automation.shouldAttemptUnlock(canUnlock: true, screenLocked: true, at: t0))
    }

    @Test func successfulUnlockClearsFailures() {
        var automation = Automation()
        automation.unlockAttemptFailed()
        automation.unlockSucceeded()
        automation.unlockAttemptFailed()
        #expect(automation.isBlockedByFailures == false)
    }

    @Test func pauseBlocksLockAndUnlockUntilItEnds() {
        var automation = Automation()
        automation.pause(until: t0.addingTimeInterval(3600))
        #expect(automation.shouldLock(lockEnabled: true, screenLocked: false, at: t0) == false)
        #expect(automation.shouldAttemptUnlock(canUnlock: true, screenLocked: true, at: t0) == false)
        let later = t0.addingTimeInterval(3600)
        #expect(automation.shouldLock(lockEnabled: true, screenLocked: false, at: later))
    }

    @Test(arguments: [(false, false), (true, true)])
    func doesNotLockWhenDisabledOrAlreadyLocked(lockEnabled: Bool, screenLocked: Bool) {
        #expect(Automation().shouldLock(lockEnabled: lockEnabled, screenLocked: screenLocked, at: t0) == false)
    }
}
