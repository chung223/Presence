@preconcurrency import CoreBluetooth // 回呼都在主執行緒（queue: nil），CBPeripheral 沒標 Sendable
import Foundation
import Observation
import PresenceCore

/// 持續掃描附近的 BLE 裝置。監控中的裝置每收到一筆訊號就交給 `onSample`。
/// 主動模式下另外連線到監控中的裝置，每 2 秒讀一次 RSSI（較穩定，但可能干擾其他藍牙設備）。
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
        case waiting, connecting, connected
    }

    private(set) var availability: Availability = .unknown
    private(set) var nearby: [NearbyDevice] = []
    /// 主動模式下每台監控裝置的連線狀態。
    private(set) var connections: [UUID: ConnectionState] = [:]

    @ObservationIgnored var onSample: ((UUID, Int, Date) -> Void)?
    @ObservationIgnored var onAvailabilityChange: ((Availability) -> Void)?
    /// 監控中的裝置第一次出現名稱時呼叫，用來記住名稱。
    @ObservationIgnored var onTargetName: ((UUID, String) -> Void)?

    var targets: Set<UUID> = [] {
        didSet {
            guard targets != oldValue else { return }
            for id in oldValue.subtracting(targets) {
                if let p = peripherals.removeValue(forKey: id) { disconnect(p) }
                connections[id] = nil
            }
            if activeMode {
                for id in targets.subtracting(oldValue) { connections[id] = .waiting }
            }
        }
    }

    var activeMode = false {
        didSet {
            guard activeMode != oldValue else { return }
            if activeMode {
                connections = Dictionary(uniqueKeysWithValues: targets.map { ($0, .waiting) })
                startPolling()
            } else {
                pollTask?.cancel()
                pollTask = nil
                peripherals.values.forEach(disconnect)
                connections = [:]
            }
        }
    }

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private var devices: [UUID: NearbyDevice] = [:]
    @ObservationIgnored private var peripherals: [UUID: CBPeripheral] = [:]
    @ObservationIgnored private var namedTargets: Set<UUID> = []
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
            peripherals.removeAll()
            if activeMode { connections = Dictionary(uniqueKeysWithValues: targets.map { ($0, .waiting) }) }
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

        guard targets.contains(id) else { return }
        if let name = device.name, !namedTargets.contains(id) {
            namedTargets.insert(id)
            onTargetName?(id, name)
        }
        peripherals[id] = peripheral
        onSample?(id, rssi, now)
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
        guard availability == .poweredOn else { return }
        for p in peripherals.values {
            switch p.state {
            case .connected: p.readRSSI()
            case .disconnected: connect(p)
            default: break
            }
        }
    }

    private func connect(_ p: CBPeripheral) {
        p.delegate = self
        connections[p.identifier] = .connecting
        central?.connect(p)
    }

    private func disconnect(_ p: CBPeripheral) {
        if p.state != .disconnected { central?.cancelPeripheralConnection(p) }
    }

    private func connectionLost(_ id: UUID) {
        guard targets.contains(id), activeMode else { return }
        connections[id] = .waiting
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
            guard targets.contains(peripheral.identifier) else { return }
            connections[peripheral.identifier] = .connected
            peripheral.readRSSI()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { connectionLost(peripheral.identifier) }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { connectionLost(peripheral.identifier) }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        guard error == nil else { return }
        let rssi = RSSI.intValue
        MainActor.assumeIsolated {
            let id = peripheral.identifier
            guard targets.contains(id), RSSIWindow.isValid(rssi) else { return }
            onSample?(id, rssi, Date())
        }
    }
}
