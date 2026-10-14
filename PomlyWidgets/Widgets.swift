import WidgetKit
import SwiftUI
import AppIntents
import AlarmKit
import ActivityKit

@main
struct PomlyWidgets: WidgetBundle {
    var body: some Widget {
        StatusWidget()
        FocusControl()
        FocusLiveActivity()
        FallbackLiveActivity()
    }
}

// MARK: - Timeline

struct StatusEntry: TimelineEntry {
    let date: Date
    let snap: TimerSnapshot
    let today: TimeInterval
    let sessions: Int
    let goal: Int        // minutes
    let focusMin: Int
}

struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry {
        StatusEntry(date: .now, snap: TimerSnapshot(), today: 50 * 60, sessions: 2, goal: 120, focusMin: 25)
    }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entries(from: .now)[0])
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        let now = Date.now
        let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: now))!
        completion(Timeline(entries: entries(from: now), policy: .after(midnight)))
    }

    /// One entry a minute while running so the dial drains (seconds tick live via Text(timerInterval:)), plus one at the end.
    private func entries(from now: Date) -> [StatusEntry] {
        let snap = TimerSnapshot.load()
        let make = { (d: Date) in
            StatusEntry(date: d, snap: snap, today: Today.seconds(), sessions: Today.count(),
                        goal: Pref.int(Pref.goalMin), focusMin: Pref.int(Pref.focusMin))
        }
        guard snap.status == .running, let end = snap.endDate, end > now else { return [make(now)] }
        return (Array(stride(from: now, to: end, by: 60).prefix(180)) + [end]).map(make)
    }
}

// MARK: - Home Screen, Lock Screen, StandBy

struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Status", provider: StatusProvider()) { StatusView(entry: $0) }
            .configurationDisplayName("Pomly")
            .description("Your timer and today's focus. The large size starts sessions too.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge,
                                .accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

/// Wide small caps used across widgets and Live Activities.
struct Caps: View {
    let text: String
    var size: CGFloat = 11
    var color: Color?

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: .semibold)).fontWidth(.expanded).tracking(size * 0.1)
            .lineLimit(1).minimumScaleFactor(0.7)
            .foregroundStyle(color.map { AnyShapeStyle($0) } ?? AnyShapeStyle(.secondary))
    }
}

struct StatusView: View {
    let entry: StatusEntry
    @Environment(\.widgetFamily) private var family

    private var s: TimerSnapshot { entry.snap }
    private var tint: Color { Theme.current.tint }
    private var end: Date? { s.status == .running ? s.endDate.flatMap { $0 > entry.date ? $0 : nil } : nil }
    private var paused: Bool { s.status == .paused }
    private var active: Bool { end != nil || paused }
    private var goalSeconds: TimeInterval { TimeInterval(entry.goal * 60) }
    private var goalProgress: Double { min(entry.today / max(goalSeconds, 1), 1) }
    private var remaining: TimeInterval { end.map { $0.timeIntervalSince(entry.date) } ?? s.remaining }
    private var dialFraction: Double { active ? remaining / max(s.planned, 1) : goalProgress }
    private var phase: String { s.phase == .focus ? String(localized: "Focus") : String(localized: "Break") }
    private var icon: String { s.phase == .focus ? "timer" : "cup.and.saucer.fill" }
    private var sessionGoal: Int { SessionBars.goal(goalMin: entry.goal, focusMin: entry.focusMin) }
    private var title: String { s.label.isEmpty ? (s.phase == .focus ? String(localized: "Deep focus") : String(localized: "Recharge")) : s.label }

