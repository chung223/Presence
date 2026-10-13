import Foundation
import Testing
@testable import PresenceCore

struct ContextRulesTests {
    let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Taipei")!
        return c
    }()

    /// 2026-10-12 是星期一。
    func date(day: Int = 12, hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func env(network: String? = nil, ac: Bool? = nil, at date: Date) -> ContextRules.Environment {
        .init(networkID: network, onACPower: ac, date: date, calendar: calendar)
    }

    @Test func emptyRulesNeverSuspend() {
        let rules = ContextRules()
        #expect(rules.isEmpty)
        #expect(rules.suspension(in: env(network: "aa:bb", ac: true, at: date(hour: 3))) == nil)
    }

    @Test func trustedNetworkSuspends() {
        var rules = ContextRules()
        rules.trustedNetworks = [.init(id: "aa:bb:cc", name: "家裡")]
        #expect(rules.suspension(in: env(network: "aa:bb:cc", at: date(hour: 10))) == .trustedNetwork("家裡"))
        #expect(rules.suspension(in: env(network: "11:22:33", at: date(hour: 10))) == nil)
        #expect(rules.suspension(in: env(network: nil, at: date(hour: 10))) == nil)
    }

    @Test(arguments: [(Optional(true), true), (Optional(false), false), (nil, false)] as [(Bool?, Bool)])
    func onlyOnBatterySuspendsWhenPluggedIn(ac: Bool?, suspended: Bool) {
        var rules = ContextRules()
        rules.onlyOnBattery = true
        #expect((rules.suspension(in: env(ac: ac, at: date(hour: 10))) == .onACPower) == suspended)
    }

    @Test(arguments: [(9, 0, true), (17, 59, true), (18, 0, false), (8, 59, false)])
    func scheduleOnWeekday(hour: Int, minute: Int, within: Bool) {
        var rules = ContextRules()
        rules.scheduleEnabled = true
        #expect(rules.isWithinSchedule(date(hour: hour, minute: minute), calendar: calendar) == within)
    }

    @Test func scheduleExcludesWeekend() {
        var rules = ContextRules()
        rules.scheduleEnabled = true
        // 2026-10-11 是星期日
        #expect(rules.suspension(in: env(at: date(day: 11, hour: 10))) == .outsideSchedule)
    }

    @Test("跨過午夜的時段：週一 22:00 到週二 06:00")
    func overnightSchedule() {
        var rules = ContextRules()
        rules.scheduleEnabled = true
        rules.scheduleStart = 22 * 60
        rules.scheduleEnd = 6 * 60
        rules.weekdays = [2] // 只有星期一開始的時段
        #expect(rules.isWithinSchedule(date(day: 12, hour: 23), calendar: calendar))
        #expect(rules.isWithinSchedule(date(day: 13, hour: 5), calendar: calendar), "星期二凌晨仍屬於星期一晚上的時段")
        #expect(rules.isWithinSchedule(date(day: 13, hour: 23), calendar: calendar) == false)
        #expect(rules.isWithinSchedule(date(day: 12, hour: 12), calendar: calendar) == false)
    }

    @Test("星期一天都沒選時視為每天，不會變成永遠不鎖定")
    func emptyWeekdaysMeansEveryDay() {
        var rules = ContextRules()
        rules.scheduleEnabled = true
        rules.weekdays = []
        #expect(rules.suspension(in: env(at: date(day: 11, hour: 10))) == nil)
        #expect(rules.suspension(in: env(at: date(day: 11, hour: 20))) == .outsideSchedule)
    }

    @Test func trustedNetworkTakesPriority() {
        var rules = ContextRules()
        rules.trustedNetworks = [.init(id: "aa", name: "辦公室")]
        rules.onlyOnBattery = true
        #expect(rules.suspension(in: env(network: "aa", ac: true, at: date(hour: 10))) == .trustedNetwork("辦公室"))
    }

    @Test func decodesMissingFieldsWithDefaults() throws {
        let rules = try JSONDecoder().decode(ContextRules.self, from: Data(#"{"onlyOnBattery":true}"#.utf8))
        #expect(rules.onlyOnBattery)
        #expect(rules.weekdays == [2, 3, 4, 5, 6])
    }
}
