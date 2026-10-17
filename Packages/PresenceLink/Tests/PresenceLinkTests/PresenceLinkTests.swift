import CryptoKit
import Foundation
import Testing
@testable import PresenceLink

struct PairingTests {
    @Test func qrStringRoundTrips() throws {
        let pairing = PairingInfo.generate(macName: "Chung 的 MacBook Pro")
        let parsed = try #require(PairingInfo(qrString: pairing.qrString))
        #expect(parsed == pairing)
    }

    @Test(arguments: [
        "",
        "presence-pair:2:00000000-0000-0000-0000-000000000000:AAAA:QQ",
        "presence-pair:1:not-a-uuid:AAAA:QQ",
        "presence-pair:1:00000000-0000-0000-0000-000000000000:AAAA:QQ",   // 金鑰太短
        "https://example.com",
    ])
    func malformedQRStringsAreRejected(_ text: String) {
        #expect(PairingInfo(qrString: text) == nil)
    }

    @Test func generatedKeysAre256BitsAndUnique() {
        let a = PairingInfo.generate(macName: "Mac")
        let b = PairingInfo.generate(macName: "Mac")
        #expect(a.key.count == 32)
        #expect(a.key != b.key)
        #expect(a.id != b.id)
    }
}

struct CryptoTests {
    let pairing = PairingInfo.generate(macName: "Mac")

    @Test func requestFrameRoundTrips() throws {
        let request = LinkRequest(.pause(minutes: 60))
        let frame = try RequestFrame.make(request, pairing: pairing)
        let decoded = try #require(RequestFrame(encoded: frame.encoded))
        #expect(decoded.pairingID == pairing.id)
        #expect(try decoded.open(with: pairing).command == .pause(minutes: 60))
    }

    @Test func wrongKeyCannotOpen() throws {
        let frame = try RequestFrame.make(LinkRequest(.lock), pairing: pairing)
        let other = PairingInfo(id: pairing.id, macName: "Mac", key: PairingInfo.generate(macName: "x").key)
        #expect(throws: (any Error).self) { try frame.open(with: other) }
    }

    @Test("換掉配對編號就解不開")
    func swappedPairingIDCannotOpen() throws {
        let frame = try RequestFrame.make(LinkRequest(.lock), pairing: pairing)
        let forged = RequestFrame(pairingID: UUID(), sealed: frame.sealed)
        let samekeyOtherID = PairingInfo(id: forged.pairingID, macName: "Mac", key: pairing.key)
        #expect(throws: (any Error).self) { try forged.open(with: samekeyOtherID) }
    }

    @Test func tamperedCiphertextCannotOpen() throws {
        var data = try RequestFrame.make(LinkRequest(.lock), pairing: pairing).encoded
        data[data.count - 20] ^= 0xFF
        let frame = try #require(RequestFrame(encoded: data))
        #expect(throws: (any Error).self) { try frame.open(with: pairing) }
    }

    @Test func shortFramesAreRejected() {
        #expect(RequestFrame(encoded: Data(repeating: 0, count: 40)) == nil)
    }

    @Test func statusRoundTrips() throws {
        let status = LinkStatus(macName: "Mac", presence: .near, summary: "Weichung 在附近 · -52 dBm",
                                locked: false, event: .lockedAway, replyTo: UUID(), sentAt: Date(timeIntervalSince1970: 1_800_000_000))
        let sealed = try LinkCrypto.seal(status, key: pairing.symmetricKey)
        #expect(try LinkCrypto.open(LinkStatus.self, from: sealed, key: pairing.symmetricKey) == status)
    }
}

struct ChunkingTests {
    @Test(arguments: [1, 10, 177, 178, 179, 500, 2000])
    func splitAndReassemble(size: Int) throws {
        let data = Data((0..<size).map { UInt8($0 % 251) })
        let chunks = LinkChunker.split(data, maxChunk: 182, messageID: 7)
        #expect(chunks.allSatisfy { $0.count <= 182 })
        var reassembler = LinkReassembler()
        var result: Data?
        for chunk in chunks { result = reassembler.add(chunk) }
        #expect(result == data)
    }

    @Test("新訊息開始時丟掉沒組完的舊訊息")
    func newMessageDiscardsIncompleteOne() throws {
        let old = LinkChunker.split(Data(repeating: 1, count: 400), maxChunk: 100, messageID: 1)
        let new = LinkChunker.split(Data(repeating: 2, count: 50), maxChunk: 100, messageID: 2)
        var reassembler = LinkReassembler()
        let first = reassembler.add(old[0])
        let second = reassembler.add(new[0])
        #expect(first == nil)
        #expect(second == Data(repeating: 2, count: 50))
    }

