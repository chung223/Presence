import SwiftUI

struct HistoryView: View {
    let log: EventLog
    @State private var confirmingClear = false

    var body: some View {
        let entries = Array(log.entries.reversed())
        Table(entries) {
            TableColumn("時間") { entry in
                Text(entry.date.formatted(.dateTime.month().day().hour().minute().second()))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(min: 160, ideal: 190, max: 240)
            TableColumn("事件") { entry in
                Label {
                    Text(entry.message)
                } icon: {
                    Image(systemName: entry.kind.symbol).foregroundStyle(entry.kind.tint)
                }
            }
        }
        .overlay {
            if entries.isEmpty {
                ContentUnavailableView("還沒有事件", systemImage: "list.bullet.rectangle")
            }
        }
        .navigationTitle("紀錄")
        .toolbar {
            if let url = log.fileLocation {
                Button("在 Finder 顯示", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            Button("清除", systemImage: "trash") { confirmingClear = true }
                .disabled(entries.isEmpty)
        }
        .confirmationDialog("要清除所有紀錄嗎？", isPresented: $confirmingClear) {
            Button("清除", role: .destructive) { log.clear() }
        }
    }
}
