import Foundation
import Observation
import PresenceLink
import StoreKit

/// Presence Pro 的購買狀態：StoreKit 2，照 Folium 的做法（ADR-023）。
/// 付費的只有簡報遙控（iPhone、手錶、鎖定畫面與「捷徑」的翻頁）；鎖定、暫停、小工具與 Mac 版都免費。
/// 只在「開始簡報」「翻頁」的地方檢查，結束簡報永遠可以按。
@Observable
final class ProStore {
    static let shared = ProStore()

    /// 現在可以用 Pro。開發用的覆寫一啟動就生效，不等 StoreKit。
    private(set) var isPro = ProStore.debugOverride ?? false
    /// 有效的是買斷（設定畫面顯示「永久」）。
    private(set) var isLifetime = false
    /// 家人共享來的：訂閱只能由購買的家人管理。
    private(set) var isFamilyShared = false
    /// 有效的訂閱是哪一種（月訂、年訂；買斷或沒有訂閱是 nil）。
    private(set) var subscription: ProProduct?
    /// 訂閱下次續訂（到期）的時間。
    private(set) var renewalDate: Date?
    /// 付費畫面上的方案（月訂、年訂、買斷）；還沒載入或載入失敗是空的。
    private(set) var plans: [ProPlan] = []
    private(set) var loadError: String?
    /// 這個 Apple 帳號還能免費試用（同一個訂閱群組只能用一次）。
    private(set) var trialEligible = false

    /// 已經讀過一次購買狀態。App 為了「捷徑」或鎖定畫面的按鈕在背景啟動時，要先讀完再判斷。
    private(set) var loaded = ProStore.debugOverride != nil
    /// Pro 狀態改變時通知（同步給手錶）。
    @ObservationIgnored var onChange: ((Bool) -> Void)?
    @ObservationIgnored private var updatesTask: Task<Void, Never>?

    private init() {
        // 別台裝置買的、家人共享、續訂、退款，都從這裡進來
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                if case .verified(let transaction) = update { await transaction.finish() }
                await self?.refresh()
            }
        }
        Task { await refresh() }
    }

    /// 重新讀購買狀態（啟動、購買、恢復購買、別台裝置買了之後）。
    func refresh() async {
        var purchases: [ProPurchase] = []
        for await entitlement in Transaction.currentEntitlements {
            guard case .verified(let transaction) = entitlement else { continue }
            purchases.append(ProPurchase(productID: transaction.productID, expirationDate: transaction.expirationDate,
                                         revocationDate: transaction.revocationDate, isUpgraded: transaction.isUpgraded,
                                         isFamilyShared: transaction.ownershipType == .familyShared))
        }
        let wasPro = isPro
        isPro = Self.debugOverride ?? ProAccess.isActive(purchases)
        loaded = true
        isLifetime = ProAccess.hasLifetime(purchases)
        isFamilyShared = ProAccess.isFamilyShared(purchases)
        let active = ProAccess.activeSubscription(purchases)
        subscription = active?.product
        renewalDate = active?.renewal
        if isPro != wasPro { onChange?(isPro) }
    }

    /// 回傳能不能用 Pro；還沒讀過購買狀態就先讀。
    func checkPro() async -> Bool {
        if !loaded { await refresh() }
        return isPro
    }

    /// 載入 App Store 上的方案（付費畫面打開時）。
    func loadPlans() async {
        #if DEBUG
        if RemoteModel.isDemo {
            plans = ProPlan.demo
            trialEligible = true
            return
        }
        #endif
        do {
            let loaded = try await Product.products(for: ProProduct.allCases.map(\.rawValue))
            plans = ProProduct.allCases.compactMap { kind in loaded.first { $0.id == kind.rawValue }.map { ProPlan(kind, $0) } }
            loadError = plans.isEmpty ? String(localized: "App Store 暫時沒有提供 Presence Pro 的方案，請稍後再試。") : nil
            let subscription = loaded.first { $0.subscription != nil }?.subscription
            trialEligible = await subscription?.isEligibleForIntroOffer ?? false
        } catch {
            loadError = String(localized: "暫時無法連線到 App Store（\(error.localizedDescription)）。")
        }
    }

    /// 購買完成：記帳、更新狀態。
    func finish(_ result: Product.PurchaseResult) async {
        if case .success(let verification) = result, case .verified(let transaction) = verification {
            await transaction.finish()
        }
        await refresh()
    }

    /// 恢復購買：向 App Store 重新同步（可能要求登入 Apple 帳號）。回傳之後有沒有 Pro。
    @discardableResult
    func restore() async throws -> Bool {
        try await AppStore.sync()
        await refresh()
        return isPro
    }

    /// 開發用：`-PresencePro YES|NO` 強制 Pro 狀態（測試付費的鎖、截圖）。示範模式預設是 Pro，截圖才拍得到簡報畫面。
    private static var debugOverride: Bool? {
        #if DEBUG
        if UserDefaults.standard.object(forKey: "PresencePro") != nil { return UserDefaults.standard.bool(forKey: "PresencePro") }
        if RemoteModel.isDemo { return true }
        #endif
        return nil
    }
}

/// 付費畫面上的一個方案。平常來自 StoreKit 的 `Product`；示範模式（截圖）沒有連 App Store，用固定的價格。
struct ProPlan: Identifiable {
    let kind: ProProduct
    let displayPrice: String
    /// 年訂換算成每月多少（顯示「約每月 NT$13」）。
    let monthlyPrice: String?
    /// 免費試用幾天；沒有試用是 nil。
    let trialDays: Int?
    let product: Product?

    var id: ProProduct { kind }

    init(_ kind: ProProduct, _ product: Product) {
        self.kind = kind
        self.product = product
        displayPrice = product.displayPrice
        if kind == .yearly {
            let monthly = product.price / 12
            monthlyPrice = monthly.formatted(product.priceFormatStyle.precision(.fractionLength(0...2)))
        } else {
            monthlyPrice = nil
        }
        if let offer = product.subscription?.introductoryOffer, offer.paymentMode == .freeTrial {
            let period = offer.period
            switch period.unit {
            case .day: trialDays = period.value
            case .week: trialDays = period.value * 7
            default: trialDays = nil
            }
        } else {
            trialDays = nil
        }
    }

    #if DEBUG
    private init(kind: ProProduct, price: String, monthly: String? = nil, trial: Int? = nil) {
        self.kind = kind
        displayPrice = price
        monthlyPrice = monthly
        trialDays = trial
        product = nil
    }

    static var demo: [ProPlan] {
        let chinese = Locale.preferredLanguages.first?.hasPrefix("zh") == true
        return chinese
            ? [ProPlan(kind: .monthly, price: "NT$30", trial: 7), ProPlan(kind: .yearly, price: "NT$150", monthly: "NT$12.5", trial: 7),
               ProPlan(kind: .lifetime, price: "NT$390")]
            : [ProPlan(kind: .monthly, price: "$0.99", trial: 7), ProPlan(kind: .yearly, price: "$4.99", monthly: "$0.42", trial: 7),
               ProPlan(kind: .lifetime, price: "$12.99")]
    }
    #endif
}