    @Test func garbageIsIgnored() {
        var reassembler = LinkReassembler()
        let tooShort = reassembler.add(Data([1]))
        let outOfRange = reassembler.add(Data([1, 5, 2, 0]))
        #expect(tooShort == nil)
        #expect(outOfRange == nil, "第 5 段卻只有 2 段")
    }
}

struct ReplayGuardTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func acceptsFreshRequestOnce() {
        var guardian = ReplayGuard()
        let request = LinkRequest(.lock, sentAt: now)
        let first = guardian.accept(request, now: now)
        let replay = guardian.accept(request, now: now.addingTimeInterval(1))
        #expect(first)
        #expect(replay == false, "同一個指令不能重送")
    }

    @Test(arguments: [-120.0, 120.0])
    func rejectsRequestsOutsideTheWindow(offset: TimeInterval) {
        var guardian = ReplayGuard()
        let accepted = guardian.accept(LinkRequest(.lock, sentAt: now.addingTimeInterval(offset)), now: now)
        #expect(accepted == false)
    }

    @Test func forgetsOldIDsButStillRejectsThemByTime() {
        var guardian = ReplayGuard()
        let request = LinkRequest(.lock, sentAt: now)
        let first = guardian.accept(request, now: now)
        let later = guardian.accept(request, now: now.addingTimeInterval(300))
        #expect(first)
        #expect(later == false)
    }
}

