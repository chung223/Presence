@preconcurrency import CoreBluetooth // 回呼都在主執行緒（queue: nil）
import Foundation
import os

/// 讓 iPhone 和 Apple Watch 的配套 App 連進來：Mac 當藍牙週邊，廣播 Presence 的服務。
///
/// 目前是可行性驗證版（啟動參數 `-PresenceLinkSpike YES` 才開啟）：
/// 收到的指令只記錄、回覆確認，不會真的鎖定；每 30 秒送一次心跳，螢幕鎖定或解鎖時也通知。
/// 紀錄寫在 ~/Library/Logs/Presence/link-spike.log。
final class LinkPeripheral: NSObject {
    static let serviceUUID = CBUUID(string: "5B1D0001-6A1F-4C7E-9E43-2F0B7C1A8D10")
    static let commandUUID = CBUUID(string: "5B1D0002-6A1F-4C7E-9E43-2F0B7C1A8D10")
    static let statusUUID = CBUUID(string: "5B1D0003-6A1F-4C7E-9E43-2F0B7C1A8D10")

    private var manager: CBPeripheralManager?
    private var status: CBMutableCharacteristic?
    private var subscribers: [CBCentral] = []
    private var heartbeat: Task<Void, Never>?
    private let log = SpikeFileLog(name: "link-spike.log")

    func start() {
        guard manager == nil else { return }
        manager = CBPeripheralManager(delegate: self, queue: nil)
        log.write("啟動週邊服務")
        heartbeat = Task { [weak self] in
            var count = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                count += 1
                self?.send("heartbeat \(count)")
            }
        }
    }

    /// 螢幕鎖定、解鎖等事件，通知已訂閱的裝置。
    func send(_ message: String) {
        guard let manager, let status, !subscribers.isEmpty else { return }
        let data = Data("\(message) @ \(Self.timestamp())".utf8)
        let ok = manager.updateValue(data, for: status, onSubscribedCentrals: nil)
        log.write("通知 \(subscribers.count) 台：\(message)\(ok ? "" : "（佇列已滿，稍後重送）")")
    }

    private func setUpService() {
        let command = CBMutableCharacteristic(type: Self.commandUUID, properties: [.write, .writeWithoutResponse],
                                              value: nil, permissions: [.writeable])
        let status = CBMutableCharacteristic(type: Self.statusUUID, properties: [.read, .notify],
                                             value: nil, permissions: [.readable])
        self.status = status
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [command, status]
        manager?.add(service)
    }

    private func received(_ text: String, from central: CBCentral) {
        log.write("收到指令「\(text)」，來自 \(central.identifier.uuidString.prefix(8))")
        send("ack \(text)")
    }

    private static func timestamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: Date())
    }
}

extension LinkPeripheral: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        let state = peripheral.state
        MainActor.assumeIsolated {
            log.write("週邊狀態 \(state.rawValue)")
            if state == .poweredOn { setUpService() }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            if let error {
                log.write("加入服務失敗：\(error.localizedDescription)")
                return
            }
            peripheral.startAdvertising([
                CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
                CBAdvertisementDataLocalNameKey: "Presence",
            ])
        }
    }

    nonisolated func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        MainActor.assumeIsolated {
            log.write(error.map { "廣播失敗：\($0.localizedDescription)" } ?? "開始廣播")
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        nonisolated(unsafe) let requests = requests // 回呼本來就在主執行緒
        MainActor.assumeIsolated {
            for request in requests {
                let text = request.value.flatMap { String(data: $0, encoding: .utf8) } ?? "（無法解讀）"
                received(text, from: request.central)
            }
            if let first = requests.first { peripheral.respond(to: first, withResult: .success) }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        MainActor.assumeIsolated {
            request.value = Data("status ok @ \(Self.timestamp())".utf8)
            peripheral.respond(to: request, withResult: .success)
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        MainActor.assumeIsolated {
            subscribers.append(central)
            log.write("\(central.identifier.uuidString.prefix(8)) 訂閱狀態（共 \(subscribers.count) 台）")
            send("hello")
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        MainActor.assumeIsolated {
            subscribers.removeAll { $0.identifier == central.identifier }
            log.write("\(central.identifier.uuidString.prefix(8)) 取消訂閱（剩 \(subscribers.count) 台）")
        }
    }

    nonisolated func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        MainActor.assumeIsolated { log.write("佇列可再送出") }
    }
}

/// 驗證用的簡單文字紀錄。
struct SpikeFileLog {
    private let url: URL?
    private let logger = Logger(subsystem: "com.chung.presence", category: "link")

    init(name: String) {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Presence")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent(name)
    }

    func write(_ message: String) {
        logger.info("\(message, privacy: .public)")
        guard let url else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        let line = Data("\(f.string(from: Date())) \(message)\n".utf8)
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }
}
