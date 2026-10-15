import PresenceLink
import StoreKit
import SwiftUI

/// Presence Pro 的付費畫面：跟簡報畫面同一套深色舞台外觀，賣的就是那個畫面。
/// - 方案照 Folium 的做法（ADR-023）：三列同樣結構，預設選年訂，價格與週期用中文，不用 StoreKit 的 ProductView。
/// - 購買鈕固定在底部，連同價格、續訂說明、恢復購買、使用條款、隱私權政策：小螢幕也不必捲動就看得到（審查規定）。
/// - 不提還沒做的功能（講者備忘稿、雷射筆），審查會當成廣告不實。
struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.purchase) private var purchase
    @State private var selected: ProProduct = .yearly
    @State private var purchasing = false
    @State private var restoring = false
    @State private var message: String?
    private var store: ProStore { .shared }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    // 方案放在功能前面：小螢幕打開也看得到價格
                    plans
                    features
                    finePrint
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 20)
                .frame(maxWidth: 520, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
            .background { StageBackground() }
            .safeAreaInset(edge: .bottom, spacing: 0) { purchaseBar }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉", systemImage: "xmark") { dismiss() }
                }
            }
            .task { if store.plans.isEmpty { await store.loadPlans() } }
            .onChange(of: store.isPro) { _, isPro in if isPro { dismiss() } }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: 標題

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(LinearGradient.stageOrange)
                        .shadow(color: .orange.opacity(0.45), radius: 14, y: 5)
                    Image(systemName: "chevron.forward")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 38, height: 38)
                .accessibilityHidden(true)
                Text("Presence Pro")
                    .font(.headline)
                    .foregroundStyle(.orange)
            }
            Text("你的 iPhone\n就是簡報筆")
                .font(.system(.largeTitle, design: .rounded).weight(.bold))
                .fixedSize(horizontal: false, vertical: true)
            Text("不用另外買遙控器，也不用裝接收器。Mac 上的 Presence 收到指令，就幫你翻頁。")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 功能

    private static let featureRows: [(symbol: String, title: LocalizedStringKey, detail: LocalizedStringKey)] = [
        ("hand.tap.fill", "點一下或滑一下就翻頁", "上一頁、跳頁、黑畫面、開始與結束播放"),
        ("lock.iphone", "手機鎖著也能翻頁", "鎖定畫面和動態島上有翻頁按鈕"),
        ("applewatch", "Apple Watch 也是簡報筆", "點按、轉錶冠，或兩指互點"),
        ("timer", "演講倒數提醒", "剩 5 分鐘、時間到時震動提醒你"),
        ("lock.open.laptopcomputer", "走上台，Mac 也不會鎖住", "簡報中暫停自動鎖定，結束後恢復"),
    ]

    private var features: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(Self.featureRows, id: \.symbol) { row in
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: row.symbol)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.orange)
                        .frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).font(.subheadline.weight(.semibold))
                        Text(row.detail).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: 方案

    @ViewBuilder
    private var plans: some View {
        if store.plans.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if let error = store.loadError {
                    Text(error).font(.subheadline).foregroundStyle(.secondary)
                    Button("重新載入") { Task { await store.loadPlans() } }
                        .foregroundStyle(.orange)
                } else {
                    ProgressView("正在載入方案…")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background { Card(radius: 16) }
        } else {
            VStack(spacing: 10) {
                ForEach(store.plans) { plan in planRow(plan) }
            }
        }
    }

    private func planRow(_ plan: ProPlan) -> some View {
        let isSelected = selected == plan.kind
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        return Button {
            selected = plan.kind
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.orange : Color.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(name(plan.kind)).font(.headline)
                        if let badge = badge(plan.kind) {
                            Text(badge)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.black)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(LinearGradient.stageOrange, in: Capsule())
                        }
                    }
                    Text(subtitle(plan))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(plan.displayPrice).font(.headline.monospacedDigit())
                    Text(period(plan.kind)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(shape.fill(.white.opacity(isSelected ? 0.1 : 0.05)))
            .overlay(shape.strokeBorder(isSelected ? Color.orange : .white.opacity(0.09), lineWidth: isSelected ? 2 : 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func name(_ kind: ProProduct) -> String {
        switch kind {
        case .monthly: String(localized: "月訂閱")
        case .yearly: String(localized: "年訂閱")
        case .lifetime: String(localized: "一次買斷")
        }
    }

    private func badge(_ kind: ProProduct) -> String? {
        switch kind {
        case .yearly: String(localized: "最划算")
        case .monthly, .lifetime: nil
        }
    }

    private func period(_ kind: ProProduct) -> String {
        switch kind {
        case .monthly: String(localized: "每月")
        case .yearly: String(localized: "每年")
        case .lifetime: String(localized: "永久")
        }
    }

    private func subtitle(_ plan: ProPlan) -> String {
        let trial = store.trialEligible ? plan.trialDays : nil
        switch plan.kind {
        case .monthly:
            if let trial { return String(localized: "前 \(trial) 天免費，隨時可以取消") }
            return String(localized: "隨時可以取消")
        case .yearly:
            let monthly = plan.monthlyPrice.map { String(localized: "約每月 \($0)") }
            if let trial { return [String(localized: "前 \(trial) 天免費"), monthly].compactMap(\.self).joined(separator: String(localized: "，")) }
            return monthly ?? String(localized: "隨時可以取消")
        case .lifetime:
            return String(localized: "付一次，之後不再收費")
        }
    }

    private var finePrint: some View {
        Text("訂閱會自動續訂，直到你在 App Store 的帳號設定裡取消；免費試用結束前沒有取消，就會開始收費。"
             + "三種方案都可以和家人共享。鎖定、暫停、小工具，以及 Mac 上的 Presence 都是免費的。")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }

    // MARK: 購買

    private var selectedPlan: ProPlan? { store.plans.first { $0.kind == selected } }

    private var purchaseBar: some View {
        VStack(spacing: 8) {
            Button {
                Task { await buy() }
            } label: {
                Group {
                    if purchasing { ProgressView().tint(.black) } else { Text(buttonTitle) }
                }
                .font(.headline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, minHeight: 52)
                .background(LinearGradient.stageOrange, in: Capsule())
                .contentShape(Capsule())
            }
            .buttonStyle(PadStyle())
            .disabled(selectedPlan == nil || purchasing)
            .opacity(selectedPlan == nil ? 0.5 : 1)
            if let terms {
                Text(terms).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            HStack(spacing: 6) {
                Button(restoring ? "正在恢復購買…" : "恢復購買") { Task { await restore() } }
                    .disabled(restoring)
                Text("·").foregroundStyle(.secondary)
                Link("使用條款", destination: LegalLinks.terms)
                Text("·").foregroundStyle(.secondary)
                Link("隱私權政策", destination: LegalLinks.privacy)
            }
            .font(.caption)
            .tint(.orange)
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
    }

    private var buttonTitle: String {
        guard let plan = selectedPlan else { return String(localized: "訂閱") }
        if plan.kind == .lifetime { return String(localized: "購買") }
        if store.trialEligible, let days = plan.trialDays { return String(localized: "免費試用 \(days) 天") }
        return String(localized: "訂閱")
    }

    /// 購買鈕下面的一行：付多少、多久一次、會不會續訂（審查規定要在購買前看得到）。
    private var terms: String? {
        guard let plan = selectedPlan else { return nil }
        let trial = store.trialEligible ? plan.trialDays : nil
        switch plan.kind {
        case .monthly:
            if let trial { return String(localized: "\(trial) 天後每月 \(plan.displayPrice)，自動續訂，可隨時取消") }
            return String(localized: "每月 \(plan.displayPrice)，自動續訂，可隨時取消")
        case .yearly:
            if let trial { return String(localized: "\(trial) 天後每年 \(plan.displayPrice)，自動續訂，可隨時取消") }
            return String(localized: "每年 \(plan.displayPrice)，自動續訂，可隨時取消")
        case .lifetime:
            return String(localized: "\(plan.displayPrice) 一次付清，不會續訂")
        }
    }

    private func buy() async {
        guard let product = selectedPlan?.product else {
            message = String(localized: "示範模式不能購買。")
            return
        }
        purchasing = true
        defer { purchasing = false }
        message = nil
        do {
            let result = try await purchase(product)
            switch result {
            case .success: await store.finish(result)
            case .pending: message = String(localized: "正在等待核准（例如家長同意），核准後就會生效。")
            case .userCancelled: break
            @unknown default: break
            }
        } catch {
            message = String(localized: "購買沒有完成（\(error.localizedDescription)）。")
        }
    }

    private func restore() async {
        restoring = true
        defer { restoring = false }
        do {
            let restored = try await store.restore()
            message = restored ? String(localized: "已恢復 Presence Pro。") : String(localized: "這個 Apple 帳號沒有 Presence Pro 的購買紀錄。")
        } catch {
            message = String(localized: "恢復購買沒有完成（\(error.localizedDescription)）。")
        }
    }
}

enum LegalLinks {
    /// Apple 的標準授權條款（App Store Connect 沒有另外填自訂條款）。
    static let terms = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    static let privacy = URL(string: "https://github.com/chung223/Presence/blob/main/docs/privacy.md")!
}