    var body: some View {
        content.containerBackground(for: .widget) { AppBackground(tint: tint) }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .accessoryInline: inline
        case .systemMedium: medium
        case .systemLarge, .systemExtraLarge: large
        default: small
        }
    }

    private func countdown(_ end: Date) -> Text {
        Text(timerInterval: min(entry.date, end)...end, countsDown: true)
    }

    /// Live countdown, paused time, or nil when idle.
    private var timeText: Text? {
        if let end { return countdown(end) }
        return paused ? Text(s.remaining.clock) : nil
    }

    // MARK: Pieces

    /// "TODAY / 45 min / bars".
    private var todayBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            Caps(text: String(localized: "Today"))
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(entry.today / 60))").font(.system(size: 46, weight: .regular, design: .rounded)).monospacedDigit()
                Text("min").font(.system(size: 15, design: .rounded)).foregroundStyle(.secondary)
            }
            .lineLimit(1).minimumScaleFactor(0.6)
            SessionBars(done: entry.sessions, goal: sessionGoal, tint: tint, height: 12).widgetAccentable()
        }
    }

    /// "● 24:24 focus" when a session is on.
    @ViewBuilder private var statusLine: some View {
        if let time = timeText {
            HStack(spacing: 6) {
                Circle().fill(tint).frame(width: 6, height: 6)
                time.font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
                Text(paused ? String(localized: "paused") : phase.lowercased())
                    .font(.system(size: 13, design: .rounded)).foregroundStyle(.secondary)
            }
            .lineLimit(1).minimumScaleFactor(0.7)
        }
    }

    /// The app's dial with the time (or today's minutes) inside.
    private func dial(_ digits: CGFloat) -> some View {
        ZStack {
            DialFace(fraction: dialFraction, tint: tint, showsKnob: active).widgetAccentable()
            VStack(spacing: 2) {
                Group {
                    if let time = timeText { time } else { Text("\(Int(goalProgress * 100))%") }
                }
                .font(.system(size: digits, weight: .regular, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.5).multilineTextAlignment(.center)
                Caps(text: active ? (paused ? String(localized: "Paused") : phase) : String(localized: "Goal"), size: digits * 0.36)
            }
            .padding(.horizontal, digits * 0.6)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    @ViewBuilder private func pill(_ intent: some AppIntent, _ title: LocalizedStringKey, _ icon: String, prominent: Bool = true) -> some View {
        let label = Label(title, systemImage: icon).font(.caption.weight(.semibold)).lineLimit(1).frame(maxWidth: .infinity)
        if prominent {
            Button(intent: intent) { label.foregroundStyle(Theme.onTint) }.buttonStyle(.borderedProminent).tint(tint)
        } else {
            Button(intent: intent) { label }.buttonStyle(.bordered).tint(tint)
        }
    }

    private var close: some View {
        Button(intent: StopIntent()) { Image(systemName: "xmark").font(.caption.weight(.bold)) }
            .buttonStyle(.bordered).buttonBorderShape(.circle).tint(tint)
            .accessibilityLabel("End Session")
    }

    @ViewBuilder private var pauseOrResume: some View {
        if paused { pill(ResumeIntent(), "Resume", "play.fill") } else { pill(PauseIntent(), "Pause", "pause.fill") }
    }

    // MARK: Home Screen

    private var small: some View {
        VStack(alignment: .leading, spacing: 0) {
            todayBlock
            Spacer(minLength: 6)
            if active { statusLine } else { pill(StartFocusIntent(), "Focus", "play.fill") }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var medium: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 0) {
                todayBlock
                Spacer(minLength: 6)
                if active { statusLine } else { pill(StartFocusIntent(), "Focus", "play.fill") }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Rectangle().fill(.secondary.opacity(0.2)).frame(width: 1)
            VStack(spacing: 6) {
                dial(20)
                Text(active ? title : String(localized: "of \(goalSeconds.minutesText)"))
                    .font(.system(size: 14, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity)
        }
    }

    /// Interactive: see the session, or start one at any length without opening the app.
    private var large: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                todayBlock
                Spacer()
                Caps(text: String(localized: "of \(goalSeconds.minutesText)"))
            }
            HStack(spacing: 16) {
                dial(26).frame(width: 136, height: 136)
                VStack(alignment: .leading, spacing: 6) {
                    Caps(text: active ? (s.phase == .focus ? String(localized: "Focusing on") : String(localized: "On a break")) : String(localized: "Ready"), color: tint)
                    Text(active ? title : String(localized: "Pick a length"))
                        .font(.system(size: 24, weight: .regular, design: .rounded)).lineLimit(1).minimumScaleFactor(0.6)
                    if let end {
                        Text("Ends at \(end, format: .dateTime.hour().minute())")
                            .font(.system(size: 15, weight: .semibold, design: .rounded)).foregroundStyle(tint).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            if active {
                HStack(spacing: 8) {
                    pauseOrResume
                    if s.phase == .focus { pill(StartBreakIntent(), "Break", "cup.and.saucer.fill", prominent: false) }
                    else { pill(StartFocusIntent(), "Focus", "timer", prominent: false) }
                    close
                }
            } else {
                HStack(spacing: 8) {
                    ForEach([15, 25, 45, 60], id: \.self) { m in
                        Button(intent: StartFocusIntent(minutes: m)) {
                            VStack(spacing: 0) {
                                Text("\(m)").font(.system(size: 20, weight: .regular, design: .rounded))
                                Text("min").font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered).tint(tint)
                        .accessibilityLabel("Focus for \(m) minutes")
                    }
                    // Break shares the row, so the large widget never overflows its margins.
                    Button(intent: StartBreakIntent()) {
                        Image(systemName: "cup.and.saucer.fill").font(.system(size: 17)).frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered).tint(tint)
                    .accessibilityLabel("Take a Break")
                }
            }
        }
    }

    // MARK: Lock Screen

    @ViewBuilder private var circular: some View {
        if let end {
            ProgressView(timerInterval: end.addingTimeInterval(-s.planned)...end, countsDown: true) {
                EmptyView()
            } currentValueLabel: {
                Image(systemName: icon).font(.title3)
            }
            .progressViewStyle(.circular)
            .widgetAccentable()
        } else {
            Gauge(value: active ? dialFraction : goalProgress) {
                Image(systemName: active ? "pause.fill" : "timer")
            } currentValueLabel: {
                Text(active ? s.remaining.clock : "\(Int(entry.today / 60))").font(.system(.body, design: .rounded))
            }
            .gaugeStyle(.accessoryCircularCapacity)
        }
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text((active ? (s.label.isEmpty ? phase : "\(phase) · \(s.label)") : String(localized: "Today")).uppercased())
                .font(.system(size: 11, weight: .semibold)).fontWidth(.expanded).lineLimit(1).widgetAccentable()
            Group {
                if let time = timeText { time } else { Text(entry.today.minutesText) }
            }
            .font(.system(size: 26, weight: .regular, design: .rounded)).monospacedDigit().lineLimit(1)
            if let end {
                ProgressView(timerInterval: end.addingTimeInterval(-s.planned)...end, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
                    .progressViewStyle(.linear)
            } else {
                Gauge(value: active ? dialFraction : goalProgress) { EmptyView() }.gaugeStyle(.accessoryLinearCapacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var inline: some View {
        if let end {
            Text("\(phase) · \(countdown(end))")
        } else if paused {
            Text("\(phase) paused · \(s.remaining.clock)")
        } else {
            Label("\(entry.today.minutesText) today", systemImage: "timer")
        }
    }
}

// MARK: - Control Center / Lock Screen / Action Button

struct FocusControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "FocusControl", provider: FocusValue()) { isOn in
            ControlWidgetToggle("Focus", isOn: isOn, action: ToggleFocusIntent()) { on in
                Label(on ? "Focusing" : "Start Focus", systemImage: on ? "timer" : "play.fill")
            }
            .tint(Theme.current.tint)
        }
        .displayName("Pomly Focus")
        .description("Start or end a focus session.")
    }
}

struct FocusValue: ControlValueProvider {
    var previewValue: Bool { false }
    func currentValue() async throws -> Bool { TimerSnapshot.load().isActive }
}

// MARK: - Live Activity (Lock Screen, Dynamic Island, StandBy)

/// Driven by AlarmKit.
struct FocusLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AlarmAttributes<PomlyMetadata>.self) { ctx in
            LiveLockScreen(live: LiveInfo(state: LiveState(ctx.state.mode), meta: ctx.attributes.metadata, tint: ctx.attributes.tintColor))
        } dynamicIsland: { ctx in
            liveIsland(LiveInfo(state: LiveState(ctx.state.mode), meta: ctx.attributes.metadata, tint: ctx.attributes.tintColor))
        }
        .supplementalActivityFamilies([.small]) // Apple Watch Smart Stack and the Mac menu bar
    }
}

/// Driven by the app when AlarmKit isn't allowed.
struct FallbackLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PomlyActivityAttributes.self) { ctx in
            LiveLockScreen(live: LiveInfo(state: LiveState(ctx.state), meta: PomlyMetadata(phase: ctx.attributes.phase, label: ctx.attributes.label), tint: Theme.current.tint))
        } dynamicIsland: { ctx in
            liveIsland(LiveInfo(state: LiveState(ctx.state), meta: PomlyMetadata(phase: ctx.attributes.phase, label: ctx.attributes.label), tint: Theme.current.tint))
        }
        .supplementalActivityFamilies([.small]) // Apple Watch Smart Stack and the Mac menu bar
    }
}

