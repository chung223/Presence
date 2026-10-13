import Foundation

/// 藍牙一次通知能送的資料很少（約 180 位元組），長訊息切段送。
/// 每段開頭 3 個位元組：訊息編號、第幾段（從 0 開始）、總共幾段。
public enum LinkChunker {
    public static let headerSize = 3

    public static func split(_ data: Data, maxChunk: Int, messageID: UInt8) -> [Data] {
        let payload = max(1, maxChunk - headerSize)
        let count = max(1, (data.count + payload - 1) / payload)
        precondition(count <= 255, "訊息太長")
        return (0..<count).map { index in
            let start = data.startIndex + index * payload
            let end = min(start + payload, data.endIndex)
            return Data([messageID, UInt8(index), UInt8(count)]) + data[start..<end]
        }
    }
}

/// 把收到的分段組回完整訊息。新編號的訊息會丟掉還沒組完的舊訊息。
public struct LinkReassembler: Sendable {
    private var messageID: UInt8?
    private var parts: [Int: Data] = [:]
    private var expected = 0

    public init() {}

    /// 組完整了就回傳整段訊息；格式不對或還沒收齊回傳 nil。
    public mutating func add(_ chunk: Data) -> Data? {
        guard chunk.count >= LinkChunker.headerSize else { return nil }
        let bytes = [UInt8](chunk.prefix(LinkChunker.headerSize))
        let (id, index, count) = (bytes[0], Int(bytes[1]), Int(bytes[2]))
        guard count > 0, index < count else { return nil }
        if id != messageID || count != expected {
            messageID = id
            expected = count
            parts = [:]
        }
        parts[index] = Data(chunk.dropFirst(LinkChunker.headerSize))
        guard parts.count == expected else { return nil }
        let whole = (0..<expected).reduce(into: Data()) { $0 += parts[$1] ?? Data() }
        messageID = nil
        parts = [:]
        expected = 0
        return whole
    }
}
