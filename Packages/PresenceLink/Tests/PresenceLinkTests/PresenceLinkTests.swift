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
