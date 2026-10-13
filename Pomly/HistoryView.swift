import SwiftUI
import SwiftData
import Charts

struct HistoryView: View {
    @Query(sort: \Session.start, order: .reverse) private var sessions: [Session]
    @Environment(\.modelContext) private var context
    @AppStorage(Pref.goalMin, store: .shared) private var goalMin = 120
    @AppStorage(Pref.theme, store: .shared) private var themeRaw = 0
    @State private var range = 7

    private var tint: Color { (Theme(rawValue: themeRaw) ?? .ember).tint }

    private struct DayTotal: Identifiable {
        let date: Date, minutes: Double
        var id: Date { date }
    }

    private var totalsByDay: [Date: Double] {
        sessions.reduce(into: [:]) { $0[Calendar.current.startOfDay(for: $1.start), default: 0] += $1.duration / 60 }
    }

    private var days: [DayTotal] {
        let cal = Calendar.current, today = cal.startOfDay(for: .now), totals = totalsByDay
        return (0..<range).reversed().compactMap { cal.date(byAdding: .day, value: -$0, to: today) }
            .map { DayTotal(date: $0, minutes: totals[$0] ?? 0) }
    }

    private var grouped: [(day: Date, items: [Session])] {
        Dictionary(grouping: sessions) { Calendar.current.startOfDay(for: $0.start) }
            .sorted { $0.key > $1.key }.map { ($0.key, $0.value) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !sessions.isEmpty { summary }
                ForEach(grouped, id: \.day) { group in
                    Section(dayTitle(group.day)) {
                        ForEach(group.items) { SessionRow(session: $0, tint: tint) }
                            .onDelete { delete(group.items, at: $0) }
                    }
                }
            }
            .pomlyBackground()
            .navigationTitle("History")
            .overlay {
                if sessions.isEmpty {
                    ContentUnavailableView("No Sessions Yet", systemImage: "timer",
                                           description: Text("Finished focus sessions appear here."))
                }
            }
        }
    }

    private var summary: some View {
        let d = days, total = d.reduce(0) { $0 + $1.minutes } * 60
        let streak = Stats.streak(Set(totalsByDay.keys), today: Calendar.current.startOfDay(for: .now))
        return Section {
            Picker("Range", selection: $range) {
                Text("Week").tag(7)
                Text("Month").tag(30)
            }
            .pickerStyle(.segmented)

            Chart {
                ForEach(d) { day in
                    BarMark(x: .value("Day", day.date, unit: .day), y: .value("Minutes", day.minutes))
                        .foregroundStyle(tint.gradient)
                        .cornerRadius(4)
                }
                RuleMark(y: .value("Goal", goalMin))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(.secondary)
                    .annotation(position: .top, alignment: .leading) { Text("Goal").font(.caption2).foregroundStyle(.secondary) }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: range == 7 ? 1 : 7)) {
                    AxisValueLabel(format: range == 7 ? .dateTime.weekday(.narrow) : .dateTime.day(), centered: true)
                }
            }
            .frame(height: 180)
            .accessibilityLabel("Focus minutes per day")

            HStack {
                stat("Total", total.minutesText)
                stat("Daily Average", (total / Double(range)).minutesText)
                stat("Streak", streak == 1 ? String(localized: "1 day") : String(localized: "\(streak) days"))
            }
        }
    }

    private func stat(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline).fontDesign(.serif).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return String(localized: "Today") }
        if cal.isDateInYesterday(day) { return String(localized: "Yesterday") }
        return day.formatted(.dateTime.weekday(.wide).month().day())
    }

    private func delete(_ items: [Session], at offsets: IndexSet) {
        let gone = offsets.map { items[$0] }
        Sync.shared.remove(gone)
        gone.forEach(context.delete)
        try? context.save()
        TimerEngine.shared.historyChanged()
    }
}
