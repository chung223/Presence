import SwiftUI

struct MainView: View {
    enum Section: String, CaseIterable, Identifiable {
        case overview, devices, lockUnlock, general, history
        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: "總覽"
            case .devices: "裝置"
            case .lockUnlock: "鎖定與解鎖"
            case .general: "一般"
            case .history: "紀錄"
            }
        }

        var symbol: String {
            switch self {
            case .overview: "gauge.with.dots.needle.67percent"
            case .devices: "iphone.radiowaves.left.and.right"
            case .lockUnlock: "lock.shield"
            case .general: "gearshape"
            case .history: "list.bullet.rectangle"
            }
        }
    }

    @Bindable var model: AppModel
    // 啟動參數 -PresenceInitialSection <名稱> 可以指定一開始的頁面（截圖檢查用）
    @State private var selection: Section? = Section(
        rawValue: UserDefaults.standard.string(forKey: "PresenceInitialSection") ?? ""
    ) ?? .overview

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            switch selection ?? .overview {
            case .overview: OverviewView(model: model, selection: $selection)
            case .devices: DevicesView(model: model)
            case .lockUnlock: LockUnlockView(model: model)
            case .general: GeneralView(model: model)
            case .history: HistoryView(log: model.log)
            }
        }
        .onAppear { NSApp.setActivationPolicy(.regular) }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
}
