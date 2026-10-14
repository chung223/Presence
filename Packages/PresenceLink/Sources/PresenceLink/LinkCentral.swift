@preconcurrency import CoreBluetooth // 回呼都在主執行緒（queue: nil），CBPeripheral 沒標 Sendable
import Foundation
import Observation

/// iPhone 與 Apple Watch 用來連 Mac 上的 Presence。
///
/// - `keepConnected = true`（iPhone）：一直保持連線以接收 Mac 的通知；斷線時向系統登記待命連線，
///   Mac 回到範圍內就會自動連上，系統也會在背景叫醒 App。
/// - `keepConnected = false`（手錶）：用完就斷。Mac 當週邊同時只接受一台連線，要把連線讓回給 iPhone。
///
/// 連上後先送 hello：Mac 用同一把金鑰回覆，才算確認是自己配對的那台 Mac。
@MainActor
@Observable
public final class LinkCentral: NSObject {
    public enum State: Equatable, Sendable {
        case notPaired, bluetoothOff, unauthorized, idle, searching, connecting, connected
    }

    public enum Failure: Error, Equatable, Sendable {
        case notPaired, bluetoothUnavailable, timeout, rejected

        public var message: String {
            switch self {
            case .notPaired: String(localized: "還沒有配對 Mac", bundle: .module)
            case .bluetoothUnavailable: String(localized: "藍牙沒有開啟", bundle: .module)
            case .timeout: String(localized: "連不上 Mac，請確認 Mac 在附近、Presence 正在執行", bundle: .module)
            case .rejected: String(localized: "Mac 沒有接受這個指令", bundle: .module)
            }
        }
    }

    public private(set) var state: State = .notPaired {
        didSet {
            guard state != oldValue else { return }
            LinkLog.write("[\(deviceName)] 連線狀態：\(oldValue) → \(state)")
            onStateChange?(state)
        }
    }
    public private(set) var status: LinkStatus?
    public private(set) var lastUpdate: Date?

    /// 收到有事件的狀態（例如 Mac 已鎖定）時呼叫，用來發通知。
    @ObservationIgnored public var onEvent: ((LinkStatus) -> Void)?
    /// 每次收到狀態都呼叫，用來同步給手錶。
    @ObservationIgnored public var onStatus: ((LinkStatus) -> Void)?
    /// 連線狀態改變時呼叫，用來更新小工具。
    @ObservationIgnored public var onStateChange: ((State) -> Void)?

    public var pairing: PairingInfo? {
        didSet {
            guard pairing != oldValue else { return }
            disconnectAll()
            status = nil
            state = pairing == nil ? .notPaired : .idle
            if pairing != nil, keepConnected { connect() }
        }
    }

    public let deviceName: String
    public let keepConnected: Bool

    @ObservationIgnored private var central: CBCentralManager?
    @ObservationIgnored private let restoreIdentifier: String?
    @ObservationIgnored private var peripheral: CBPeripheral?
    @ObservationIgnored private var command: CBCharacteristic?
    @ObservationIgnored private var verified = false
    @ObservationIgnored private var helloID: UUID?
    @ObservationIgnored private var rejectedPeripherals: Set<UUID> = []
    @ObservationIgnored private var readyWaiters: [CheckedContinuation<Bool, Never>] = []
    @ObservationIgnored private var replyWaiters: [UUID: CheckedContinuation<LinkStatus?, Never>] = [:]
    @ObservationIgnored private var reassembler = LinkReassembler()
    @ObservationIgnored private var verifyTimeout: Task<Void, Never>?
    @ObservationIgnored private var idleDisconnect: Task<Void, Never>?
    #if DEBUG
    /// App Store 截圖用的示範模式：不連藍牙，指令直接改示範狀態。
    @ObservationIgnored private var demo = false
    #endif

    public init(deviceName: String, keepConnected: Bool, restoreIdentifier: String? = nil) {
        self.deviceName = deviceName
        self.keepConnected = keepConnected
        self.restoreIdentifier = restoreIdentifier
        super.init()
    }

