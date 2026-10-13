@preconcurrency import CoreBluetooth // 回呼都在主執行緒（queue: nil）
import Foundation
import Observation
import UIKit
import UserNotifications

/// 連到 Mac 上的 Presence（Mac 當藍牙週邊）。可行性驗證版：送文字指令、接收狀態通知。
/// 紀錄同時寫到 App 的 Documents/link-log.txt，方便從 Mac 取回背景期間的紀錄。
@Observable
final class LinkClient: NSObject {
    static let shared = LinkClient()

    static let serviceUUID = CBUUID(string: "5B1D0001-6A1F-4C7E-9E43-2F0B7C1A8D10")
    static let commandUUID = CBUUID(string: "5B1D0002-6A1F-4C7E-9E43-2F0B7C1A8D10")
    static let statusUUID = CBUUID(string: "5B1D0003-6A1F-4C7E-9E43-2F0B7C1A8D10")

    struct Line: Identifiable {
        let id = UUID()
        let time: String
        let text: String
    }

    enum State: String {
        case idle = "未連線", scanning = "搜尋中", connecting = "連線中", ready = "已連線"
    }

    private(set) var state: State = .idle
    private(set) var lines: [Line] = []
    private(set) var lastStatus = "—"

    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var command: CBCharacteristic?
    @ObservationIgnored private var readyWaiters: [CheckedContinuation<Bool, Never>] = []
    @ObservationIgnored private var writeWaiter: CheckedContinuation<Bool, Never>?
    @ObservationIgnored private let logURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("link-log.txt")
    private static let savedPeripheralKey = "linkPeripheral"

