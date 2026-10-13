import Charts
import PresenceCore
import SwiftUI

/// 在座時間：今天坐了多久、最近 7 天的趨勢，以及久坐提醒。
struct DeskTimeView: View {
    @Bindable var model: AppModel

    private struct Day: Identifiable {
        let date: Date
        let hours: Double
        var id: Date { date }
    }

    var body: some View {
        let calendar = Calendar.current
        let now = model.now
        let desk = model.deskTime
        let days = (0..<7).reversed().compactMap { offset -> Day? in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now)) else { return nil }
            return Day(date: date, hours: desk.total(on: date, calendar: calendar, now: now) / 3600)
        }

        Form {
            Section {
                HStack(spacing: 12) {
                    tile("今天在座", desk.total(on: now, calendar: calendar, now: now))
                    tile("目前這一段", desk.currentDuration(at: now))
                    tile("今天最長的一段", desk.longestSession(on: now, calendar: calendar, now: now))
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            Section("最近 7 天") {
                Chart(days) { day in
                    BarMark(
                        x: .value("日期", day.date, unit: .day),
                        y: .value("小時", day.hours)
                    )
                    .foregroundStyle(calendar.isDate(day.date, inSameDayAs: now) ? AnyShapeStyle(.tint) : AnyShapeStyle(.tint.opacity(0.45)))
                    .cornerRadius(4)
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) {
                        AxisValueLabel(format: .dateTime.weekday(.narrow))
                    }
                }
                .chartYAxisLabel("小時")
                .chartYScale(domain: 0...max(1, days.map(\.hours).max() ?? 0))
                .frame(height: 180)
                .padding(.vertical, 6)
            }

            Section {
                Toggle("久坐提醒", isOn: $model.preferences.sittingReminderEnabled)
                Picker("連續坐多久提醒一次", selection: $model.preferences.sittingReminderInterval) {
                    ForEach([30, 45, 60, 90, 120] as [TimeInterval], id: \.self) { minutes in
                        Text(AppModel.describe(minutes * 60)).tag(minutes * 60)
                    }
                }
                .disabled(!model.preferences.sittingReminderEnabled)
            } footer: {
                Text("依裝置在附近的時間計算；離開不到 3 分鐘（例如去倒杯水）算同一段。紀錄只存在這台 Mac 上，保留 60 天。")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("在座時間")
    }

    private func tile(_ title: LocalizedStringKey, _ duration: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout).foregroundStyle(.secondary)
            Text(Self.format(duration))
                .font(.title2.weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.background.secondary, in: .rect(cornerRadius: 12))
    }

    /// 例如「2 小時 15 分鐘」、「0 分鐘」。
    static func format(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = duration < 3600 ? [.minute] : [.hour, .minute]
        formatter.unitsStyle = .short
        return formatter.string(from: max(0, duration)) ?? ""
    }
}
