import Foundation
import Testing
@testable import PresenceCore

struct DeskTimeTests {
    let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return c
    }()

    func at(_ hour: Int, _ minute: Int = 0, day: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    /// 每 10 秒更新一次，從 from 到 to。
    func run(_ desk: inout DeskTime, near: Bool, from: Date, to: Date) {
        var t = from
        while t < to {
            desk.update(near: near, at: t)
            t.addTimeInterval(10)
        }
    }

    @Test func countsContinuousTimeNear() {
        var desk = DeskTime()
        run(&desk, near: true, from: at(9), to: at(10))
        #expect(abs(desk.currentDuration(at: at(10)) - 3600) < 20)
        #expect(abs(desk.total(on: at(9), calendar: calendar, now: at(10)) - 3600) < 20)
    }

    @Test("短暫離開（不到 3 分鐘）算同一段")
    func shortBreakKeepsTheSession() {
        var desk = DeskTime()
        run(&desk, near: true, from: at(9), to: at(9, 30))
        run(&desk, near: false, from: at(9, 30), to: at(9, 32))
        run(&desk, near: true, from: at(9, 32), to: at(10))
        #expect(desk.sessions.isEmpty)
        #expect(desk.currentDuration(at: at(10)) >= 3590)
    }

    @Test func longBreakEndsTheSession() throws {
        var desk = DeskTime()
        run(&desk, near: true, from: at(9), to: at(9, 30))
        run(&desk, near: false, from: at(9, 30), to: at(9, 40))
        let session = try #require(desk.sessions.last)
        #expect(desk.currentStart == nil)
        #expect(abs(session.duration - 1800) < 20, "結束時間記在最後一次在附近，而不是判定離開的那一刻")
    }

    @Test func remindsOncePerInterval() {
        var desk = DeskTime()
        var reminders = 0
        var t = at(9)
        while t < at(11, 5) {
            desk.update(near: true, at: t)
            if desk.shouldRemind(every: 3600, at: t) { reminders += 1 }
            t.addTimeInterval(10)
        }
        #expect(reminders == 2, "9 點坐到 11 點多，滿 1 小時、2 小時各提醒一次")
    }

    @Test func reminderCountResetsAfterARealBreak() {
        var desk = DeskTime()
        var reminders = 0
        for (near, from, to) in [(true, at(9), at(10, 1)), (false, at(10, 1), at(10, 15)), (true, at(10, 15), at(11, 16))] {
            var t = from
            while t < to {
                desk.update(near: near, at: t)
                if desk.shouldRemind(every: 3600, at: t) { reminders += 1 }
                t.addTimeInterval(10)
            }
        }
        #expect(reminders == 2)
    }

    @Test func totalsAreSplitAtMidnight() {
        var desk = DeskTime()
        run(&desk, near: true, from: at(23), to: at(1, day: 13))
        run(&desk, near: false, from: at(1, day: 13), to: at(1, 10, day: 13))
        #expect(abs(desk.total(on: at(12), calendar: calendar, now: at(2, day: 13)) - 3600) < 20)
        #expect(abs(desk.total(on: at(12, day: 13), calendar: calendar, now: at(2, day: 13)) - 3600) < 20)
    }

    @Test func roundTripsThroughJSON() throws {
        var desk = DeskTime()
        run(&desk, near: true, from: at(9), to: at(9, 30))
        run(&desk, near: false, from: at(9, 30), to: at(9, 40))
        let decoded = try JSONDecoder().decode(DeskTime.self, from: JSONEncoder().encode(desk))
        #expect(decoded == desk)
    }
}
