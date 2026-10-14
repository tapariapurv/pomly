import SwiftUI
import SwiftData
import StoreKit

struct FocusView: View {
    private let engine = TimerEngine.shared
    @Query(sort: \Session.start, order: .reverse) private var sessions: [Session]
    @AppStorage(Pref.goalMin, store: .shared) private var goalMin = 120
    @AppStorage(Pref.focusMin, store: .shared) private var focusMin = 25
    @AppStorage(Pref.theme, store: .shared) private var themeRaw = 0
    @AppStorage(Pref.haptics, store: .shared) private var haptics = true
    @State private var wide = false
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.requestReview) private var requestReview
    @ScaledMetric(relativeTo: .title3) private var scaledControl = 56.0
    @Namespace private var glass
    @State private var askingLabel = false
    @State private var newLabel = ""
    @State private var fullScreen = false

    private var controlSize: CGFloat { min(scaledControl, 72) }
    private var tint: Color { (Theme(rawValue: themeRaw) ?? .ember).tint }
    private var today: [Session] { Array(sessions.prefix { Calendar.current.isDateInToday($0.start) }) }
    private var todaySeconds: TimeInterval { today.reduce(0) { $0 + $1.duration } }
    private var motion: Animation { reduceMotion ? .easeInOut(duration: 0.2) : .snappy(duration: 0.4) }
    /// Once a session ends, the dial previews what comes next.
    private var nextPhase: Phase { engine.snap.phase == .focus ? .rest : .focus }

    var body: some View {
        let s = engine.snap
        ZStack {
            AppBackground(tint: tint)
            Group { if wide { regular } else { compact } }
                // The dial needs room; text still grows a lot but stops where this layout can hold it.
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
        // Side by side only when there's width to spare (landscape, Mac, iPhone Duo inside); portrait iPad stacks like iPhone.
        .onGeometryChange(for: Bool.self) { $0.size.width > 640 && $0.size.width >= $0.size.height * 0.9 } action: { wide = $0 }
        .animation(motion, value: s.status)
        .animation(motion, value: s.phase)
        .sensoryFeedback(.success, trigger: s.status == .finished) { _, new in haptics && new }
        .task(id: s.endDate) { await waitForEnd(s.endDate) }
        .onChange(of: engine.lifetimeCompleted) { _, n in
            guard [5, 25, 100].contains(n) else { return }
            Task { try? await Task.sleep(for: .seconds(2)); requestReview() } // after the celebration, not during it
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $fullScreen) { FullScreenTimer(tint: tint) }
        #endif
        .alert("Focusing On", isPresented: $askingLabel) {
            TextField("Reading", text: $newLabel)
            Button("Save") { engine.setLabel(newLabel.trimmingCharacters(in: .whitespacesAndNewlines)) }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: Layouts

    private var compact: some View {
        VStack(spacing: 18) {
            header
            title
            Spacer(minLength: 0)
            dial.frame(maxWidth: 520)
            presets
            Spacer(minLength: 0)
            controls
        }
        .frame(maxWidth: 560, maxHeight: 940) // tall iPads: keep the composition together
        .padding(Self.edge)
    }

    /// iPhone Duo inner display / landscape: focus on one side of the fold, today on the other.
    private var regular: some View {
        GeometryReader { geo in
            HStack(alignment: .top, spacing: foldWidth(geo)) {
                VStack(spacing: 18) {
                    header
                    title
                    dial.frame(maxWidth: 420)
                    presets
                    Spacer(minLength: 0)
                    controls
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                TodayPanel(sessions: today, seconds: todaySeconds, goalMin: goalMin, focusMin: focusMin, tint: tint)
                    .frame(maxWidth: .infinity)
            }
            .padding(Self.edge)
        }
    }

    /// Mac is viewed from further away: roomier margins.
    #if os(macOS)
    static let edge: CGFloat = 28
    #else
    static let edge: CGFloat = 16
    #endif

    private func foldWidth(_ geo: GeometryProxy) -> CGFloat {
#if os(iOS)
        if #available(iOS 27.1, *) {
            return geo.reservedRegions(kind: .division).filter(\.isActive).map(\.frame.width).max() ?? 32
        }
#endif
        return 32
    }

    // MARK: Header and title

    private var header: some View {
        HStack(spacing: 8) {
            if !wide { todayLine } // side by side, the Today panel says it
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 36)
        .overlay(alignment: .trailing) {
            #if DEBUG
            quickToggle
            #endif
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var todayLine: some View {
            Text("TODAY").font(.caption.weight(.semibold)).fontWidth(.expanded).tracking(1.2).foregroundStyle(.secondary)
            Text(todaySeconds.shortText).font(.subheadline.weight(.semibold)).fontDesign(.rounded).monospacedDigit()
                .contentTransition(.numericText())
    }

    /// Test builds only: 15-second sessions to try the whole cycle quickly.
    private var quickToggle: some View {
        Button { engine.toggleQuick() } label: {
            Image(systemName: "hare.fill").font(.subheadline).frame(width: 36, height: 36).contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(engine.snap.planned < 60 ? tint : .secondary)
        .glassEffect(.regular.interactive(), in: .circle)
        .disabled(engine.snap.isActive)
        .accessibilityLabel("Quick 15-second sessions")
    }

    @ViewBuilder private var title: some View {
        let s = engine.snap
        if s.status == .finished {
            VStack(spacing: 6) {
                Stamp(text: s.phase == .focus ? "Session Logged" : "Break Done", tint: tint)
                Text(s.label.isEmpty ? (s.phase == .focus ? String(localized: "Focus") : String(localized: "Break")) : s.label)
                    .font(.title2.weight(.semibold)).fontDesign(.rounded).lineLimit(1)
                Group {
                    s.phase == .focus ? Text("\(s.planned.shortText) of focus. Take a breather.") : Text("Rested. Ready for the next one?")
                }
                .font(.subheadline).fontDesign(.rounded).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            .transition(.blurReplace)
        } else if s.phase == .rest, s.isActive {
            // A break has no label to pick; say when focus resumes instead.
            VStack(spacing: 4) {
                Text("ON A BREAK").font(.caption.weight(.semibold)).fontWidth(.expanded).tracking(1.2).foregroundStyle(.secondary)
                Group {
                    if let end = s.endDate { Text("Back at \(end, format: .dateTime.hour().minute())") } else { Text("Paused") }
                }
                .font(.title.weight(.semibold)).fontDesign(.rounded).lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(.opacity)
            }
            .transition(.blurReplace)
        } else {
            labelPicker.transition(.blurReplace)
        }
    }

    private var labelChoices: [String] {
        var seen = Set<String>(), out: [String] = []
        for l in sessions.lazy.map(\.label) + ["Work", "Study", "Reading", "Writing"] where !l.isEmpty && seen.insert(l).inserted {
            out.append(l)
            if out.count == 6 { break }
        }
        return out
    }

    private var labelPicker: some View {
        let s = engine.snap
        return Menu {
            ForEach(labelChoices, id: \.self) { l in Button(l) { engine.setLabel(l) } }
            Divider()
            Button("New Label…", systemImage: "plus") { newLabel = ""; askingLabel = true }
            if !s.label.isEmpty { Button("Clear", systemImage: "xmark", role: .destructive) { engine.setLabel("") } }
        } label: {
            VStack(spacing: 4) {
                (s.phase == .rest && s.isActive ? Text("ON A BREAK") : Text("FOCUSING ON"))
                    .font(.caption.weight(.semibold)).fontWidth(.expanded).tracking(1.2).foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Text(s.label.isEmpty ? String(localized: "Anything") : s.label)
                        .font(.title.weight(.semibold)).fontDesign(.rounded).lineLimit(1)
                        .contentTransition(.opacity)
                    Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                .foregroundStyle(.primary)
            }
            .contentShape(.rect)
        }
        #if os(macOS)
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        #endif
        .animation(motion, value: s.label)
        .accessibilityLabel("Focusing on \(s.label.isEmpty ? String(localized: "anything") : s.label)")
        .accessibilityHint("Choose a label for this session")
    }

    // MARK: Dial and presets

    private var dial: some View {
        DialView(snap: engine.snap, next: engine.defaultSeconds(for: nextPhase), tint: tint, haptics: haptics) {
            engine.setDuration(TimeInterval($0 * 60))
        }
    }

    @ViewBuilder private var presets: some View {
        let s = engine.snap
        Group {
            if s.status == .idle {
                HStack(spacing: 10) {
                    ForEach([15, 25, 45, 60], id: \.self) { m in
                        Button { engine.setDuration(TimeInterval(m * 60)) } label: {
                            Text("\(m)").font(.subheadline.weight(.semibold)).monospacedDigit().lineLimit(1).frame(minWidth: 32, minHeight: 32)
                        }
                        .glassCapsule()
                        .tint(s.planned == TimeInterval(m * 60) ? tint : nil)
                        .accessibilityLabel("\(m) minutes")
                    }
                }
            } else if s.status == .finished, s.phase == .focus {
                Button("Add 5 Minutes", systemImage: "plus") { Task { await engine.start(.focus, seconds: 300) } }
                    .font(.subheadline.weight(.semibold)).glassCapsule(neutral: true)
            } else if s.isActive {
                Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") {
                    #if os(macOS)
                    openWindow(id: "timer")
                    #else
                    fullScreen = true
                    #endif
                }
                .font(.subheadline.weight(.semibold)).glassCapsule(neutral: true)
            } else {
                Color.clear
            }
        }
        .frame(height: 44) // keeps the dial still while states change
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }

    // MARK: Controls: secondary · primary · switch phase

    private struct Action {
        let id: String
        var icon: String?
        let label: LocalizedStringKey
        let run: () -> Void
    }

    private var controls: some View {
        let s = engine.snap
        return GlassEffectContainer(spacing: 16) {
            HStack(spacing: 16) {
                if let a = leading(s) { secondary(a) }
                primary(main(s))
                if let a = trailing(s) { secondary(a) }
            }
        }
        .frame(maxWidth: 440)
    }

    private func leading(_ s: TimerSnapshot) -> Action? {
        switch s.status {
        case .running, .paused: Action(id: "leading", icon: "xmark", label: "End Session") { engine.stop() }
        case .finished: Action(id: "leading", label: "Skip") { engine.reset() }
        case .idle: nil
        }
    }

    private func main(_ s: TimerSnapshot) -> Action {
        switch (s.status, s.phase) {
        case (.running, _): Action(id: "main", icon: "pause.fill", label: "Pause") { engine.pause() }
        case (.paused, _): Action(id: "main", icon: "play.fill", label: "Resume") { Task { await engine.resume() } }
        case (.finished, .focus): Action(id: "main", icon: "cup.and.saucer.fill", label: "Start Break") { Task { await engine.start(.rest) } }
        case (.finished, .rest): Action(id: "main", icon: "timer", label: "Start Focus") { Task { await engine.start(.focus) } }
        case (.idle, _): Action(id: "main", icon: "play.fill", label: "Start Focus") { Task { await engine.start(.focus, seconds: s.planned) } }
        }
    }

    private func trailing(_ s: TimerSnapshot) -> Action? {
        switch (s.status, s.phase) {
        case (.finished, _): nil
        case (_, .rest) where s.isActive: Action(id: "trailing", icon: "timer", label: "Focus Now") { Task { await engine.start(.focus) } }
        default: Action(id: "trailing", icon: "cup.and.saucer.fill", label: "Take a Break") { Task { await engine.start(.rest) } }
        }
    }

    /// Circle for icons, capsule for words; the same glass id morphs between them.
    private func secondary(_ a: Action) -> some View {
        Button(action: a.run) {
            Group {
                if let icon = a.icon {
                    Image(systemName: icon).font(.title3.weight(.semibold)).frame(width: controlSize, height: controlSize)
                } else {
                    Text(a.label).font(.headline).fontDesign(.rounded).lineLimit(1).padding(.horizontal, 24).frame(height: controlSize)
                }
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
        .glassEffectID(a.id, in: glass)
        .accessibilityLabel(a.label)
    }

    private func primary(_ a: Action) -> some View {
        Button(action: a.run) {
            Label(a.label, systemImage: a.icon ?? "play.fill")
                .font(.headline).fontDesign(.rounded)
                .lineLimit(1).minimumScaleFactor(0.7)
                .contentTransition(.opacity)
                .frame(maxWidth: .infinity, minHeight: controlSize)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.onTint)
        .glassEffect(.regular.tint(tint).interactive(), in: .capsule)
        .glassEffectID(a.id, in: glass)
        .keyboardShortcut(.space, modifiers: [])
    }

    private func waitForEnd(_ end: Date?) async {
        guard let end else { return }
        try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
        guard !Task.isCancelled else { return }
        engine.refresh()
    }
}

/// "✓ SESSION LOGGED" lands like a rubber stamp.
struct Stamp: View {
    let text: LocalizedStringKey
    let tint: Color
    @State private var landed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Label(text, systemImage: "checkmark")
            .font(.caption.weight(.bold)).fontWidth(.expanded).tracking(1.4).textCase(.uppercase)
            .foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 5)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(tint, lineWidth: 1.5))
            .rotationEffect(.degrees(landed ? -3 : -12))
            .scaleEffect(landed || reduceMotion ? 1 : 1.9)
            .opacity(landed || reduceMotion ? 1 : 0)
            .onAppear { withAnimation(.spring(response: 0.32, dampingFraction: 0.55)) { landed = true } }
    }
}

// MARK: - Dial

struct DialView: View {
    let snap: TimerSnapshot
    let next: TimeInterval
    let tint: Color
    var haptics = true
    var onSet: (Int) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settling = false

    private var idle: Bool { snap.status == .idle }
    private var done: Bool { snap.status == .finished }
    private var minutes: Int { Int(snap.planned / 60) }

    var body: some View {
        // Ticks twice a second only while running; pauses during the start sweep so it isn't cut short.
        TimelineView(.animation(minimumInterval: 0.5, paused: snap.status != .running || settling)) { ctx in
            let remaining = snap.remaining(at: ctx.date)
            let shown = idle ? snap.planned : done ? next : remaining
            let fraction = idle ? DialFace.idleFraction(snap.planned) : done ? 1 : (snap.planned > 0 ? remaining / snap.planned : 0)
            let last = snap.status == .running ? Int(remaining.rounded(.up)) : 0
            GeometryReader { geo in
                ZStack {
                    DialFace(fraction: fraction, tint: tint, lap: idle && minutes > 60, knobScale: idle ? 1.85 : 1)
                        .animation(reduceMotion ? nil : .smooth(duration: 0.9), value: snap.status)
                    VStack(spacing: 6) {
                        Text(shown.clock)
                            .font(.system(size: geo.size.width * 0.22, weight: .regular, design: .rounded)).monospacedDigit()
                            .contentTransition(.numericText(countsDown: true))
                            .animation(reduceMotion ? nil : .smooth, value: Int(shown))
                            .lineLimit(1).minimumScaleFactor(0.4)
                        HStack(spacing: 6) {
                            Circle().fill(tint).frame(width: 6, height: 6)
                            statusText.font(.caption.weight(.semibold)).fontWidth(.expanded).tracking(1.5)
                        }
                        .foregroundStyle(.secondary)
                    }
                    .padding(geo.size.width * 0.2)
                }
                // The last three seconds beat once each, with a light tap.
                .keyframeAnimator(initialValue: 1.0, trigger: (1...3).contains(last) ? last : 0) { content, scale in
                    content.scaleEffect(scale)
                } keyframes: { _ in
                    SpringKeyframe(reduceMotion ? 1 : 1.03, duration: 0.12)
                    SpringKeyframe(1.0, duration: 0.4)
                }
                .sensoryFeedback(.impact(weight: .light), trigger: last) { _, n in haptics && (1...3).contains(n) }
                .contentShape(.circle)
                .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                    guard idle else { return }
                    let c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                    onSet(Self.minutes(forAngle: Self.angle(of: v.location, center: c), current: minutes))
                })
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .padding(14)
        .glassEffect(.regular, in: .circle)
        .sensoryFeedback(trigger: minutes) { _, new in
            guard haptics, idle else { return nil }
            return new % 5 == 0 ? .impact(weight: .medium) : .selection
        }
        .onChange(of: snap.status) { _, new in
            guard new == .running, !reduceMotion else { return }
            settling = true
            Task { try? await Task.sleep(for: .seconds(0.9)); settling = false }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(snap.phase == .focus ? "Focus timer" : "Break timer")
        .accessibilityValue(idle ? "\(minutes) minutes" : done ? "Done" : "\(Duration.seconds(snap.remaining()).formatted(.units(width: .wide))) remaining")
        .accessibilityHint(idle ? "Swipe up or down to change the length" : "")
        .accessibilityAdjustableAction { dir in
            guard idle else { return }
            onSet(min(120, max(5, minutes + (dir == .increment ? 5 : -5))))
        }
    }

    private var statusText: Text {
        switch snap.status {
        case .paused: Text("PAUSED")
        case .finished: snap.phase == .focus ? Text("BREAK") : Text("FOCUS") // what's next
        default: snap.phase == .focus ? Text("FOCUS") : Text("BREAK")
        }
    }

    /// Degrees clockwise from 12 o'clock.
    static func angle(of p: CGPoint, center c: CGPoint) -> Double {
        let deg = atan2(p.x - c.x, c.y - p.y) * 180 / .pi
        return deg < 0 ? deg + 360 : deg
    }

    /// The ring is one hour. The lap closest to `current` wins, so dragging past 12 keeps counting (1–120).
    static func minutes(forAngle a: Double, current: Int) -> Int {
        let m = Int((a / 6).rounded()) % 60
        let pick = [m - 60, m, m + 60, m + 120].min { abs($0 - current) < abs($1 - current) }!
        return min(120, max(1, pick))
    }
}

// MARK: - Today (regular width)

struct TodayPanel: View {
    let sessions: [Session]
    let seconds: TimeInterval
    let goalMin: Int
    let focusMin: Int
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Today").font(.largeTitle.weight(.semibold)).fontDesign(.rounded)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(Int(seconds / 60))").font(.system(size: 48, weight: .regular, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                    Text("min of focus").font(.body).fontDesign(.rounded).foregroundStyle(.secondary).lineLimit(1)
                    Spacer(minLength: 8)
                    SessionBars(done: sessions.count, goal: SessionBars.goal(goalMin: goalMin, focusMin: focusMin), tint: tint, height: 22)
                }
                Text(sessions.count == 1 ? String(localized: "1 session") : String(localized: "\(sessions.count) sessions"))
                    .font(.subheadline).fontDesign(.rounded).foregroundStyle(.secondary)
            }
            .padding(20)
            .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 24))
            if !sessions.isEmpty {
                HStack {
                    Text("TODAY")
                    Spacer()
                    Text(seconds.shortText.uppercased())
                }
                .font(.caption.weight(.semibold)).fontWidth(.expanded).tracking(1.2).foregroundStyle(.secondary)
                .padding(.horizontal, 20)
                VStack(spacing: 0) {
                    ForEach(Array(sessions.prefix(6).enumerated()), id: \.element.id) { i, session in
                        if i > 0 { Divider() }
                        SessionRow(session: session, tint: tint).padding(.vertical, 12)
                    }
                }
                .padding(.horizontal, 20)
                .background(Color.primary.opacity(0.05), in: .rect(cornerRadius: 24))
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(maxWidth: 440, maxHeight: .infinity, alignment: .topLeading)
        .animation(.snappy, value: sessions.count)
    }
}

struct SessionRow: View {
    let session: Session
    let tint: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.label.isEmpty ? String(localized: "Focus") : session.label)
                    .font(.body.weight(.medium)).fontDesign(.rounded).lineLimit(1)
                Text(session.completed ? session.start.formatted(.dateTime.hour().minute())
                                       : String(localized: "Ended early · \(session.start.formatted(.dateTime.hour().minute()))"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(session.duration.shortText).font(.body).fontDesign(.rounded).monospacedDigit()
                .foregroundStyle(session.completed ? .primary : .secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Full screen

/// Distraction-free timer: huge digits on pure black or white, any orientation. Tap to show controls.
struct FullScreenTimer: View {
    let tint: Color
    private let engine = TimerEngine.shared
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("fullScreenStyle", store: .shared) private var style = 0 // 0 match system, 1 dark, 2 light
    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?

    private var dark: Bool { style == 0 ? systemScheme == .dark : style == 1 }

    var body: some View {
        let s = engine.snap
        GeometryReader { geo in
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let remaining = s.remaining(at: ctx.date)
                let size = min(geo.size.width * 0.26, (geo.size.height - 96) * 0.5)
                VStack(spacing: size * 0.1) {
                    HStack(spacing: 8) {
                        Circle().fill(tint).frame(width: 7, height: 7)
                        Text(header(s)).font(.system(size: max(13, size * 0.09), weight: .semibold)).tracking(2.5)
                    }
                    .opacity(0.6)
                    Text(remaining.clock)
                        .font(.system(size: size, weight: .light, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                        .animation(reduceMotion ? nil : .smooth, value: Int(remaining))
                        .lineLimit(1).minimumScaleFactor(0.5)
                    Capsule().fill(Color.primary.opacity(0.12))
                        .overlay(alignment: .leading) {
                            Capsule().fill(tint).scaleEffect(x: max(s.planned > 0 ? remaining / s.planned : 0, 0.001), anchor: .leading)
                        }
                        .frame(width: min(geo.size.width * 0.5, 360), height: 3)
                }
                .offset(reduceMotion ? .zero : Self.drift(ctx.date))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 96) // room for the controls, so they never cover the timer
            }
        }
        .foregroundStyle(dark ? .white : .black)
        .background((dark ? Color.black : Color.white).ignoresSafeArea())
        .overlay(alignment: .bottom) {
            if showControls { controls(s).padding(.bottom, 24).transition(.opacity) }
        }
        .contentShape(.rect)
        .onTapGesture { reveal() }
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(dark ? .dark : .light)
        #if os(iOS)
        .statusBarHidden()
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        #endif
        .onAppear { reveal() }
        .onDisappear { hideTask?.cancel() }
        .onChange(of: s.status) { reveal() }
    }

    private func header(_ s: TimerSnapshot) -> String {
        let phase = s.phase == .focus ? String(localized: "Focus") : String(localized: "Break")
        let state = s.status == .paused ? String(localized: "Paused") : s.status == .finished ? String(localized: "Done") : (s.label.isEmpty ? phase : "\(phase) · \(s.label)")
        return state.uppercased()
    }

    private func controls(_ s: TimerSnapshot) -> some View {
        GlassEffectContainer(spacing: 20) {
            HStack(spacing: 20) {
                control("xmark", "Exit Full Screen") { dismiss() }
                if s.isActive {
                    control(s.status == .running ? "pause.fill" : "play.fill", s.status == .running ? "Pause" : "Resume") {
                        if s.status == .running { engine.pause() } else { Task { await engine.resume() } }
                        reveal()
                    }
                }
                control(dark ? "sun.max.fill" : "moon.fill", dark ? "White Background" : "Black Background") {
                    style = dark ? 2 : 1
                    reveal()
                }
            }
        }
    }

    private func control(_ icon: String, _ label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title3.weight(.semibold)).frame(width: 56, height: 56).contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(dark ? Color.white : .black) // the overlay doesn't inherit the screen's foreground
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel(label)
    }

    /// Controls fade after a few seconds while running; they stay when paused or done.
    private func reveal() {
        withAnimation { showControls = true }
        hideTask?.cancel()
        guard engine.snap.status == .running else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.6)) { showControls = false }
        }
    }

    /// Shifts a few points each minute so long sessions don't burn the digits into OLED screens.
    static func drift(_ date: Date) -> CGSize {
        let m = Int(date.timeIntervalSince1970 / 60)
        return CGSize(width: CGFloat(m % 5 - 2) * 3, height: CGFloat(m / 5 % 5 - 2) * 3)
    }
}

extension View {
    /// Secondary glass capsule. macOS draws `.glass` as a small tinted rounded rect; match the iOS capsule instead.
    @ViewBuilder func glassCapsule(neutral: Bool = false) -> some View {
        #if os(macOS)
        if neutral { buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.large).tint(nil) }
        else { buttonStyle(.glass).buttonBorderShape(.capsule).controlSize(.large) }
        #else
        buttonStyle(.glass)
        #endif
    }
}