struct PresenceChallengeTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func acceptsTheSameNonceWithinLifetime() {
        let challenge = PresenceChallenge(issuedAt: now)
        #expect(challenge.accepts(challenge.nonce, at: now.addingTimeInterval(2), within: 10))
    }

    @Test("別的挑戰、過期或時間倒退的回應都不算")
    func rejectsWrongOrLateResponses() {
        let challenge = PresenceChallenge(issuedAt: now)
        let other = PresenceChallenge(issuedAt: now)
        #expect(challenge.nonce != other.nonce)
        #expect(challenge.accepts(other.nonce, at: now, within: 10) == false)
        #expect(challenge.accepts(challenge.nonce, at: now.addingTimeInterval(11), within: 10) == false)
        #expect(challenge.accepts(challenge.nonce, at: now.addingTimeInterval(-1), within: 10) == false)
    }

    @Test func nonceIs128BitsAndRandom() {
        let nonces = Set((0..<100).map { _ in PresenceChallenge.randomNonce() })
        #expect(nonces.count == 100)
        #expect(nonces.allSatisfy { $0.count == 16 })
    }

    @Test func remembersWhichConnectionsGotIt() {
        var challenge = PresenceChallenge(issuedAt: now)
        let central = UUID()
        let first = challenge.markSent(to: central)
        let again = challenge.markSent(to: central)
        #expect(first)
        #expect(again == false)
        #expect(challenge.sentTo == [central])
    }

    @Test("挑戰與回應經過加密後原樣保留")
    func challengeSurvivesEncryption() throws {
        let pairing = PairingInfo.generate(macName: "Mac")
        let challenge = PresenceChallenge(issuedAt: now)
        let status = LinkStatus(macName: "Mac", presence: .near, summary: "", locked: true, challenge: challenge.nonce, sentAt: now)
        let sealed = try LinkCrypto.seal(status, key: pairing.symmetricKey)
        let opened = try LinkCrypto.open(LinkStatus.self, from: sealed, key: pairing.symmetricKey)
        #expect(opened.challenge == challenge.nonce)

        let frame = try RequestFrame.make(LinkRequest(.confirm(challenge: try #require(opened.challenge))), pairing: pairing)
        let decoded = try #require(RequestFrame(encoded: frame.encoded))
        #expect(try decoded.open(with: pairing).command == .confirm(challenge: challenge.nonce))
    }
}

struct SharedStatusTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func status(presence: MacPresence = .near, locked: Bool = false, pausedUntil: Date? = nil, summary: String = "") -> LinkStatus {
        LinkStatus(macName: "Mac", presence: presence, summary: summary, locked: locked, pausedUntil: pausedUntil, sentAt: now)
    }

    @Test("訊號強度之類的摘要文字變了，不必重畫小工具")
    func signatureIgnoresSummary() {
        let a = SharedStatus(macName: "Mac", status: status(summary: "-52 dBm"), connected: true, updatedAt: now)
        let b = SharedStatus(macName: "Mac", status: status(summary: "-60 dBm"), connected: true, updatedAt: now.addingTimeInterval(5))
        #expect(a.widgetSignature == b.widgetSignature)
    }

    @Test(arguments: [
        SharedStatus(macName: "Mac", status: nil, connected: true),
        SharedStatus(macName: "Mac", status: LinkStatus(macName: "Mac", presence: .away, summary: "", locked: false), connected: true),
        SharedStatus(macName: "Mac", status: LinkStatus(macName: "Mac", presence: .near, summary: "", locked: true), connected: true),
        SharedStatus(macName: "Mac", status: LinkStatus(macName: "Mac", presence: .near, summary: "", locked: false), connected: false),
    ])
    func signatureChangesWithVisibleState(other: SharedStatus) {
        let base = SharedStatus(macName: "Mac", status: status(), connected: true, updatedAt: now)
        #expect(base.widgetSignature != other.widgetSignature)
    }

    @Test func pausedAndStale() {
        let paused = SharedStatus(macName: "Mac", status: status(pausedUntil: now.addingTimeInterval(60)), connected: true, updatedAt: now)
        #expect(paused.isPaused(at: now))
        #expect(paused.isPaused(at: now.addingTimeInterval(61)) == false)
        #expect(paused.isStale(at: now.addingTimeInterval(60)) == false)
        #expect(paused.isStale(at: now.addingTimeInterval(31 * 60)))
        let disconnected = SharedStatus(macName: "Mac", status: status(), connected: false, updatedAt: now)
        #expect(disconnected.isStale(at: now))
    }
}

struct PresenterProtocolTests {
    let pairing = PairingInfo.generate(macName: "Mac")

    @Test(arguments: PresenterAction.allCases.map(LinkCommand.presenter) + [.presentation(active: true), .presentation(active: false)])
    func presenterCommandsRoundTrip(command: LinkCommand) throws {
        let frame = try RequestFrame.make(LinkRequest(command), pairing: pairing)
        let decoded = try #require(RequestFrame(encoded: frame.encoded))
        #expect(try decoded.open(with: pairing).command == command)
    }

    @Test("舊版 Mac 送的狀態沒有簡報欄位，新版 iPhone 照樣解得開")
    func oldStatusDecodes() throws {
        let json = #"{"macName":"Mac","presence":"near","summary":"","locked":false,"sentAt":0}"#
        let status = try JSONDecoder().decode(LinkStatus.self, from: Data(json.utf8))
        #expect(status.presenter == nil)
        #expect(status.refusalMessage == nil)
    }

    @Test("新版 Mac 多送的欄位，舊版 iPhone 會略過")
    func newStatusDecodesWithOldFields() throws {
        struct OldStatus: Decodable { var macName: String; var presence: MacPresence; var locked: Bool }
        let status = LinkStatus(macName: "Mac", presence: .paused, summary: "", locked: false,
                                presenter: .presenting, refusal: CommandRefusal.screenLocked.rawValue)
        let old = try JSONDecoder().decode(OldStatus.self, from: JSONEncoder().encode(status))
        #expect(old.macName == "Mac" && old.presence == .paused)
    }

    @Test func statusWithPresenterRoundTrips() throws {
        let status = LinkStatus(macName: "Mac", presence: .near, summary: "", locked: false, presenter: .enabled,
                                refusal: CommandRefusal.noAccessibility.rawValue, sentAt: Date(timeIntervalSince1970: 1_800_000_000))
        let sealed = try LinkCrypto.seal(status, key: pairing.symmetricKey)
        #expect(try LinkCrypto.open(LinkStatus.self, from: sealed, key: pairing.symmetricKey) == status)
    }

    @Test("不認得的拒絕原因給一般的說明，不會整則解不開")
    func unknownRefusalFallsBack() {
        var status = LinkStatus(macName: "Mac", presence: .near, summary: "", locked: false, refusal: "somethingNew")
        #expect(status.refusalMessage == String(localized: "Mac 沒有接受這個指令", bundle: .module))
        status.refusal = CommandRefusal.screenLocked.rawValue
        #expect(status.refusalMessage == CommandRefusal.screenLocked.message)
    }
}

struct PresentationTimerTests {
    @Test(arguments: [LinkCommand.goToSlide(12), .presentationTimer(startedAt: Date(timeIntervalSince1970: 1_800_000_000), minutes: 20),
                      .presentationTimer(startedAt: Date(timeIntervalSince1970: 1_800_000_000), minutes: nil),
                      .volume(.set(0.4)), .volume(.step(up: true)), .volume(.mute(true))])
    func newCommandsRoundTrip(command: LinkCommand) throws {
        let pairing = PairingInfo.generate(macName: "Mac")
        let frame = try RequestFrame.make(LinkRequest(command), pairing: pairing)
        #expect(try #require(RequestFrame(encoded: frame.encoded)).open(with: pairing).command == command)
    }

    @Test func endsAtNeedsBothStartAndLength() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var status = LinkStatus(macName: "Mac", presence: .paused, summary: "", locked: false, presentationStartedAt: start)
        #expect(status.presentationEndsAt == nil)
        status.presentationMinutes = 20
        #expect(status.presentationEndsAt == start.addingTimeInterval(1200))
    }
}

