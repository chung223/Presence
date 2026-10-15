@preconcurrency import CoreBluetooth // 回呼都在主執行緒（queue: nil）
import Foundation
import Observation
import PresenceLink
import Security

/// 已配對的 iPhone 或 Apple Watch。手錶沿用 iPhone 的配對，所以一個配對可能有兩種裝置名稱。
struct PairedDevice: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String?
    let createdAt: Date
    var lastSeen: Date?
}

/// 配對清單存在 UserDefaults；每個配對的金鑰存在鑰匙圈。
struct PairedDeviceStore {
    private static let listKey = "link.devices"
    private static let keychainService = "com.chung.presence.link"

    static func load() -> [PairedDevice] {
        guard let data = UserDefaults.standard.data(forKey: listKey),
              let devices = try? JSONDecoder().decode([PairedDevice].self, from: data) else { return [] }
        return devices
    }

    static func save(_ devices: [PairedDevice]) {
        if Demo.isActive { return }
        if let data = try? JSONEncoder().encode(devices) { UserDefaults.standard.set(data, forKey: listKey) }
    }

    static func key(for id: UUID) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    static func storeKey(_ key: Data, for id: UUID) {
        if Demo.isActive { return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: id.uuidString,
        ]
        SecItemDelete(base as CFDictionary)
        var item = base
        item[kSecValueData as String] = key
        item[kSecAttrLabel as String] = "Presence 配對金鑰"
        SecItemAdd(item as CFDictionary, nil)
    }

    static func removeKey(for id: UUID) {
        if Demo.isActive { return }
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: id.uuidString,
        ] as CFDictionary)
    }
}

/// 讓 iPhone 與 Apple Watch 的 Presence Remote 連進來（Mac 當藍牙週邊）。
///
/// - 指令都經過加密與驗證，並擋掉重送；不認得的配對一律不理。
/// - 每條連線在第一筆有效指令後才綁定配對，之後用該配對的金鑰加密狀態通知。
/// - 只有在有配對（或正在配對）時才廣播，平常不讓旁人看到這台 Mac 在跑 Presence。
@Observable
final class LinkService: NSObject {
    private(set) var devices: [PairedDevice] = PairedDeviceStore.load()
    /// 目前連著的配對（配對編號 → 裝置名稱）。
    private(set) var connected: [UUID: String] = [:]
    /// 正在顯示 QR code、等待 iPhone 掃描的配對。
    private(set) var pendingPairing: PairingInfo?
    /// 等待中的配對剛剛完成。
    private(set) var pairingCompleted = false

    /// 收到鎖定、暫停、簡報等指令；做不成時回傳原因，跟著回覆送回 iPhone 或手錶。
    @ObservationIgnored var onCommand: ((LinkCommand) -> CommandRefusal?)?
    /// 已配對的裝置連上並打過招呼。
    @ObservationIgnored var onDeviceConnected: ((String) -> Void)?
    /// 提供目前狀態給通知用；event 由呼叫端帶入。
    @ObservationIgnored var statusProvider: (() -> LinkStatus)?

    private struct Session {
        let central: CBCentral
        var pairingID: UUID?
        var messageID: UInt8 = 0
        var queue: [Data] = []
    }

    @ObservationIgnored private var manager: CBPeripheralManager?
    @ObservationIgnored private var statusCharacteristic: CBMutableCharacteristic?
    @ObservationIgnored private var sessions: [UUID: Session] = [:]
    @ObservationIgnored private var guards: [UUID: ReplayGuard] = [:]
    @ObservationIgnored private var keys: [UUID: Data] = [:]
    @ObservationIgnored private var challenge: PendingChallenge?

    private struct PendingChallenge {
        var challenge: PresenceChallenge
        let lifetime: TimeInterval
        let continuation: CheckedContinuation<PresenceConfirmation, Never>
    }

    enum PresenceConfirmation: Equatable {
        case confirmed(deviceName: String)
        /// 時限內沒有任何已配對的裝置連著
        case noDevice
        /// 有裝置連著，但沒有回應（例如 App 版本太舊）
        case noResponse
    }

    private var shouldAdvertise: Bool { !devices.isEmpty || pendingPairing != nil }

    func start() {
        if Demo.isActive { return }
        guard shouldAdvertise else {
            stop()
            return
        }
        if manager == nil {
            manager = CBPeripheralManager(delegate: self, queue: nil)
        } else if manager?.state == .poweredOn, manager?.isAdvertising == false {
            advertise()
        }
    }

    func stop() {
        manager?.stopAdvertising()
        manager?.removeAllServices()
        manager = nil
        statusCharacteristic = nil
        sessions = [:]
        connected = [:]
    }

