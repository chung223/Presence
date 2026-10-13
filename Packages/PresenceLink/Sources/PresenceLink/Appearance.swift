import SwiftUI

/// iPhone 與手錶共用的狀態外觀。
public extension MacPresence {
    var symbol: String {
        switch self {
        case .near: "iphone.radiowaves.left.and.right"
        case .leaving: "figure.walk.departure"
        case .away: "iphone.slash"
        case .waiting: "ellipsis.circle"
        case .paused: "pause.circle"
        case .suspended: "house.circle"
        case .lockPending: "hourglass"
        case .noDevice: "questionmark.circle"
        case .bluetoothOff: "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .near: .green
        case .leaving, .lockPending, .suspended: .orange
        case .paused: .blue
        case .away, .waiting: .secondary
        case .noDevice, .bluetoothOff: .yellow
        }
    }
}

public extension LinkCentral.State {
    var title: String {
        switch self {
        case .notPaired: String(localized: "尚未配對", bundle: .module)
        case .bluetoothOff: String(localized: "藍牙沒有開啟", bundle: .module)
        case .unauthorized: String(localized: "沒有藍牙權限", bundle: .module)
        case .idle: String(localized: "未連線", bundle: .module)
        case .searching: String(localized: "正在尋找 Mac", bundle: .module)
        case .connecting: String(localized: "連線中", bundle: .module)
        case .connected: String(localized: "已連線", bundle: .module)
        }
    }
}
