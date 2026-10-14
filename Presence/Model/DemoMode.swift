import Foundation
import PresenceCore
import PresenceLink

/// 示範模式（開發版加 `-PresenceDemo YES` 啟動）：假裝置、模擬訊號，給截圖與宣傳影片用。
///
/// 不接手正在執行的 Presence，不讀寫真正的設定、事件紀錄、在座時間、密碼與登入項目，
/// 也不真的鎖定或解鎖螢幕（鎖定狀態只存在 `ScreenSession.demoLocked`）。
/// 加 `-PresenceDemoScript YES` 會照腳本離開再回來（見 `targetRSSI`）。
nonisolated enum Demo {
    #if DEBUG
    static let isActive = UserDefaults.standard.bool(forKey: "PresenceDemo")
    #else
    static let isActive = false
    #endif
}

#if DEBUG
@MainActor
extension Demo {
    static let runsScript = UserDefaults.standard.bool(forKey: "PresenceDemoScript")

    static let iPhoneID = UUID(uuidString: "42857EBD-9CF8-4C86-BDA2-2A8D18C603C7")!
    static let watchID = UUID(uuidString: "CCF09853-188B-46B0-80A2-E2E5625A7B91")!
    static let pairingID = UUID(uuidString: "F7E5176C-86AF-4201-956E-A7C19F28CCC9")!
    static let macName = "MacBook Pro"

    /// 示範用的設定存在另一個網域，每次啟動清空，不會動到真正的設定。
    static let defaults: UserDefaults = {
        let name = "com.chung.presence.demo"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }()

    private static var isChinese: Bool { Locale.preferredLanguages.first?.hasPrefix("zh") == true }

    static var preferences: Preferences {
        var prefs = Preferences()
        prefs.devices = [
            MonitoredDevice(id: iPhoneID, name: "iPhone", unlockRSSI: -62, lockRSSI: -76),
            MonitoredDevice(id: watchID, name: "Apple Watch", unlockRSSI: -66, lockRSSI: -80),
        ]
        prefs.lockDelay = 4
        prefs.lockHotKey = try? JSONDecoder().decode(HotKey.self, from: Data(#"{"keyCode":37,"modifiers":4352,"display":"⌃⌘L"}"#.utf8))
        prefs.context.trustedNetworks = [.init(id: "a4:83:e7:2b:41:0c", name: isChinese ? "家裡" : "Home")]
        return prefs
    }

    static let nearby: [BluetoothMonitor.NearbyDevice] = [
        .init(id: iPhoneID, name: "iPhone", rssi: -52, lastSeen: Date()),
        .init(id: watchID, name: "Apple Watch", rssi: -58, lastSeen: Date()),
        .init(id: UUID(uuidString: "72216564-2DF0-4B06-B5BF-A8F19001B529")!, name: "Magic Keyboard", rssi: -49, lastSeen: Date()),
        .init(id: UUID(uuidString: "85B4E7F7-84E7-4914-8875-9E7A71A49C30")!, name: "AirPods Pro", rssi: -67, lastSeen: Date()),
        .init(id: UUID(uuidString: "C4CA8BA1-986C-4CB5-A729-56D7E66D9A2E")!, name: "iPad", rssi: -74, lastSeen: Date()),
    ]

    static var pairedDevices: [PairedDevice] {
        [PairedDevice(id: pairingID, name: "iPhone", createdAt: Date().addingTimeInterval(-6 * 86400), lastSeen: Date())]
    }

    /// 平常的訊號強度；腳本模式下照時間離開再回來。nil 表示這一刻收不到。
    static func targetRSSI(for id: UUID, elapsed t: TimeInterval) -> Int? {
        let near = id == iPhoneID ? -52 : -58
        let far = id == iPhoneID ? -90 : -94
        guard runsScript else { return near }
        func ramp(_ from: Int, _ to: Int, _ start: TimeInterval, _ length: TimeInterval) -> Int {
            from + Int((Double(to - from) * min(1, max(0, (t - start) / length))).rounded())
        }
        switch t {
        case ..<10: return near
        case ..<16: return ramp(near, far, 10, 6)
        case ..<34: return Bool.random() ? far : nil
        case ..<38: return ramp(far, near, 34, 4)
        default: return near
        }
    }

    /// 過去一週的在座時間，今天這一段從 48 分鐘前開始。
    static func deskTime(now: Date) -> DeskTime {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: now)
        var sessions: [[String: Double]] = []
        func add(_ day: Date, _ start: Double, _ end: Double) {
            sessions.append(["start": day.addingTimeInterval(start * 3600).timeIntervalSinceReferenceDate,
                             "end": day.addingTimeInterval(end * 3600).timeIntervalSinceReferenceDate])
        }
        let pattern: [[(Double, Double)]] = [
            [(9.2, 10.9), (11.1, 12.3), (13.4, 15.6), (15.8, 17.9)],
            [(9.5, 11.8), (13.2, 14.4), (14.6, 18.1)],
            [(10.0, 12.1), (13.5, 16.2)],
            [(9.0, 10.2), (10.4, 12.4), (13.1, 17.3)],
            [(9.4, 11.6), (13.0, 15.1), (15.3, 16.8)],
            [(10.3, 12.0), (14.0, 15.4)],
        ]
        for (offset, ranges) in pattern.enumerated() {
            guard let day = calendar.date(byAdding: .day, value: -(offset + 1), to: today) else { continue }
            ranges.forEach { add(day, $0.0, $0.1) }
        }
        let current = now.addingTimeInterval(-48 * 60)
        for (start, end) in [(-5.6, -4.1), (-3.9, -2.2)] {
            let s = now.addingTimeInterval(start * 3600), e = now.addingTimeInterval(end * 3600)
            if s >= today { sessions.append(["start": s.timeIntervalSinceReferenceDate, "end": e.timeIntervalSinceReferenceDate]) }
        }
        let json: [String: Any] = [
            "sessions": sessions,
            "currentStart": max(current, today).timeIntervalSinceReferenceDate,
            "lastSeenNear": now.timeIntervalSinceReferenceDate,
            "remindersInSession": 0,
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        return (try? JSONDecoder().decode(DeskTime.self, from: data)) ?? DeskTime()
    }

    /// 事件紀錄：今天幾次離開、回來、從 iPhone 鎖定。訊息和 AppModel 用同一組字串，才有翻譯。
    static func logEntries(now: Date) -> [EventLog.Entry] {
        let both = AppModel.list(["iPhone", "Apple Watch"])
        let all = String(localized: "所有裝置")
        func at(_ minutesAgo: Double) -> Date { now.addingTimeInterval(-minutesAgo * 60) }
        return [
            .init(date: at(338), kind: .info, message: String(localized: "Presence 已啟動")),
            .init(date: at(246), kind: .locked, message: String(localized: "\(all) 離開了，已自動鎖定")),
            .init(date: at(234), kind: .unlocked, message: String(localized: "\(both) 在附近，\("iPhone") 已加密確認，已自動解鎖")),
            .init(date: at(132), kind: .locked, message: String(localized: "\(all) 離開了，已自動鎖定")),
            .init(date: at(77), kind: .unlocked, message: String(localized: "\(both) 在附近，\("iPhone") 已加密確認，已自動解鎖")),
            .init(date: at(52), kind: .info, message: String(localized: "收到 iPhone 或 Apple Watch 的鎖定指令")),
            .init(date: at(52), kind: .locked, message: String(localized: "手動鎖定")),
            .init(date: at(48), kind: .unlocked, message: String(localized: "\(both) 在附近，已由 Apple Watch 或 Touch ID 解鎖")),
        ]
    }
}
#endif