    #if DEBUG
    /// 示範模式：不廣播，直接顯示假的已配對裝置。
    func startDemo(devices: [PairedDevice], connected: [UUID: String]) {
        self.devices = devices
        self.connected = connected
    }
    #endif

    // MARK: - 配對

    func beginPairing() -> PairingInfo {
        cancelPairing()
        let pairing = PairingInfo.generate(macName: Demo.isActive ? "MacBook Pro" : Host.current().localizedName ?? "Mac")
        PairedDeviceStore.storeKey(pairing.key, for: pairing.id)
        keys[pairing.id] = pairing.key
        pendingPairing = pairing
        pairingCompleted = false
        start()
        return pairing
    }

    /// 關掉配對畫面時呼叫：還沒有裝置用過的配對就作廢。
    func cancelPairing() {
        guard let pending = pendingPairing else { return }
        pendingPairing = nil
        if !devices.contains(where: { $0.id == pending.id }) {
            PairedDeviceStore.removeKey(for: pending.id)
            keys[pending.id] = nil
        }
        start()
    }

    func remove(_ id: UUID) {
        devices.removeAll { $0.id == id }
        PairedDeviceStore.save(devices)
        PairedDeviceStore.removeKey(for: id)
        keys[id] = nil
        guards[id] = nil
        connected[id] = nil
        for (centralID, session) in sessions where session.pairingID == id {
            sessions[centralID]?.pairingID = nil
        }
        start()
    }

    // MARK: - 在場確認

    /// 請已配對的裝置用金鑰送回一個隨機挑戰，證明它此刻真的連在這台 Mac 上。
    /// 還沒有裝置連著時一直等到時限，期間連上的也會收到挑戰。
    func confirmPresence(within lifetime: TimeInterval) async -> PresenceConfirmation {
        finishChallenge(with: .noResponse)
        let pending = PresenceChallenge()
        return await withCheckedContinuation { continuation in
            challenge = PendingChallenge(challenge: pending, lifetime: lifetime, continuation: continuation)
            for (centralID, session) in sessions {
                guard let pairingID = session.pairingID, var status = statusProvider?() else { continue }
                status.challenge = pending.nonce
                if challenge?.challenge.markSent(to: centralID) == true {
                    send(status, to: centralID, pairingID: pairingID)
                }
            }
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(lifetime))
                guard let self, self.challenge?.challenge.nonce == pending.nonce else { return }
                self.finishChallenge(with: self.challenge?.challenge.sentTo.isEmpty == false ? .noResponse : .noDevice)
            }
        }
    }

    /// 已經不需要確認了（例如 Apple Watch 先解開了）。
    func cancelPresenceConfirmation() {
        finishChallenge(with: .noResponse)
    }

    private func finishChallenge(with result: PresenceConfirmation) {
        guard let pending = challenge else { return }
        challenge = nil
        pending.continuation.resume(returning: result)
    }

    // MARK: - 通知

    /// 把目前狀態送給所有連著的裝置；event 是要提醒的事件（例如已鎖定）。
    func broadcast(event: LinkEvent? = nil) {
        guard let statusProvider else { return }
        var status = statusProvider()
        status.event = event
        for (centralID, session) in sessions {
            guard let pairingID = session.pairingID else { continue }
            send(status, to: centralID, pairingID: pairingID)
        }
    }

    private func send(_ status: LinkStatus, to centralID: UUID, pairingID: UUID) {
        guard var session = sessions[centralID], let key = key(for: pairingID),
              let sealed = try? LinkCrypto.seal(status, key: .init(data: key), context: pairingID.data) else { return }
        session.messageID &+= 1
        let chunks = LinkChunker.split(sealed, maxChunk: max(20, session.central.maximumUpdateValueLength),
                                       messageID: session.messageID)
        session.queue.append(contentsOf: chunks)
        sessions[centralID] = session
        flush(centralID)
    }

    private func flush(_ centralID: UUID) {
        guard let manager, let characteristic = statusCharacteristic, var session = sessions[centralID] else { return }
        while let next = session.queue.first {
            guard manager.updateValue(next, for: characteristic, onSubscribedCentrals: [session.central]) else { break }
            session.queue.removeFirst()
        }
        sessions[centralID] = session
    }

    // MARK: - 指令

    private func key(for pairingID: UUID) -> Data? {
        if let key = keys[pairingID] { return key }
        guard devices.contains(where: { $0.id == pairingID }) || pendingPairing?.id == pairingID,
              let key = PairedDeviceStore.key(for: pairingID) else { return nil }
        keys[pairingID] = key
        return key
    }

    /// 回傳 false 表示格式錯誤、不認得或驗證失敗。
    private func handle(_ data: Data, from central: CBCentral) -> Bool {
        guard let frame = RequestFrame(encoded: data), let key = key(for: frame.pairingID) else { return false }
        let pairing = PairingInfo(id: frame.pairingID, macName: "", key: key)
        guard let request = try? frame.open(with: pairing) else { return false }
        var replay = guards[frame.pairingID] ?? ReplayGuard()
        guard replay.accept(request, now: Date()) else { return false }
        guards[frame.pairingID] = replay

        if sessions[central.identifier] == nil { sessions[central.identifier] = Session(central: central) }
        sessions[central.identifier]?.pairingID = frame.pairingID

        var refusal: CommandRefusal?
        switch request.command {
        case .hello(let deviceName):
            register(frame.pairingID, name: deviceName)
        case .status:
            touch(frame.pairingID)
        case .lock, .pause, .resume, .presenter, .presentation:
            touch(frame.pairingID)
            refusal = onCommand?(request.command)
        case .confirm(let response):
            touch(frame.pairingID)
            if let pending = challenge, pending.challenge.accepts(response, at: Date(), within: pending.lifetime) {
                finishChallenge(with: .confirmed(deviceName: connected[frame.pairingID] ?? name(of: frame.pairingID)))
            }
        }
        if var status = statusProvider?() {
            status.replyTo = request.id
            status.refusal = refusal?.rawValue
            // 剛連上、還沒收過正在等的挑戰：一起帶過去
            if challenge?.challenge.markSent(to: central.identifier) == true { status.challenge = challenge?.challenge.nonce }
            send(status, to: central.identifier, pairingID: frame.pairingID)
        }
        if case .hello(let deviceName) = request.command, devices.contains(where: { $0.id == frame.pairingID }) {
            onDeviceConnected?(deviceName)
        }
        return true
    }

    private func register(_ id: UUID, name: String) {
        connected[id] = name
        if let index = devices.firstIndex(where: { $0.id == id }) {
            // 手錶沿用 iPhone 的配對：保留第一次配對的名稱（通常是 iPhone）
            if devices[index].name == nil { devices[index].name = name }
            devices[index].lastSeen = Date()
        } else if pendingPairing?.id == id {
            devices.append(PairedDevice(id: id, name: name, createdAt: Date(), lastSeen: Date()))
            pendingPairing = nil
            pairingCompleted = true
        } else {
            return
        }
        PairedDeviceStore.save(devices)
    }

    private func name(of id: UUID) -> String {
        devices.first { $0.id == id }?.name ?? "iPhone"
    }

    private func touch(_ id: UUID) {
        guard let index = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[index].lastSeen = Date()
        PairedDeviceStore.save(devices)
    }

    private func advertise() {
        guard let manager, manager.state == .poweredOn, shouldAdvertise else { return }
        if statusCharacteristic == nil {
            let command = CBMutableCharacteristic(type: CBUUID(string: LinkIdentifiers.command),
                                                  properties: [.write], value: nil, permissions: [.writeable])
            let status = CBMutableCharacteristic(type: CBUUID(string: LinkIdentifiers.status),
                                                 properties: [.notify], value: nil, permissions: [.readable])
            statusCharacteristic = status
            let service = CBMutableService(type: CBUUID(string: LinkIdentifiers.service), primary: true)
            service.characteristics = [command, status]
            manager.add(service)
        } else if !manager.isAdvertising {
            manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: LinkIdentifiers.service)]])
        }
    }
}

