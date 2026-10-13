@preconcurrency import CoreBluetooth // 回呼都在主執行緒（queue: nil），CBPeripheral 沒標 Sendable
import Foundation
import Observation
import PresenceCore

/// 持續掃描附近的 BLE 裝置。目標裝置的每一筆訊號都交給 `onSample`。
/// 主動模式下另外連線到目標裝置，每 2 秒讀一次 RSSI（較穩定，但可能干擾其他藍牙設備）。
@Observable
final class BluetoothMonitor: NSObject {
    struct NearbyDevice: Identifiable, Equatable {
        let id: UUID
        var name: String?
        var rssi: Int
        var lastSeen: Date
    }

    enum Availability: Equatable {
        case unknown, poweredOn, poweredOff, unauthorized, unsupported, resetting

        var description: String {
            switch self {
            case .unknown: "正在啟動"
            case .poweredOn: "已開啟"
            case .poweredOff: "已關閉"
            case .unauthorized: "沒有藍牙權限"
            case .unsupported: "這台 Mac 不支援"
            case .resetting: "重新啟動中"
            }
        }
    }

    enum ConnectionState: Equatable {
        case off, waiting, connecting, connected
    }

    private(set) var availability: Availability = .unknown
    private(set) var nearby: [NearbyDevice] = []
    private(set) var connection: ConnectionState = .off

    /// 目標裝置每收到一筆訊號就呼叫一次。
    @ObservationIgnored var onSample: ((Int, Date) -> Void)?
    @ObservationIgnored var onAvailabilityChange: ((Availability) -> Void)?
    /// 第一次看到目標裝置的名稱時呼叫，用來記住名稱。
    @ObservationIgnored var onTargetName: ((String) -> Void)?

    var target: UUID? {
        didSet {
            guard target != oldValue else { return }
            disconnectTarget()
            targetPeripheral = nil
            if activeMode { connection = .waiting }
        }
    }

    var activeMode = false {
        didSet {
            guard activeMode != oldValue else { return }
            if activeMode {
                connection = .waiting
                startPolling()
            } else {
                pollTask?.cancel()
                pollTask = nil
                disconnectTarget()
                connection = .off
            }
        }
    }

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var devices: [UUID: NearbyDevice] = [:]
    @ObservationIgnored private var targetPeripheral: CBPeripheral?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var publishTask: Task<Void, Never>?

    func start() {
        guard central == nil else { return }
        central = CBCentralManager(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        publishTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self?.publish()
            }
        }
    }

    // MARK: - 內部

    private func publish() {
        let cutoff = Date().addingTimeInterval(-30)
        devices = devices.filter { $0.value.lastSeen > cutoff }
        let sorted = devices.values.sorted { $0.rssi > $1.rssi }
        if sorted != nearby { nearby = sorted }
    }

    private func setAvailability(_ state: CBManagerState) {
        let new: Availability = switch state {
        case .poweredOn: .poweredOn
        case .poweredOff: .poweredOff
        case .unauthorized: .unauthorized
        case .unsupported: .unsupported
        case .resetting: .resetting
        default: .unknown
        }
        guard new != availability else { return }
        availability = new
        if new == .poweredOn {
            central?.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        } else {
            targetPeripheral = nil
            if activeMode { connection = .waiting }
        }
        onAvailabilityChange?(new)
    }

    private func discovered(_ peripheral: CBPeripheral, name: String?, rssi: Int) {
        guard RSSIWindow.isValid(rssi) else { return }
        let id = peripheral.identifier
        let now = Date()
        var device = devices[id] ?? NearbyDevice(id: id, rssi: rssi, lastSeen: now)
        if device.name == nil, let name { device.name = name }
        device.rssi = rssi
        device.lastSeen = now
        devices[id] = device

        guard id == target else { return }
        if targetPeripheral == nil, let name = device.name { onTargetName?(name) }
        targetPeripheral = peripheral
        onSample?(rssi, now)
        if activeMode, peripheral.state == .disconnected { connect(peripheral) }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func poll() {
        guard availability == .poweredOn, let p = targetPeripheral else { return }
        switch p.state {
        case .connected: p.readRSSI()
        case .disconnected: connect(p)
        default: break
        }
    }

    private func connect(_ p: CBPeripheral) {
        p.delegate = self
        connection = .connecting
        central?.connect(p)
    }

    private func disconnectTarget() {
        if let p = targetPeripheral, p.state != .disconnected {
            central?.cancelPeripheralConnection(p)
        }
    }
}

// CoreBluetooth 的 queue 是 nil，所有回呼都在主執行緒。
extension BluetoothMonitor: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state
        MainActor.assumeIsolated { setAvailability(state) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let local = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = [peripheral.name, local]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .first { $0.isEmpty == false }
        let rssi = RSSI.intValue
        MainActor.assumeIsolated { discovered(peripheral, name: name, rssi: rssi) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard peripheral.identifier == target else { return }
            connection = .connected
            peripheral.readRSSI()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral.identifier == target, activeMode else { return }
            connection = .waiting
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral.identifier == target, activeMode else { return }
            connection = .waiting
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        let rssi = RSSI.intValue
        MainActor.assumeIsolated {
            guard peripheral.identifier == target, RSSIWindow.isValid(rssi) else { return }
            onSample?(rssi, Date())
        }
    }
}