struct ProAccessTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func nothingBoughtIsNotPro() {
        #expect(!ProAccess.isActive([], now: now))
        #expect(!ProAccess.isActive([ProPurchase(productID: "com.example.other")], now: now))
    }

    @Test func lifetimeNeverExpires() {
        let purchases = [ProPurchase(productID: ProProduct.lifetime.rawValue)]
        #expect(ProAccess.isActive(purchases, now: now))
        #expect(ProAccess.hasLifetime(purchases))
        #expect(ProAccess.activeSubscription(purchases, now: now) == nil)
    }

    @Test("訂閱到期、退款或換方案後就不算")
    func subscriptionMustBeCurrent() {
        let id = ProProduct.yearly.rawValue
        #expect(ProAccess.isActive([ProPurchase(productID: id, expirationDate: now + 60)], now: now))
        #expect(!ProAccess.isActive([ProPurchase(productID: id, expirationDate: now - 60)], now: now))
        #expect(!ProAccess.isActive([ProPurchase(productID: id, expirationDate: now + 60, revocationDate: now - 1)], now: now))
        #expect(!ProAccess.isActive([ProPurchase(productID: id, expirationDate: now + 60, isUpgraded: true)], now: now))
    }

    @Test("同時有月訂與年訂時，顯示到期最晚的那一個")
    func activeSubscriptionPicksLatestRenewal() throws {
        let purchases = [ProPurchase(productID: ProProduct.monthly.rawValue, expirationDate: now + 86_400),
                         ProPurchase(productID: ProProduct.yearly.rawValue, expirationDate: now + 86_400 * 300)]
        let active = try #require(ProAccess.activeSubscription(purchases, now: now))
        #expect(active.product == .yearly)
        #expect(active.renewal == now + 86_400 * 300)
    }

    @Test func familySharingOnlyWhenEveryValidPurchaseIsShared() {
        let shared = ProPurchase(productID: ProProduct.lifetime.rawValue, isFamilyShared: true)
        let own = ProPurchase(productID: ProProduct.monthly.rawValue, expirationDate: now + 60)
        #expect(ProAccess.isFamilyShared([shared], now: now))
        #expect(!ProAccess.isFamilyShared([shared, own], now: now))
        #expect(!ProAccess.isFamilyShared([], now: now))
    }
}

struct NeedsProTests {
    @Test(arguments: [LinkCommand.presenter(.next), .goToSlide(3), .presentation(active: true),
                      .presentationTimer(startedAt: Date(timeIntervalSince1970: 0), minutes: 10), .volume(.mute(false))])
    func presenterCommandsNeedPro(command: LinkCommand) {
        #expect(command.needsPro)
    }

    @Test("鎖定、暫停與結束簡報不用 Pro")
    func freeCommands() {
        for command in [LinkCommand.lock, .status, .pause(minutes: 15), .resume, .presentation(active: false)] {
            #expect(!command.needsPro)
        }
    }
}

struct StatusDetailTests {
    @Test("舊版 Mac 沒送 detail：解得開，顯示 Mac 組好的文字")
    func oldMacFallsBackToSummary() throws {
        let status = LinkStatus(macName: "Mac", presence: .near, summary: "Apple Watch 在附近 · -52 dBm", locked: false)
        var json = try JSONSerialization.jsonObject(with: WatchMessage.encode(status)) as! [String: Any]
        json.removeValue(forKey: "detail")
        let decoded = try WatchMessage.decode(LinkStatus.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.detail == nil)
        #expect(decoded.displaySummary == "Apple Watch 在附近 · -52 dBm")
    }

    @Test("認不得的種類（新版 Mac）退回 Mac 組好的文字")
    func unknownKindFallsBack() {
        var detail = StatusDetail(kind: .near, devices: ["Apple Watch"])
        detail.kind = "somethingNew"
        let status = LinkStatus(macName: "Mac", presence: .near, summary: "原本的文字", detail: detail, locked: false)
        #expect(status.displaySummary == "原本的文字")
    }

