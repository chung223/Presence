import Foundation
import Observation
import os

/// 鎖定、解鎖等事件的紀錄。存在 Application Support/Presence/events.json，最多保留 500 筆。
/// 不記錄 RSSI 的每一筆樣本，也絕不記錄密碼或其長度。
@Observable
final class EventLog {
    enum Kind: String, Codable {
        case locked, unlocked, manualUnlock, intruded, unlockFailed, warning, info

        var symbol: String {
            switch self {
            case .locked: "lock.fill"
            case .unlocked: "lock.open.fill"
            case .manualUnlock: "hand.raised.fill"
            case .intruded: "person.fill.questionmark"
            case .unlockFailed: "xmark.octagon.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .info: "info.circle"
            }
        }
    }

    struct Entry: Codable, Identifiable, Equatable {
        var id = UUID()
        let date: Date
        let kind: Kind
        let message: String
        /// 附加的檔案（例如拍照存證的照片）路徑。
        var attachment: String?
    }

    private(set) var entries: [Entry] = []

    @ObservationIgnored private let fileURL: URL?
    @ObservationIgnored private let logger = Logger(subsystem: "com.chung.presence", category: "events")
    private static let limit = 500

    init(directory: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Presence", isDirectory: true)) {
        if let directory {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            fileURL = directory.appendingPathComponent("events.json")
        } else {
            fileURL = nil
        }
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    func add(_ kind: Kind, _ message: String, attachment: URL? = nil) {
        logger.info("[\(kind.rawValue, privacy: .public)] \(message, privacy: .public)")
        entries.append(Entry(date: Date(), kind: kind, message: message, attachment: attachment?.path))
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        save()
    }

    #if DEBUG
    /// 示範模式：換成假的紀錄（不存檔，見 `Demo`）。
    func seedDemo(_ demo: [Entry]) {
        entries = demo
    }
    #endif

    func clear() {
        entries.removeAll()
        save()
    }

    var fileLocation: URL? { fileURL }

    private func save() {
        guard let fileURL, let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
