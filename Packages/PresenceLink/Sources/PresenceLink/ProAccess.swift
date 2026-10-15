import Foundation

/// Presence Pro 的商品：月訂、年訂（訂閱群組「Presence Pro」，都有 7 天免費試用）或買斷，都可以家人共享。
/// 2026-10-15 產品負責人決定：簡報遙控是付費功能；鎖定、暫停、小工具與 Mac 版維持免費。
/// 順序就是付費畫面上的順序。iPhone 與手錶是同一個 App 紀錄，買一次兩邊都能用。
public enum ProProduct: String, CaseIterable, Sendable {
    case monthly = "com.chung.presence.pro.monthly"
    case yearly = "com.chung.presence.pro.yearly"
    case lifetime = "com.chung.presence.pro.lifetime"

    /// 自動續訂（月訂、年訂）。
    public var isSubscription: Bool { self != .lifetime }
}

/// 一筆購買紀錄裡判斷 Pro 用得到的部分（App 從 StoreKit 的 `Transaction` 取出來，這裡不碰 StoreKit，好測試）。
public struct ProPurchase: Sendable, Equatable {
    public var productID: String
    /// 訂閱的到期時間；買斷是 nil。
    public var expirationDate: Date?
    /// 退款或家人共享被取消的時間。
    public var revocationDate: Date?
    /// 已經換成同一組的其他訂閱。
    public var isUpgraded: Bool
    /// 家人共享來的（不是這個 Apple 帳號自己買的）。
    public var isFamilyShared: Bool

    public init(productID: String, expirationDate: Date? = nil, revocationDate: Date? = nil,
                isUpgraded: Bool = false, isFamilyShared: Bool = false) {
        self.productID = productID
        self.expirationDate = expirationDate
        self.revocationDate = revocationDate
        self.isUpgraded = isUpgraded
        self.isFamilyShared = isFamilyShared
    }
}

public enum ProAccess {
    /// 有沒有可以用的 Pro：任何一筆是 Presence Pro 的商品、沒有被退款或取消、沒有被換掉，而且（訂閱的話）還沒到期。
    public static func isActive(_ purchases: [ProPurchase], now: Date = Date()) -> Bool {
        purchases.contains { isValid($0, now: now) }
    }

    /// 有效的那一筆是買斷（設定畫面顯示「永久」而不是續訂日）。
    public static func hasLifetime(_ purchases: [ProPurchase]) -> Bool {
        purchases.contains { $0.productID == ProProduct.lifetime.rawValue && $0.revocationDate == nil }
    }

    /// 有效的購買全部來自家人共享（設定畫面註明，訂閱也只能由購買的家人管理）。
    public static func isFamilyShared(_ purchases: [ProPurchase], now: Date = Date()) -> Bool {
        let valid = purchases.filter { isValid($0, now: now) }
        return !valid.isEmpty && valid.allSatisfy(\.isFamilyShared)
    }

    /// 目前有效的訂閱（設定畫面顯示「月訂」「年訂」與下次續訂日）：到期最晚的那一筆。
    public static func activeSubscription(_ purchases: [ProPurchase], now: Date = Date()) -> (product: ProProduct, renewal: Date)? {
        purchases.compactMap { purchase -> (ProProduct, Date)? in
            guard let product = ProProduct(rawValue: purchase.productID), product.isSubscription,
                  isValid(purchase, now: now), let expiration = purchase.expirationDate else { return nil }
            return (product, expiration)
        }
        .max { $0.1 < $1.1 }
    }

    private static func isValid(_ purchase: ProPurchase, now: Date) -> Bool {
        guard ProProduct(rawValue: purchase.productID) != nil, purchase.revocationDate == nil, !purchase.isUpgraded else { return false }
        guard let expiration = purchase.expirationDate else { return true }
        return expiration > now
    }
}
