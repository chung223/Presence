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
    /// 雷射筆的位置走這個特徵；舊版 Mac 沒有。
    private var pointerCharacteristic: CBCharacteristic?
    @ObservationIgnored private var verified = false
    /// 還在查特徵的服務；每一份都查完才訂閱與打招呼。
    @ObservationIgnored private var discovering: Set<ObjectIdentifier> = []
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

    /// 宣傳影片用：照腳本換狀態。
    public func updateDemo(_ status: LinkStatus) {
        self.status = status
        lastUpdate = Date()
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
        case .presentation(let active):
            next.presenter = active ? .presenting : .enabled
            next.pausedUntil = active ? Date().addingTimeInterval(3 * 3600) : nil
            next.presence = active ? .paused : .near
            next.presentationStartedAt = active ? (next.presentationStartedAt ?? Date()) : nil
            if !active { next.presentationMinutes = nil }
        case .presentationTimer(let startedAt, let minutes):
            next.presentationStartedAt = startedAt
            next.presentationMinutes = minutes
        case .volume(let change):
            var volume = next.volume ?? MacVolume(level: 0.5, muted: false, adjustable: true)
            switch change {
            case .set(let level): volume = MacVolume(level: level, muted: false, adjustable: true)
            case .step(let up): volume = MacVolume(level: volume.level + (up ? 1 : -1) / 16, muted: false, adjustable: true)
            case .mute(let muted): volume.muted = muted
            }
            next.volume = volume
        case .hello, .status, .confirm, .presenter, .goToSlide: break
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
        // 只有一直連著的 iPhone 沿用記住的 Mac。手錶隔很久才直接連一次，Mac 的藍牙位址早就換了，
        // 連記住的那個會一直等（2026-10-17 實測等了 42 秒），重新搜尋約 3 秒就連上
        if keepConnected, let key = savedPeripheralKey, let saved = UserDefaults.standard.string(forKey: key).flatMap(UUID.init),
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
        pointerCharacteristic = nil
        discovering = []
        p.discoverServices([CBUUID(string: LinkIdentifiers.service)])
    }

    private func ourServices(of p: CBPeripheral) -> [CBService] {
        p.services?.filter { $0.uuid == CBUUID(string: LinkIdentifiers.service) } ?? []
    }

    private func statusCharacteristics(of p: CBPeripheral) -> [CBCharacteristic] {
        ourServices(of: p).flatMap { $0.characteristics ?? [] }.filter { $0.uuid == CBUUID(string: LinkIdentifiers.status) }
    }

    /// Mac 上 0.3.1 以前的 Presence 每次睡眠醒來都會多加一份服務（舊的沒移除），回覆只從最新那份送出。
    /// 所以每一份的狀態特徵都訂閱，全部訂好才打招呼；指令與雷射筆寫到最後一份（Mac 收到哪一份都一樣處理）。
    private func didDiscoverCharacteristics(on p: CBPeripheral) {
        let characteristics = ourServices(of: p).flatMap { $0.characteristics ?? [] }
        command = characteristics.last { $0.uuid == CBUUID(string: LinkIdentifiers.command) }
        pointerCharacteristic = characteristics.last { $0.uuid == CBUUID(string: LinkIdentifiers.pointer) }
        let statuses = statusCharacteristics(of: p)
        guard !statuses.isEmpty else { return }
        let waiting = statuses.filter { !$0.isNotifying }
        if waiting.isEmpty {
            sendHello()
        } else {
            waiting.forEach { p.setNotifyValue(true, for: $0) }
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

    /// 能送雷射筆的位置：連著、驗證過，而且 Mac 版本夠新。
    public var canStreamPointer: Bool {
        #if DEBUG
        if demo { return true }
        #endif
        return state == .connected && verified && pointerCharacteristic != nil
    }

    /// 送一筆雷射筆位置，不等回覆。藍牙送不過來時直接丟掉這筆：下一筆就是更新的位置。
    public func streamPointer(_ update: PointerUpdate) {
        #if DEBUG
        if demo { return }
        #endif
        guard verified, let peripheral, let pointerCharacteristic, let pairing,
              peripheral.canSendWriteWithoutResponse,
              let frame = try? PointerFrame.make(update, pairing: pairing) else { return }
        peripheral.writeValue(frame, for: pointerCharacteristic, type: .withoutResponse)
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
        pointerCharacteristic = nil
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
            let services = ourServices(of: peripheral)
            guard !services.isEmpty else {
                central?.cancelPeripheralConnection(peripheral)
                return
            }
            if services.count > 1 {
                LinkLog.write("[\(deviceName)] Mac 上有 \(services.count) 份服務（舊版 Presence 睡眠醒來會多加），每一份都訂閱")
            }
            discovering = Set(services.map(ObjectIdentifier.init))
            for service in services {
                peripheral.discoverCharacteristics([CBUUID(string: LinkIdentifiers.command), CBUUID(string: LinkIdentifiers.status),
                                                    CBUUID(string: LinkIdentifiers.pointer)], for: service)
            }
        }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            // 上一輪查詢晚到的回呼不算
            guard discovering.remove(ObjectIdentifier(service)) != nil, discovering.isEmpty else { return }
            didDiscoverCharacteristics(on: peripheral)
        }
    }

    public nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let ok = error == nil && characteristic.isNotifying
        MainActor.assumeIsolated {
            guard ok else {
                LinkLog.write("[\(deviceName)] 訂閱 Mac 的狀態失敗：\(error.map { "\($0)" } ?? "沒有開啟")")
                return
            }
            // 每一份都訂好才打招呼，不然回覆可能從還沒訂到的那份送出
            if statusCharacteristics(of: peripheral).allSatisfy(\.isNotifying) { sendHello() }
        }
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