    override private init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: "presence-remote"])
        write("LinkClient 建立（App 狀態：\(Self.appState)）")
    }

    func connect() {
        guard central.state == .poweredOn else { return }
        // 系統冷啟動 App 時會交還仍然連著的 Mac：直接沿用，但要重新取得服務與特徵
        if let peripheral, peripheral.state == .connected {
            if state != .ready { prepare(peripheral) }
            return
        }
        if let saved = UserDefaults.standard.string(forKey: Self.savedPeripheralKey).flatMap(UUID.init),
           let known = central.retrievePeripherals(withIdentifiers: [saved]).first {
            write("用記住的 Mac 直接連線")
            connect(known)
            return
        }
        state = .scanning
        write("開始搜尋 Presence")
        central.scanForPeripherals(withServices: [Self.serviceUUID])
    }

    /// 送出指令並等 Mac 確認收到。用在 App Intent（可能在背景執行）。
    func sendAndWait(_ text: String, timeout: TimeInterval = 10) async -> String {
        let start = Date()
        if state != .ready {
            connect()
            let ready = await withTimeout(timeout) { await self.waitUntilReady() }
            guard ready == true else { return "連不上 Mac（\(Self.ms(since: start))）" }
        }
        let connectedAfter = Self.ms(since: start)
        let ok = await withTimeout(timeout) { await self.writeAndWait(text) }
        let result = ok == true ? "Mac 已收到（連線 \(connectedAfter)，共 \(Self.ms(since: start))）" : "送出失敗（\(Self.ms(since: start))）"
        write("「\(text)」→ \(result)")
        return result
    }

    func send(_ text: String) {
        Task { _ = await sendAndWait(text) }
    }

    // MARK: - 內部

    private func prepare(_ p: CBPeripheral) {
        p.delegate = self
        if let service = p.services?.first(where: { $0.uuid == Self.serviceUUID }), service.characteristics != nil {
            write("沿用系統保留的連線")
            peripheral(p, didDiscoverCharacteristicsFor: service, error: nil)
        } else {
            write("沿用系統保留的連線，重新查詢服務")
            p.discoverServices([Self.serviceUUID])
        }
    }

    private func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        state = .connecting
        central.connect(p)
    }

    private func waitUntilReady() async -> Bool {
        if state == .ready { return true }
        return await withCheckedContinuation { readyWaiters.append($0) }
    }

    private func writeAndWait(_ text: String) async -> Bool {
        guard let peripheral, let command else { return false }
        return await withCheckedContinuation { continuation in
            writeWaiter = continuation
            peripheral.writeValue(Data(text.utf8), for: command, type: .withResponse)
        }
    }

    private func setReady(_ ready: Bool) {
        state = ready ? .ready : .idle
        guard ready else { return }
        let waiters = readyWaiters
        readyWaiters = []
        waiters.forEach { $0.resume(returning: true) }
    }

    private func withTimeout(_ seconds: TimeInterval, _ operation: @escaping @MainActor () async -> Bool) async -> Bool? {
        await withTaskGroup(of: Bool?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            // 逾時後把還在等的人放掉，避免 continuation 洩漏
            if first == nil { self.failWaiters() }
            return first
        }
    }

    private func failWaiters() {
        let waiters = readyWaiters
        readyWaiters = []
        waiters.forEach { $0.resume(returning: false) }
        writeWaiter?.resume(returning: false)
        writeWaiter = nil
    }

    private func received(_ text: String) {
        lastStatus = text
        write("Mac：\(text)")
        if Self.appState != "前景", text.hasPrefix("mac locked") || text.hasPrefix("mac unlocked") {
            let content = UNMutableNotificationContent()
            content.title = "Presence"
            content.body = text.hasPrefix("mac locked") ? "你的 Mac 已鎖定" : "你的 Mac 已解鎖"
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    func write(_ text: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        let time = f.string(from: Date())
        lines.append(Line(time: time, text: text))
        if lines.count > 200 { lines.removeFirst(lines.count - 200) }
        let line = Data("\(time) [\(Self.appState)] \(text)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            try? handle.close()
        } else {
            try? line.write(to: logURL)
        }
    }

    private static var appState: String {
        switch UIApplication.shared.applicationState {
        case .active: "前景"
        case .inactive: "非作用中"
        case .background: "背景"
        @unknown default: "未知"
        }
    }

    private static func ms(since start: Date) -> String {
        "\(Int(Date().timeIntervalSince(start) * 1000)) ms"
    }
}

extension LinkClient: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        MainActor.assumeIsolated {
            write("藍牙狀態 \(state.rawValue)")
            if state == .poweredOn { connect() }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        nonisolated(unsafe) let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first
        MainActor.assumeIsolated {
            write("系統在背景喚醒 App，恢復連線狀態")
            if let restored {
                peripheral = restored
                restored.delegate = self
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let rssi = RSSI.intValue
        MainActor.assumeIsolated {
            write("找到 Presence（\(rssi) dBm）")
            central.stopScan()
            UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: Self.savedPeripheralKey)
            connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            write("已連線，查詢服務")
            peripheral.discoverServices([Self.serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            write("連線失敗：\(error?.localizedDescription ?? "")")
            setReady(false)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            write("斷線：\(error?.localizedDescription ?? "正常")")
            command = nil
            setReady(false)
            // 在背景也排一個待命連線：Mac 一回到範圍內，系統就會幫忙連上並喚醒 App
            central.connect(peripheral)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else {
                write("找不到 Presence 服務")
                return
            }
            peripheral.discoverCharacteristics([Self.commandUUID, Self.statusUUID], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for characteristic in service.characteristics ?? [] {
                if characteristic.uuid == Self.commandUUID { command = characteristic }
                if characteristic.uuid == Self.statusUUID { peripheral.setNotifyValue(true, for: characteristic) }
            }
            write(command == nil ? "找不到指令特徵" : "準備完成")
            setReady(command != nil)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let ok = error == nil
        MainActor.assumeIsolated {
            writeWaiter?.resume(returning: ok)
            writeWaiter = nil
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let text = characteristic.value.flatMap { String(data: $0, encoding: .utf8) }
        MainActor.assumeIsolated {
            if let text { received(text) }
        }
    }
}
