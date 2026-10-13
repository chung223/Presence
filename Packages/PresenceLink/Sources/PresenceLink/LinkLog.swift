import Foundation
import os

/// 連線過程的簡單紀錄，寫在 App 的 Documents/link-log.txt，
/// 開發時可以用 `xcrun devicectl device copy from` 取回。不記錄金鑰或指令內容以外的資料。
public enum LinkLog {
    private static let logger = Logger(subsystem: "com.chung.presence.link", category: "link")
    private static let maxBytes = 200_000

    private static var url: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("link-log.txt")
    }

    public static func write(_ message: String) {
        logger.info("\(message, privacy: .public)")
        guard let url else { return }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        let line = Data("\(f.string(from: Date())) \(message)\n".utf8)
        // 太大就從頭開始，避免無限長大
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int), size > maxBytes {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
            try? handle.close()
        } else {
            try? line.write(to: url)
        }
    }
}
