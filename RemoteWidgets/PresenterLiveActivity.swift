import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

/// 簡報中的即時動態：鎖定畫面與動態島上的翻頁按鈕。按鈕由 App 執行（LiveActivityIntent），手機鎖著也能按。
/// 外觀跟 App 裡的簡報畫面一致：深色底、橘色的「下一頁」。
struct PresenterLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PresenterAttributes.self) { context in
            PresenterLockScreenView(context: context)
                .activityBackgroundTint(Color(red: 0.06, green: 0.065, blue: 0.08).opacity(0.94))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PreviousButton(size: 52).padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    NextButton(size: 52).padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        PresentingLabel()
                        ElapsedText(state: context.state)
                            .font(.system(size: 26, weight: .semibold, design: .rounded))
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    EndButton()
                }
            } compactLeading: {
                Image(systemName: "play.rectangle.fill").foregroundStyle(Color.orange)
            } compactTrailing: {
                ElapsedText(state: context.state)
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: 52)
            } minimal: {
                Image(systemName: "play.rectangle.fill").foregroundStyle(Color.orange)
            }
            .keylineTint(Color.orange)
        }
    }
}

private struct PresenterLockScreenView: View {
    let context: ActivityViewContext<PresenterAttributes>

    var body: some View {
        HStack(spacing: 16) {
            PreviousButton(size: 56)

            VStack(alignment: .leading, spacing: 4) {
                PresentingLabel()
                ElapsedText(state: context.state)
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                HStack(spacing: 8) {
                    Text(context.attributes.macName)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                    EndButton()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            NextButton(size: 72)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }
}

private struct PresentingLabel: View {
    var body: some View {
        Label("簡報中", systemImage: "play.rectangle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.orange)
    }
}

private struct NextButton: View {
    let size: CGFloat

    var body: some View {
        Button(intent: NextSlideIntent()) {
            Image(systemName: "chevron.forward")
                .font(.system(size: size * 0.38, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(LinearGradient(colors: [Color(red: 1.0, green: 0.66, blue: 0.24),
                                                                  Color(red: 0.97, green: 0.42, blue: 0.08)],
                                                         startPoint: .top, endPoint: .bottom)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("下一頁")
    }
}

private struct PreviousButton: View {
    let size: CGFloat

    var body: some View {
        Button(intent: PreviousSlideIntent()) {
            Image(systemName: "chevron.backward")
                .font(.system(size: size * 0.36, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Circle().fill(.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("上一頁")
    }
}

private struct EndButton: View {
    var body: some View {
        Button(intent: EndPresentationIntent()) {
            Text("結束簡報")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(.white.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }
}

/// 設了演講長度就倒數剩下的時間，沒設就顯示講了多久；系統自己每秒更新。
private struct ElapsedText: View {
    let state: PresenterAttributes.ContentState

    var body: some View {
        Group {
            if let endsAt = state.endsAt, endsAt > state.startedAt {
                Text(timerInterval: state.startedAt...endsAt, countsDown: true)
            } else {
                Text(timerInterval: state.startedAt...Date.distantFuture, countsDown: false)
            }
        }
        .monospacedDigit()
    }
}