extension LinkService: CBPeripheralManagerDelegate {
    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        let state = peripheral.state
        MainActor.assumeIsolated {
            if state == .poweredOn {
                advertise()
            } else {
                statusCharacteristic = nil
                sessions = [:]
                connected = [:]
            }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard error == nil else { return }
            peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [CBUUID(string: LinkIdentifiers.service)]])
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        nonisolated(unsafe) let requests = requests // 回呼本來就在主執行緒
        MainActor.assumeIsolated {
            var ok = true
            for request in requests {
                guard let value = request.value, handle(value, from: request.central) else {
                    ok = false
                    continue
                }
            }
            if let first = requests.first {
                peripheral.respond(to: first, withResult: ok ? .success : .insufficientAuthentication)
            }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        nonisolated(unsafe) let central = central
        MainActor.assumeIsolated {
            if sessions[central.identifier] == nil { sessions[central.identifier] = Session(central: central) }
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        let id = central.identifier
        MainActor.assumeIsolated {
            if let pairingID = sessions[id]?.pairingID {
                // 同一個配對還有其他連線（例如手錶）就不移除
                let others = sessions.filter { $0.key != id && $0.value.pairingID == pairingID }
                if others.isEmpty { connected[pairingID] = nil }
            }
            sessions[id] = nil
        }
    }

    nonisolated func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        MainActor.assumeIsolated {
            for id in sessions.keys { flush(id) }
        }
    }
}
