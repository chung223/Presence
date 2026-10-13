@preconcurrency import CoreBluetooth
import Observation
import SwiftUI

/// 可行性驗證：Apple Watch 直接當藍牙中央端連 Mac，打開就自動送 ping。
@main
struct WatchSpikeApp: App {
    @State private var link = WatchLink()

    var body: some Scene {
        WindowGroup {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    Text(link.state).font(.headline)
                    Button("再送一次 ping") { link.ping() }
                    ForEach(link.lines.reversed(), id: \.self) { Text($0).font(.caption2) }
                }
            }
        }
    }
}

@Observable
final class WatchLink: NSObject {
    static let serviceUUID = CBUUID(string: "5B1D0001-6A1F-4C7E-9E43-2F0B7C1A8D10")
    static let commandUUID = CBUUID(string: "5B1D0002-6A1F-4C7E-9E43-2F0B7C1A8D10")
    static let statusUUID = CBUUID(string: "5B1D0003-6A1F-4C7E-9E43-2F0B7C1A8D10")

    private(set) var state = "啟動中"
    private(set) var lines: [String] = []
    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var command: CBCharacteristic?
    @ObservationIgnored private var start = Date()
    @ObservationIgnored private var sentAt: Date?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func ping() {
        guard let peripheral, let command else { return }
        sentAt = Date()
        peripheral.writeValue(Data("ping from watch".utf8), for: command, type: .withResponse)
    }

    @ObservationIgnored private var connectTimeout: Task<Void, Never>?
    @ObservationIgnored private let logURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("watch-log.txt")

    private func note(_ text: String) {
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        lines.append("\(ms)ms \(text)")
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        let line = Data("\(f.string(from: Date())) \(text)\n".utf8)
        if let h = try? FileHandle(forWritingTo: logURL) {
            _ = try? h.seekToEnd(); try? h.write(contentsOf: line); try? h.close()
        } else {
            try? line.write(to: logURL)
        }
    }

    /// 15 秒連不上就取消、重新搜尋
    private func connect(_ p: CBPeripheral) {
        state = "連線中"
        note("開始連線（\(p.identifier.uuidString.prefix(8))）")
        central.connect(p)
        connectTimeout?.cancel()
        connectTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, p.state != .connected else { return }
            self.note("15 秒連不上（狀態 \(p.state.rawValue)），取消後重試")
            self.central.cancelPeripheralConnection(p)
            self.state = "重試中"
            self.central.scanForPeripherals(withServices: [Self.serviceUUID])
        }
    }
}

extension WatchLink: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let s = central.state
        MainActor.assumeIsolated {
            note("藍牙狀態 \(s.rawValue)")
            if s == .poweredOn {
                state = "搜尋 Mac"
                central.scanForPeripherals(withServices: [Self.serviceUUID])
            } else if s == .unauthorized {
                state = "沒有藍牙權限"
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let rssi = RSSI.intValue
        MainActor.assumeIsolated {
            note("找到 Presence \(rssi)dBm")
            central.stopScan()
            self.peripheral = peripheral
            peripheral.delegate = self
            connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            connectTimeout?.cancel()
            note("已連線")
            peripheral.discoverServices([Self.serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let message = error?.localizedDescription ?? "無錯誤訊息"
        MainActor.assumeIsolated {
            note("連線失敗：\(message)")
            state = "連線失敗"
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let message = error?.localizedDescription ?? "正常斷線"
        MainActor.assumeIsolated { note("斷線：\(message)") }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else { return }
            peripheral.discoverCharacteristics([Self.commandUUID, Self.statusUUID], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for c in service.characteristics ?? [] {
                if c.uuid == Self.commandUUID { command = c }
                if c.uuid == Self.statusUUID { peripheral.setNotifyValue(true, for: c) }
            }
            state = "已連線"
            ping()
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let ok = error == nil
        MainActor.assumeIsolated {
            let ms = sentAt.map { Int(Date().timeIntervalSince($0) * 1000) } ?? -1
            note(ok ? "Mac 已收到 ping（\(ms)ms）" : "送出失敗")
            state = ok ? "✅ Mac 已收到" : "送出失敗"
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let text = characteristic.value.flatMap { String(data: $0, encoding: .utf8) } ?? ""
        MainActor.assumeIsolated { note("Mac：\(text)") }
    }
}
