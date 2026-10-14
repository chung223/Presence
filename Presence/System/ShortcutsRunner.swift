import Foundation

/// 用系統內建的 `shortcuts` 指令列出與執行「捷徑」。
enum ShortcutsRunner {
    private nonisolated static let tool = URL(fileURLWithPath: "/usr/bin/shortcuts")

    static func list() async -> [String] {
        await Task.detached { () -> [String] in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = tool
            process.arguments = ["list"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return []
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)?
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending } ?? []
        }.value
    }

    /// 在背景執行，不等它結束。
    static func run(_ name: String) {
        if Demo.isActive { return }
        let process = Process()
        process.executableURL = tool
        process.arguments = ["run", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