    @Test func summaryCarriesNamesSignalAndCountdown() throws {
        let near = try #require(StatusDetail(kind: .near, devices: ["Apple Watch"], rssi: -52).localizedSummary)
        #expect(near.contains("Apple Watch") && near.contains("-52 dBm"))
        let leaving = try #require(StatusDetail(kind: .leaving, devices: ["iPhone"], leavingSeconds: 7).localizedSummary)
        #expect(leaving.contains("iPhone") && leaving.contains("7"))
        let suspended = try #require(StatusDetail(kind: .suspended, suspension: .trustedNetwork(name: "Home")).localizedSummary)
        #expect(suspended.contains("Home"))
    }

    @Test func detailRoundTrips() throws {
        let detail = StatusDetail(kind: .suspended, suspension: .presenting(app: "Keynote"), suspendsUnlock: true)
        let status = LinkStatus(macName: "Mac", presence: .suspended, summary: "", detail: detail, locked: false)
        #expect(try WatchMessage.decode(LinkStatus.self, from: WatchMessage.encode(status)).detail == detail)
    }
}

struct PointerTests {
    @Test func roundTripsAndStaysSmall() throws {
        let pairing = PairingInfo.generate(macName: "Mac")
        let update = PointerUpdate(mode: .spotlight, x: 0.25, y: 0.75, sentAt: Date(timeIntervalSince1970: 1_800_000_000.125))
        let frame = try PointerFrame.make(update, pairing: pairing)
        #expect(frame.count < 100)  // 一筆就送得完，不用分段
        #expect(PointerFrame.pairingID(of: frame) == pairing.id)
        let opened = try #require(PointerFrame.open(frame, key: pairing.symmetricKey))
        #expect(opened.mode == .spotlight)
        #expect(abs(opened.x - 0.25) < 0.0001 && abs(opened.y - 0.75) < 0.0001)
        #expect(opened.sentAt == update.sentAt)
    }

    @Test("別的配對的金鑰、被改過的資料都解不開")
    func rejectsWrongKeyAndTampering() throws {
        let pairing = PairingInfo.generate(macName: "Mac")
        var frame = try PointerFrame.make(PointerUpdate(mode: .laser, x: 0.5, y: 0.5), pairing: pairing)
        #expect(PointerFrame.open(frame, key: PairingInfo.generate(macName: "Other").symmetricKey) == nil)
        frame[frame.count - 1] ^= 0xFF
        #expect(PointerFrame.open(frame, key: pairing.symmetricKey) == nil)
    }

    @Test("指令的密文不能拿來當位置用")
    func commandFramesAreNotPointers() throws {
        let pairing = PairingInfo.generate(macName: "Mac")
        let request = try RequestFrame.make(LinkRequest(.lock), pairing: pairing)
        #expect(PointerFrame.open(request.encoded, key: pairing.symmetricKey) == nil)
    }

    @Test func clampsToScreen() {
        let update = PointerUpdate(mode: .laser, x: -0.2, y: 1.4)
        #expect(update.x == 0 && update.y == 1)
    }

    @Test("只收比上一筆新、時間差在 30 秒內的位置")
    func guardRejectsReplays() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var guardian = PointerGuard()
        func accept(_ sentAt: Date) -> Bool { guardian.accept(PointerUpdate(mode: .laser, x: 0, y: 0, sentAt: sentAt), now: now) }
        #expect(accept(now))
        #expect(!accept(now))
        #expect(accept(now + 0.03))
        #expect(!accept(now - 1))
        #expect(!accept(now + 60))
    }
}

struct VolumeTests {
    @Test("舊版 Mac 沒送音量：解得開，手機不顯示音量")
    func oldMacHasNoVolume() throws {
        let status = LinkStatus(macName: "Mac", presence: .near, summary: "", locked: false)
        var json = try JSONSerialization.jsonObject(with: WatchMessage.encode(status)) as! [String: Any]
        json.removeValue(forKey: "volume")
        let decoded = try WatchMessage.decode(LinkStatus.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.volume == nil)
    }

    @Test func volumeRoundTrips() throws {
        let status = LinkStatus(macName: "Mac", presence: .near, summary: "", locked: false,
                                volume: MacVolume(level: 0.625, muted: true, adjustable: true))
        #expect(try WatchMessage.decode(LinkStatus.self, from: WatchMessage.encode(status)).volume == status.volume)
    }

    @Test func levelIsClamped() {
        #expect(MacVolume(level: 1.4, muted: false, adjustable: true).level == 1)
        #expect(MacVolume(level: -0.2, muted: false, adjustable: true).level == 0)
    }
}
