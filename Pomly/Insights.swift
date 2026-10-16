import SwiftUI

enum Insights {
    /// Hour of day (0–23) with the most focus, by session start. Pure, for tests.
    static func bestHour(_ items: [(start: Date, seconds: TimeInterval)], calendar: Calendar = .current) -> Int? {
        let byHour = items.reduce(into: [Int: TimeInterval]()) { $0[calendar.component(.hour, from: $1.start), default: 0] += $1.seconds }
        return byHour.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
    }

    /// Hour with the best average "How did it feel?" (needs 3+ ratings), and that average.
    static func bestFeel(_ items: [(start: Date, feel: Int)], calendar: Calendar = .current) -> (hour: Int, average: Double)? {
        let rated = items.filter { $0.feel > 0 }
        guard rated.count >= 3 else { return nil }
        let byHour = Dictionary(grouping: rated) { calendar.component(.hour, from: $0.start) }
            .mapValues { Double($0.reduce(0) { $0 + $1.feel }) / Double($0.count) }
        return byHour.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }.map { ($0.key, $0.value) }
    }

    static func hourText(_ h: Int) -> String {
        (Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: .now) ?? .now).formatted(.dateTime.hour())
    }
}

/// History: the last 7 days in words, best hour, feel, and a shareable recap card.
struct InsightsSection: View {
    let sessions: [Session]
    let tint: Color
    @Environment(\.colorScheme) private var scheme
    @State private var card: Image?

    private var week: [Session] {
        let start = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: .now)) ?? .now
        return sessions.filter { $0.start >= start }
    }

    var body: some View {
        let w = week, total = w.reduce(0) { $0 + $1.duration }
        let best = Insights.bestHour(w.map { ($0.start, $0.duration) })
        let feel = Insights.bestFeel(sessions.prefix(200).map { ($0.start, $0.feel) })
        let streak = Stats.streak(Set(sessions.map { Calendar.current.startOfDay(for: $0.start) }),
                                  today: Calendar.current.startOfDay(for: .now), freezes: true)
        if total > 0 {
            Section {
                Text("You focused \(total.minutesText) over \(w.count) sessions this week, about \((total / 7).minutesText) a day.")
                if let best { LabeledContent("Best Hour", value: Insights.hourText(best)) }
                if let feel {
                    LabeledContent("Feels Best", value: "\(Insights.hourText(feel.hour)) · \(feel.average.formatted(.number.precision(.fractionLength(1)))) of 5")
                }
                if let card {
                    ShareLink(item: card, preview: SharePreview("My Week in Pomly", image: card)) {
                        Label("Share Recap", systemImage: "square.and.arrow.up")
                    }
                }
            } header: {
                Text("This Week")
            } footer: {
                Text("Streaks forgive one missed day a week.")
            }
            .task(id: "\(total)\(streak)\(scheme)") {
                let r = ImageRenderer(content: RecapCard(total: total, sessions: w.count, streak: streak, best: best, tint: tint)
                    .environment(\.colorScheme, scheme))
                r.scale = 3
                card = r.cgImage.map { Image(decorative: $0, scale: 3) }
            }
        }
    }
}

/// "I focused 4 hr this week": the share card, in the app's colors for the current appearance.
struct RecapCard: View {
    let total: TimeInterval, sessions: Int, streak: Int, best: Int?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("THIS WEEK").font(.caption.weight(.semibold)).fontWidth(.expanded).tracking(1.2).foregroundStyle(.secondary)
            Text("I focused \(total.minutesText)").font(.largeTitle.weight(.bold)).fontDesign(.rounded).foregroundStyle(tint)
                .minimumScaleFactor(0.6).lineLimit(2)
            Spacer(minLength: 0)
            HStack(spacing: 18) {
                fact("\(sessions)", "Sessions")
                fact("\(streak)", "Day Streak")
                if let best { fact(Insights.hourText(best), "Best Hour") }
            }
            Text("Pomly").font(.footnote.weight(.semibold)).fontDesign(.rounded).foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(width: 360, height: 360, alignment: .leading)
        .background(AppBackground(tint: tint))
    }

    private func fact(_ value: String, _ title: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.weight(.semibold)).fontDesign(.rounded).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
}
