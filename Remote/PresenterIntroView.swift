import SwiftUI

/// 更新後第一次打開時介紹簡報遙控（只出現一次）：能做什麼、Mac 上要先打開什麼。
struct PresenterIntroView: View {
    let isPro: Bool
    /// true：使用者想馬上試（沒有 Pro 會接著打開付費畫面）。
    let done: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("新功能").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
                        Text("iPhone 變成簡報筆")
                            .font(.system(.largeTitle, design: .rounded).weight(.bold))
                        Text("站在台上，用手機或手錶翻 Mac 上的簡報。Keynote、PowerPoint、Google 簡報、PDF 都可以。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 36)

                    VStack(alignment: .leading, spacing: 16) {
                        point("hand.tap.fill", "點一下或滑一下就翻頁", "手機鎖著也能在鎖定畫面翻頁")
                        point("applewatch", "Apple Watch 也能翻頁", "點按、轉錶冠，或兩指互點")
                        point("timer", "演講倒數", "剩 5 分鐘、時間到時震動提醒")
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("開始前").font(.headline)
                        step(1, "把 Mac 上的 Presence 更新到最新版")
                        step(2, "在 Mac 的 Presence 打開「手機與手錶 › 允許簡報遙控」")
                        step(3, "回到這裡，點「簡報遙控」")
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background { Card(radius: 18) }

                    if !isPro {
                        Text("簡報遙控是 Presence Pro 的功能，訂閱可以免費試用。鎖定、暫停、小工具照樣免費。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 24)
            }
            .scrollIndicators(.hidden)

            VStack(spacing: 6) {
                Button { done(true) } label: {
                    Text(isPro ? "開始簡報遙控" : "看看 Presence Pro")
                        .font(.headline)
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity, minHeight: 52)
                        .background(LinearGradient.stageOrange, in: Capsule())
                }
                .buttonStyle(PadStyle())
                Button("之後再說") { done(false) }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 40)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 8)
        }
        .background { StageBackground() }
        .preferredColorScheme(.dark)
        .presentationDragIndicator(.visible)
    }

    private func point(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.orange)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(number.formatted())
                .font(.caption.weight(.bold))
                .foregroundStyle(.black)
                .frame(width: 20, height: 20)
                .background(Circle().fill(.orange))
            Text(text).font(.subheadline)
        }
    }
}
