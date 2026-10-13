import SwiftUI

struct MainView: View {
    enum Section: String, CaseIterable, Identifiable {
        case overview, devices, lockUnlock, context, deskTime, remote, general, history
        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: String(localized: "總覽")
            case .devices: String(localized: "裝置")
            case .lockUnlock: String(localized: "鎖定與解鎖")
            case .context: String(localized: "情境")
            case .deskTime: String(localized: "在座時間")
            case .remote: String(localized: "手機與手錶")
            case .general: String(localized: "一般")
            case .history: String(localized: "紀錄")
            }
        }

        var symbol: String {
            switch self {
            case .overview: "gauge.with.dots.needle.67percent"
            case .devices: "iphone.radiowaves.left.and.right"
            case .lockUnlock: "lock.shield"
            case .context: "house"
            case .deskTime: "chair"
            case .remote: "applewatch.radiowaves.left.and.right"
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
            case .context: ContextView(model: model)
            case .deskTime: DeskTimeView(model: model)
            case .remote: RemoteDevicesView(model: model)
            case .general: GeneralView(model: model)
            case .history: HistoryView(log: model.log)
            }
        }
        .onAppear { NSApp.setActivationPolicy(.regular) }
        .onDisappear { NSApp.setActivationPolicy(.accessory) }
    }
}