    public func start() {
        guard central == nil else { return }
        var options: [String: Any] = [CBCentralManagerOptionShowPowerAlertKey: false]
        #if os(iOS)
        if let restoreIdentifier { options[CBCentralManagerOptionRestoreIdentifierKey] = restoreIdentifier }
        #endif
        central = CBCentralManager(delegate: self, queue: nil, options: options)
    }

    #if DEBUG
    /// 截圖用：不連藍牙，直接顯示給定的狀態（呼叫前不要 `start()`）。
    public func startDemo(pairing: PairingInfo, status: LinkStatus) {
        demo = true
        self.pairing = pairing
        self.status = status
        lastUpdate = Date()
        state = .connected
    }

    private func demoReply(to command: LinkCommand) -> LinkStatus {
        var next = status ?? LinkStatus(macName: pairing?.macName ?? "Mac", presence: .near, summary: "", locked: false)
        switch command {
        case .lock: next.locked = true
        case .pause(let minutes):
            next.pausedUntil = Date().addingTimeInterval(TimeInterval(minutes * 60))
            next.presence = .paused
        case .resume:
            next.pausedUntil = nil
            next.presence = .near
        case .hello, .status, .confirm: break
        }
        next.sentAt = Date()
        status = next
        lastUpdate = Date()
        return next
    }
    #endif

    /// 送出指令並等 Mac 回覆最新狀態。
    public func send(_ command: LinkCommand, timeout: TimeInterval = 10) async -> Result<LinkStatus, Failure> {
        guard pairing != nil else { return .failure(.notPaired) }
        #if DEBUG
        if demo { return .success(demoReply(to: command)) }
        #endif
        start()
        idleDisconnect?.cancel()
        if state != .connected {
            connect()
            guard await withTimeout(timeout, { await self.waitUntilReady() }) == true else {
                LinkLog.write("[\(deviceName)] 等不到連線就緒（藍牙 \(central?.state.rawValue ?? -1)）")
                scheduleIdleDisconnect()
                return .failure(central?.state == .poweredOn ? .timeout : .bluetoothUnavailable)
            }
        }
        let request = LinkRequest(command)
        let started = Date()
        let reply = await withTimeout(timeout) { await self.write(request) }
        scheduleIdleDisconnect()
        guard let reply = reply ?? nil else {
            LinkLog.write("[\(deviceName)] 指令 \(command) 沒有回覆")
            return .failure(.timeout)
        }
        LinkLog.write("[\(deviceName)] 指令 \(command) 完成（\(Int(Date().timeIntervalSince(started) * 1000)) ms）")
        return .success(reply)
    }

    public func disconnectAll() {
        verifyTimeout?.cancel()
        idleDisconnect?.cancel()
        if let peripheral { central?.cancelPeripheralConnection(peripheral) }
        central?.stopScan()
        peripheral = nil
        command = nil
        verified = false
        failWaiters()
        if pairing != nil { state = .idle }
    }

    // MARK: - 連線

    private var savedPeripheralKey: String? {
        pairing.map { "presence.link.peripheral.\($0.id.uuidString)" }
    }

    func connect() {
        guard let central, central.state == .poweredOn, pairing != nil else { return }
        // 系統冷啟動 App 時會交還仍然連著的 Mac：沿用，但要重新取得特徵並打招呼
        if let peripheral, peripheral.state == .connected {
            if !verified { prepare(peripheral) }
            return
        }
        if let peripheral, peripheral.state == .connecting { return }
        if let key = savedPeripheralKey, let saved = UserDefaults.standard.string(forKey: key).flatMap(UUID.init),
           let known = central.retrievePeripherals(withIdentifiers: [saved]).first {
            connect(known)
            return
        }
        state = .searching
        central.scanForPeripherals(withServices: [CBUUID(string: LinkIdentifiers.service)])
    }