/// Everything a Live Activity view needs, from either source.
struct LiveInfo {
    let state: LiveState
    let meta: PomlyMetadata?
    let tint: Color

    var rest: Bool { meta?.phase == .rest }
    var phase: String {
        if state.done { return String(localized: "Done") }
        let p = rest ? String(localized: "Break") : String(localized: "Focus")
        return state.end == nil ? "\(p) · \(String(localized: "Paused"))" : p
    }
    var title: String {
        if let l = meta?.label, !l.isEmpty { return l }
        return rest ? String(localized: "Recharge") : String(localized: "Deep focus")
    }
}

private func liveIsland(_ live: LiveInfo) -> DynamicIsland {
    let style = LiveStyle.current
    return DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
            Group {
                switch style {
                case .controls: LiveButtons(live: live)
                case .minimal: LiveRing(live: live).frame(width: 40, height: 40)
                case .ruler: LiveTitles(live: live)
                }
            }
            .padding(.leading, 8)
        }
        DynamicIslandExpandedRegion(.trailing) {
            VStack(alignment: .trailing, spacing: 0) {
                if style == .controls { Caps(text: live.phase, size: 10, color: live.tint) }
                LiveClock(state: live.state).font(.system(size: 36, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            .padding(.trailing, 8)
        }
        DynamicIslandExpandedRegion(.bottom) {
            Group {
                switch style {
                case .ruler: LiveRuler(live: live)
                case .controls: LiveBar(live: live)
                case .minimal: Caps(text: live.title, size: 10)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
        }
    } compactLeading: {
        LiveRing(live: live).frame(width: 18, height: 18).padding(.leading, 2)
    } compactTrailing: {
        LiveClock(state: live.state).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit()
            .foregroundStyle(live.tint).frame(maxWidth: 56)
    } minimal: {
        LiveRing(live: live)
    }
    .keylineTint(live.tint)
}

struct LiveLockScreen: View {
    let live: LiveInfo
    @Environment(\.isActivityFullscreen) private var fullscreen
    @Environment(\.activityFamily) private var activityFamily

    var body: some View {
        Group {
            if activityFamily == .small { watch } else if fullscreen { standBy } else {
                switch LiveStyle.current {
                case .ruler: ruler
                case .controls: controls
                case .minimal: minimal
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .activitySystemActionForegroundColor(live.tint)
    }

    private var ruler: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                LiveRing(live: live).frame(width: 44, height: 44)
                LiveTitles(live: live)
                Spacer(minLength: 8)
                LiveClock(state: live.state).font(.system(size: 42, weight: .semibold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.6).multilineTextAlignment(.trailing).frame(width: 132, alignment: .trailing)
            }
            LiveRuler(live: live)
        }
    }

    private var controls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Caps(text: live.phase, color: live.tint)
                    LiveClock(state: live.state).font(.system(size: 42, weight: .semibold, design: .rounded)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.6).frame(width: 150, alignment: .leading)
                }
                Spacer(minLength: 8)
                LiveButtons(live: live)
            }
            LiveBar(live: live)
        }
    }

    private var minimal: some View {
        HStack(spacing: 14) {
            LiveRing(live: live).frame(width: 40, height: 40)
            LiveTitles(live: live)
            Spacer(minLength: 8)
            LiveClock(state: live.state).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.6).multilineTextAlignment(.trailing).frame(width: 108, alignment: .trailing)
        }
    }

    /// Apple Watch Smart Stack: ring, phase and the countdown, nothing else.
    private var watch: some View {
        HStack(spacing: 10) {
            LiveRing(live: live).frame(width: 30, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Caps(text: live.phase, size: 10, color: live.tint)
                LiveClock(state: live.state).font(.system(size: 24, weight: .semibold, design: .rounded)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    /// StandBy: the glowing dial with the time, and what you're focusing on.
    private var standBy: some View {
        HStack(spacing: 28) {
            ZStack {
                DialFace(fraction: live.state.done ? 0 : 1, tint: live.tint, showsKnob: false)
                VStack(spacing: 4) {
                    LiveClock(state: live.state).font(.system(size: 44, weight: .regular, design: .rounded)).monospacedDigit()
                    Caps(text: live.rest ? String(localized: "Break") : String(localized: "Focus"), size: 12)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            VStack(alignment: .leading, spacing: 8) {
                Caps(text: live.rest ? String(localized: "On a break") : String(localized: "Focusing on"), size: 14, color: .white.opacity(0.8))
                Text(live.title).font(.system(size: 40, weight: .regular, design: .rounded)).lineLimit(1).minimumScaleFactor(0.5)
                if let end = live.state.end {
                    Text("Ends at \(end, format: .dateTime.hour().minute())")
                        .font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(live.tint).lineLimit(1)
                } else {
                    Text(live.state.done ? "Done" : "Paused").font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(live.tint)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
    }
}

/// "FOCUS" over the session title.
struct LiveTitles: View {
    let live: LiveInfo
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Caps(text: live.phase, size: 11, color: live.tint)
            Text(live.title).font(.system(size: 17, weight: .semibold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.8)
        }
    }
}

struct LiveClock: View {
    let state: LiveState
    var body: some View {
        if state.done {
            Text("Done")
        } else if let end = state.end {
            Text(timerInterval: min(.now, end)...end, countsDown: true)
        } else {
            Text(state.remaining.clock)
        }
    }
}

struct LiveRing: View {
    let live: LiveInfo
    var body: some View {
        if live.state.done {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(live.tint)
        } else if let end = live.state.end {
            ProgressView(timerInterval: end.addingTimeInterval(-live.state.total)...end, countsDown: true) {
                EmptyView()
            } currentValueLabel: {
                EmptyView()
            }
            .progressViewStyle(.circular).tint(live.tint)
        } else {
            ProgressView(value: max(0, min(1, live.state.remaining / max(live.state.total, 1)))).progressViewStyle(.circular).tint(live.tint)
        }
    }
}

/// Thin bar that drains with the session.
struct LiveBar: View {
    let live: LiveInfo
    var body: some View {
        Group {
            if let end = live.state.end, !live.state.done {
                ProgressView(timerInterval: end.addingTimeInterval(-live.state.total)...end, countsDown: true) { EmptyView() } currentValueLabel: { EmptyView() }
            } else {
                ProgressView(value: live.state.done ? 0 : max(0, min(1, live.state.remaining / max(live.state.total, 1))))
            }
        }
        .progressViewStyle(.linear)
        .tint(live.tint)
    }
}

/// The bar over a ruler of ticks, echoing the dial.
struct LiveRuler: View {
    let live: LiveInfo
    var body: some View {
        ZStack(alignment: .bottom) {
            Ticks().fill(Color.secondary.opacity(0.45)).frame(height: 9)
            LiveBar(live: live).scaleEffect(x: 1, y: 1.6, anchor: .bottom)
        }
        .frame(height: 10)
    }
}

struct Ticks: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let n = 48
        for i in 0...n {
            let x = min(max(rect.width * CGFloat(i) / CGFloat(n) - 0.75, 0), rect.width - 1.5)
            let h = i % 6 == 0 ? rect.height : rect.height * 0.55
            p.addRoundedRect(in: CGRect(x: x, y: rect.maxY - h, width: 1.5, height: h), cornerSize: CGSize(width: 0.75, height: 0.75))
        }
        return p
    }
}

struct LiveButtons: View {
    let live: LiveInfo
    var body: some View {
        if !live.state.done {
            HStack(spacing: 10) {
                if live.state.end == nil {
                    Button(intent: ResumeIntent()) { Image(systemName: "play.fill") }.tint(live.tint).accessibilityLabel("Resume")
                } else {
                    Button(intent: PauseIntent()) { Image(systemName: "pause.fill") }.tint(live.tint).accessibilityLabel("Pause")
                }
                Button(intent: StopIntent()) { Image(systemName: "xmark") }.tint(.gray).accessibilityLabel("End Session")
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.circle)
            .font(.title3)
        }
    }
}
