import WidgetKit
import SwiftUI

/// Watch face complications: the live countdown while a session runs, today's focus otherwise.
@main
struct PomlyWatchWidgets: WidgetBundle {
    var body: some Widget { PomlyComplication() }
}

struct ComplicationEntry: TimelineEntry {
    let date: Date
    let snap: TimerSnapshot
    let today: TimeInterval
}

struct ComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> ComplicationEntry { ComplicationEntry(date: .now, snap: TimerSnapshot(), today: 0) }
    func getSnapshot(in context: Context, completion: @escaping (ComplicationEntry) -> Void) { completion(entry()) }

    /// One entry: the text counts down by itself. Refresh when the session ends, else at midnight for "today".
    func getTimeline(in context: Context, completion: @escaping (Timeline<ComplicationEntry>) -> Void) {
        let e = entry()
        let next = e.snap.status == .running ? (e.snap.endDate ?? .now) : Calendar.current.startOfDay(for: .now.addingTimeInterval(86_400))
        completion(Timeline(entries: [e], policy: .after(next)))
    }

    private func entry() -> ComplicationEntry { ComplicationEntry(date: .now, snap: TimerSnapshot.load(), today: Today.seconds()) }
}

struct PomlyComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "PomlyWatch", provider: ComplicationProvider()) { ComplicationView(entry: $0) }
            .configurationDisplayName("Pomly")
            .description("Your focus timer at a glance.")
            .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryCorner, .accessoryInline])
    }
}

struct ComplicationView: View {
    let entry: ComplicationEntry
    @Environment(\.widgetFamily) private var family

    private var s: TimerSnapshot { entry.snap }
    private var tint: Color { Theme.current.tint }
    private var end: Date? { s.status == .running ? s.endDate.flatMap { $0 > entry.date ? $0 : nil } : nil }
    private var todayMin: Int { Int(entry.today / 60) }
    private var goal: Double { min(entry.today / Double(max(Pref.int(Pref.goalMin), 1) * 60), 1) }
    private var phase: LocalizedStringKey { s.status == .paused ? "PAUSED" : s.phase == .focus ? "FOCUS" : "BREAK" }

    var body: some View {
        content.containerBackground(.clear, for: .widget)
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryCircular:
            if let end {
                ProgressView(timerInterval: end.addingTimeInterval(-s.planned)...end, countsDown: true) { EmptyView() } currentValueLabel: {
                    Text(timerInterval: entry.date...end, countsDown: true, showsHours: false)
                        .font(.system(size: 11, weight: .semibold, design: .rounded)).monospacedDigit()
                }
                .progressViewStyle(.circular).tint(tint)
            } else {
                Gauge(value: goal) { Image(systemName: "timer") } currentValueLabel: { Text("\(todayMin)").fontDesign(.rounded) }
                    .gaugeStyle(.accessoryCircular).tint(tint)
            }
        case .accessoryCorner:
            Image(systemName: s.phase == .focus ? "timer" : "cup.and.saucer.fill").font(.title3).foregroundStyle(tint)
                .widgetLabel {
                    if let end { Text(timerInterval: entry.date...end, countsDown: true) } else { Text("\(todayMin) min") }
                }
        case .accessoryInline:
            if let end { Text(timerInterval: entry.date...end, countsDown: true) } else { Text("\(todayMin) min focus today") }
        default:
            VStack(alignment: .leading, spacing: 1) {
                Text(s.isActive ? phase : "TODAY").font(.system(size: 11, weight: .semibold)).fontWidth(.expanded).foregroundStyle(tint)
                Group {
                    if let end { Text(timerInterval: entry.date...end, countsDown: true) }
                    else if s.status == .paused { Text(s.remaining.clock) }
                    else { Text("\(todayMin) min") }
                }
                .font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(s.label.isEmpty ? String(localized: "Pomly") : s.label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
