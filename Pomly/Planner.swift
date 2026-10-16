import SwiftUI
import EventKit

extension Pref {
    /// Settings › Advanced: suggest free gaps and log focus sessions to a "Pomly" calendar. Off by default.
    static let calendar = "calendarAware"
}

/// Calendar-aware scheduling: one quiet "you're free" suggestion and a log of finished focus.
@MainActor enum Planner {
    static var enabled: Bool {
        Pref.bool(Pref.calendar) && EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    static func requestAccess() async -> Bool { (try? await eventStore.requestFullAccessToEvents()) == true }

    /// First stretch of at least `length` between `from` and `until` that `busy` doesn't cover. Pure, for tests.
    nonisolated static func nextGap(busy: [DateInterval], from: Date, until: Date, length: TimeInterval) -> DateInterval? {
        var cursor = from
        for b in busy.sorted(by: { $0.start < $1.start }) where b.end > cursor {
            if b.start.timeIntervalSince(cursor) >= length { return DateInterval(start: cursor, end: b.start) }
            cursor = max(cursor, b.end)
        }
        return until.timeIntervalSince(cursor) >= length ? DateInterval(start: cursor, end: until) : nil
    }

    /// Next free gap today that fits `length`, from timed events in every calendar.
    static func suggestion(length: TimeInterval, now: Date = .now) -> DateInterval? {
        guard enabled, let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now)) else { return nil }
        let events = eventStore.events(matching: eventStore.predicateForEvents(withStart: now, end: end, calendars: nil))
        let busy = events.filter { !$0.isAllDay && $0.availability != .free }.map { DateInterval(start: $0.startDate, end: max($0.startDate, $0.endDate)) }
        return nextGap(busy: busy, from: now, until: end, length: length)
    }

    /// Adds a finished focus session to the "Pomly" calendar (created on first use).
    static func log(_ session: Session) {
        guard enabled, session.completed, let cal = pomlyCalendar() else { return }
        let e = EKEvent(eventStore: eventStore)
        e.calendar = cal
        e.title = session.label.isEmpty ? String(localized: "Focus") : session.label
        e.startDate = session.start
        e.endDate = session.start + session.duration
        e.availability = .busy
        try? eventStore.save(e, span: .thisEvent)
    }

    private static func pomlyCalendar() -> EKCalendar? {
        if let c = eventStore.calendars(for: .event).first(where: { $0.title == "Pomly" && $0.allowsContentModifications }) { return c }
        guard let source = eventStore.defaultCalendarForNewEvents?.source else { return nil }
        let c = EKCalendar(for: .event, eventStore: eventStore)
        c.title = "Pomly"
        c.source = source
        c.cgColor = PlatformColor(rgb: 0xB85A1E).cgColor
        return (try? eventStore.saveCalendar(c, commit: true)) != nil ? c : nil
    }
}

/// Idle focus screen: "Free until 3:30 PM · Start" (or when the next gap opens). Nothing when the calendar is off.
struct FreeGapHint: View {
    let planned: TimeInterval
    let tint: Color
    @AppStorage(Pref.calendar, store: .shared) private var on = false
    @State private var gap: DateInterval?

    var body: some View {
        Group {
            if let gap {
                if gap.start <= .now + 60 {
                    Button { Task { await TimerEngine.shared.start(.focus, seconds: planned) } } label: {
                        Text("Free until \(gap.end, format: .dateTime.hour().minute()) · Start")
                    }
                    .buttonStyle(.plain).foregroundStyle(tint)
                    .accessibilityHint("Starts a focus session")
                } else {
                    Text("Next free block at \(gap.start, format: .dateTime.hour().minute())").foregroundStyle(.secondary)
                }
            }
        }
        .font(.footnote.weight(.medium)).fontDesign(.rounded).lineLimit(1).minimumScaleFactor(0.8)
        .frame(minHeight: gap == nil ? 0 : 44)
        .task(id: "\(on)\(planned)") { gap = on ? Planner.suggestion(length: planned) : nil }
    }
}

/// Settings › Advanced row.
struct CalendarSection: View {
    @AppStorage(Pref.calendar, store: .shared) private var on = false

    var body: some View {
        Section {
            Toggle("Use Calendar", isOn: $on)
                .onChange(of: on) { _, new in
                    guard new else { return }
                    Task { if !(await Planner.requestAccess()) { on = false } }
                }
        } header: {
            Text("Calendar")
        } footer: {
            Text("Suggests a free gap today that fits a focus block and adds finished sessions to a Pomly calendar.")
        }
    }
}