    private func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        state = .connecting
        central?.connect(p)
    }

    /// 每次都重新查詢服務：Mac 上的 Presence 重開後服務會重建，沿用快取的特徵會寫到無效的位置。
    private func prepare(_ p: CBPeripheral) {
        p.delegate = self
        command = nil
        p.discoverServices([CBUUID(string: LinkIdentifiers.service)])
    }

    private func didDiscoverCharacteristics(of service: CBService, on p: CBPeripheral) {
        for characteristic in service.characteristics ?? [] {
            if characteristic.uuid == CBUUID(string: LinkIdentifiers.command) { command = characteristic }
            if characteristic.uuid == CBUUID(string: LinkIdentifiers.status) {
                if characteristic.isNotifying {
                    sendHello()
                } else {
                    p.setNotifyValue(true, for: characteristic)
                }
            }
        }
    }

    /// 打招呼並等 Mac 用同一把金鑰回覆；5 秒內沒有就當作不是自己的 Mac。
    private func sendHello() {
        guard let peripheral, let command, let pairing else { return }
        let request = LinkRequest(.hello(deviceName: deviceName))
        helloID = request.id
        guard let frame = try? RequestFrame.make(request, pairing: pairing) else { return }
        peripheral.writeValue(frame.encoded, for: command, type: .withResponse)
        verifyTimeout?.cancel()
        verifyTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, !self.verified, let p = self.peripheral else { return }
            if let key = self.savedPeripheralKey, UserDefaults.standard.string(forKey: key) == p.identifier.uuidString {
                // 之前驗證過的就是這台：多半是 Mac 上的 Presence 剛重開，斷線重連就好，不要列入黑名單
                LinkLog.write("[\(self.deviceName)] 已知的 Mac 沒有回應打招呼，重新連線")
                self.central?.cancelPeripheralConnection(p)
                return
            }
            // 不是自己配對的 Mac：記下來，換下一台
            LinkLog.write("[\(self.deviceName)] \(p.identifier.uuidString.prefix(8)) 沒有回應打招呼，換下一台")
            self.rejectedPeripherals.insert(p.identifier)
            self.central?.cancelPeripheralConnection(p)
            self.peripheral = nil
            self.state = .searching
            self.central?.scanForPeripherals(withServices: [CBUUID(string: LinkIdentifiers.service)])
        }
    }

    private func markVerified() {
        guard !verified, let peripheral else { return }
        verified = true
        verifyTimeout?.cancel()
        state = .connected
        if let key = savedPeripheralKey { UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: key) }
        let waiters = readyWaiters
        readyWaiters = []
        waiters.forEach { $0.resume(returning: true) }
    }

    private func scheduleIdleDisconnect() {
        guard !keepConnected else { return }
        idleDisconnect?.cancel()
        idleDisconnect = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, let p = self.peripheral else { return }
            self.central?.cancelPeripheralConnection(p)
        }
    }

    // MARK: - 收送

    private func waitUntilReady() async -> Bool {
        if state == .connected, verified { return true }
        return await withCheckedContinuation { readyWaiters.append($0) }
    }

    private func write(_ request: LinkRequest) async -> LinkStatus? {
        guard let peripheral, let command, let pairing,
              let frame = try? RequestFrame.make(request, pairing: pairing) else { return nil }
        return await withCheckedContinuation { continuation in
            replyWaiters[request.id] = continuation
            peripheral.writeValue(frame.encoded, for: command, type: .withResponse)
        }
    }

    private func received(_ chunk: Data) {
        guard let pairing, let whole = reassembler.add(chunk),
              let status = try? LinkCrypto.open(LinkStatus.self, from: whole, key: pairing.symmetricKey,
                                                context: pairing.id.data) else { return }
        if let reply = status.replyTo, reply == helloID { markVerified() }
        // 在場確認一定要回，即使這則狀態比手上的舊
        if let challenge = status.challenge { confirm(challenge) }
        // 比目前更舊的主動通知（例如延遲送達）不要蓋掉新的狀態
        if let current = self.status, status.replyTo == nil, status.sentAt < current.sentAt { return }
        self.status = status
        lastUpdate = Date()
        onStatus?(status)
        if status.event != nil { onEvent?(status) }
        if let reply = status.replyTo, let waiter = replyWaiters.removeValue(forKey: reply) {
            waiter.resume(returning: status)
        }
    }

    /// Mac 要解鎖前的在場確認：馬上送回去。App 在背景時，系統會為了這個通知叫醒它。
    private func confirm(_ challenge: Data) {
        LinkLog.write("[\(deviceName)] 回應 Mac 的在場確認")
        Task {
            if case .failure(let failure) = await send(.confirm(challenge: challenge), timeout: 5) {
                LinkLog.write("[\(deviceName)] 在場確認沒有送到：\(failure)")
            }
        }
    }

    private func failWaiters() {
        let ready = readyWaiters
        readyWaiters = []
        ready.forEach { $0.resume(returning: false) }
        let replies = replyWaiters
        replyWaiters = [:]
        replies.values.forEach { $0.resume(returning: nil) }
    }

    private func withTimeout<T: Sendable>(_ seconds: TimeInterval, _ operation: @escaping @MainActor () async -> T) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: .seconds(seconds))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            if first == nil { failWaiters() }
            return first
        }
    }

    private func handleDisconnect(_ p: CBPeripheral) {
        command = nil
        verified = false
        reassembler = LinkReassembler()
        failWaiters()
        guard pairing != nil else { return }
        if keepConnected, !rejectedPeripherals.contains(p.identifier) {
            // 登記待命連線：Mac 一回到範圍內，系統就自動連上並在背景叫醒 App
            state = .connecting
            central?.connect(p)
        } else {
            state = .idle
            peripheral = nil
        }
    }
}

