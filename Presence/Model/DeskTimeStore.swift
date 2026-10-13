import Foundation
import PresenceCore

/// 在座時間存在 Application Support/Presence/desktime.json。
enum DeskTimeStore {
    private static var url: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Presence/desktime.json")
    }

    static func load() -> DeskTime {
        guard let url, let data = try? Data(contentsOf: url),
              let deskTime = try? JSONDecoder().decode(DeskTime.self, from: data) else { return DeskTime() }
        return deskTime
    }

    static func save(_ deskTime: DeskTime) {
        guard let url, let data = try? JSONEncoder().encode(deskTime) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