extension LinkCentral: CBCentralManagerDelegate, CBPeripheralDelegate {
    public nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let s = central.state
        MainActor.assumeIsolated {
            switch s {
            case .poweredOn:
                if pairing != nil, state == .bluetoothOff || state == .unauthorized || state == .idle { state = .idle }
                if keepConnected || !readyWaiters.isEmpty { connect() }
            case .unauthorized: state = .unauthorized
            default: if pairing != nil { state = .bluetoothOff }
            }
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        nonisolated(unsafe) let restored = (dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral])?.first
        MainActor.assumeIsolated {
            if let restored {
                peripheral = restored
                restored.delegate = self
            }
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                           advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            guard !rejectedPeripherals.contains(peripheral.identifier), self.peripheral == nil else { return }
            central.stopScan()
            connect(peripheral)
        }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated { prepare(peripheral) }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { handleDisconnect(peripheral) }
    }

    public nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated { handleDisconnect(peripheral) }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let service = peripheral.services?.first(where: { $0.uuid == CBUUID(string: LinkIdentifiers.service) }) else {
                central?.cancelPeripheralConnection(peripheral)
                return
            }
            peripheral.discoverCharacteristics([CBUUID(string: LinkIdentifiers.command), CBUUID(string: LinkIdentifiers.status)], for: service)
        }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated { didDiscoverCharacteristics(of: service, on: peripheral) }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let ok = error == nil && characteristic.isNotifying
        MainActor.assumeIsolated { if ok { sendHello() } }
    }

    /// Mac 上的 Presence 重開時，連線可能還在、服務卻已重建：重新查詢並再打一次招呼。
    public nonisolated func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        let ours = invalidatedServices.contains { $0.uuid == CBUUID(string: LinkIdentifiers.service) }
        MainActor.assumeIsolated {
            guard ours, peripheral == self.peripheral else { return }
            LinkLog.write("[\(deviceName)] Mac 的服務變了，重新連線")
            verified = false
            if state == .connected { state = .connecting }
            prepare(peripheral)
        }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let value = characteristic.value
        MainActor.assumeIsolated { if let value { received(value) } }
    }
}
