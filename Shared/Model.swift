import SwiftUI
import SwiftData
#if os(iOS)
import AlarmKit
import ActivityKit
#endif
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - Session history

/// A finished (or ended-early) focus session. All attributes have defaults so the store can move to CloudKit later.
@Model final class Session {
    var start: Date = Date.now
    var duration: TimeInterval = 0
    var planned: TimeInterval = 0
    var label: String = ""
    var completed: Bool = false
    /// "How did it feel?" 1–5, 0 when skipped.
    var feel: Int = 0

    init(start: Date, duration: TimeInterval, planned: TimeInterval, label: String, completed: Bool) {
        self.start = start
        self.duration = duration
        self.planned = planned
        self.label = label
        self.completed = completed
    }
}

enum Store {
    @MainActor static let container: ModelContainer = {
        if let c = try? ModelContainer(for: Session.self) { return c }
        // Never crash-loop on a broken store; run in memory instead.
        return try! ModelContainer(for: Session.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }()
}

enum Stats {
    /// Consecutive active days ending today (or yesterday, so an unfinished today doesn't break the streak).
    /// With `freezes`, one missed day per calendar week is forgiven (it doesn't count, it just doesn't break the run).
    static func streak(_ activeDays: Set<Date>, today: Date, freezes: Bool = false, calendar: Calendar = .current) -> Int {
        var day = activeDays.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today)!
        var n = 0, frozenWeeks = Set<Date>()
        while true {
            if activeDays.contains(day) { n += 1 }
            else if !freezes || n == 0 || !frozenWeeks.insert(calendar.dateInterval(of: .weekOfYear, for: day)!.start).inserted { break }
            day = calendar.date(byAdding: .day, value: -1, to: day)!
        }
        return n
    }
}

// MARK: - Timer state (shared with widgets via the App Group)

enum Phase: String, Codable, Hashable, Sendable {
    case focus, rest
}

#if os(iOS)
struct PomlyMetadata: AlarmMetadata {
    var phase: Phase
    var label: String
}

/// Our own Live Activity when AlarmKit isn't allowed (system only displays AlarmAttributes backed by a real alarm).
struct PomlyActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var end: Date?            // nil while paused
        var remaining: TimeInterval
        var total: TimeInterval
    }
    var phase: Phase
    var label: String
}

/// What the Live Activity views need, from either source.
struct LiveState {
    var end: Date?
    var remaining: TimeInterval
    var total: TimeInterval
    var done = false

    init(_ s: PomlyActivityAttributes.ContentState) { end = s.end; remaining = s.remaining; total = s.total }

    init(_ mode: AlarmPresentationState.Mode) {
        switch mode {
        case .countdown(let c): end = c.fireDate; remaining = c.fireDate.timeIntervalSinceNow; total = c.totalCountdownDuration
        case .paused(let p): remaining = p.totalCountdownDuration - p.previouslyElapsedDuration; total = p.totalCountdownDuration
        default: remaining = 0; total = 1; done = true
        }
    }
}
#endif

struct TimerSnapshot: Codable, Equatable {
    enum Status: String, Codable { case idle, running, paused, finished }

    var phase = Phase.focus
    var status = Status.idle
    var planned: TimeInterval = 25 * 60
    var endDate: Date?
    var remaining: TimeInterval = 0
    var startedAt: Date?
    var label = ""
    var alarmID: UUID?
    var focusCount = 0

    var isActive: Bool { status == .running || status == .paused }

    func remaining(at now: Date = .now) -> TimeInterval {
        switch status {
        case .running: max(0, (endDate ?? now).timeIntervalSince(now))
        case .paused: remaining
        case .idle: planned
        case .finished: 0
        }
    }

    static func load() -> TimerSnapshot {
        if let data = UserDefaults.shared.data(forKey: "snapshot"),
           let s = try? JSONDecoder().decode(TimerSnapshot.self, from: data) { return s }
        return TimerSnapshot(planned: TimeInterval(Pref.int(Pref.focusMin) * 60))
    }

    func save() { UserDefaults.shared.set(try? JSONEncoder().encode(self), forKey: "snapshot") }
}

/// Today's focus, cached for widgets (they can't read the SwiftData store).
enum Today {
    private static var key: Double { Calendar.current.startOfDay(for: .now).timeIntervalSince1970 }
    private static var valid: Bool { UserDefaults.shared.double(forKey: "todayDay") == key }
    static func seconds() -> TimeInterval { valid ? UserDefaults.shared.double(forKey: "todaySeconds") : 0 }
    static func count() -> Int { valid ? UserDefaults.shared.integer(forKey: "todayCount") : 0 }
    static func store(_ seconds: TimeInterval, count: Int) {
        UserDefaults.shared.set(key, forKey: "todayDay")
        UserDefaults.shared.set(seconds, forKey: "todaySeconds")
        UserDefaults.shared.set(count, forKey: "todayCount")
    }
}

/// Today's sessions as small bars against the goal (e.g. 3 of 5).
struct SessionBars: View {
    let done: Int
    let goal: Int
    let tint: Color
    var height: CGFloat = 14

    var body: some View {
        HStack(spacing: height * 0.22) {
            ForEach(0..<min(max(goal, done, 1), 8), id: \.self) { i in
                Capsule().fill(i < done ? tint : tint.opacity(0.22)).frame(width: max(2, height * 0.2), height: height)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(done) of \(goal) sessions")
    }

    /// Sessions needed to reach the daily goal at the current focus length.
    static func goal(goalMin: Int, focusMin: Int) -> Int { max(1, Int((Double(goalMin) / Double(max(focusMin, 1))).rounded(.up))) }
}

// MARK: - Preferences

extension UserDefaults {
    static let shared = UserDefaults(suiteName: "group.com.purvt.pomly") ?? .standard
}

enum Pref {
    static let focusMin = "focusMin", breakMin = "breakMin", longBreakMin = "longBreakMin", longEvery = "longEvery"
    static let autoBreak = "autoBreak", autoFocus = "autoFocus", goalMin = "goalMin"
    static let appearance = "appearance", theme = "theme", haptics = "haptics", sound = "sound", liveStyle = "liveStyle"
    static let autoUpdate = "autoUpdate"

    private static let defaults: UserDefaults = {
        let d = UserDefaults.shared
        d.register(defaults: [focusMin: 25, breakMin: 5, longBreakMin: 15, longEvery: 4, autoBreak: false,
                              autoFocus: false, goalMin: 120, appearance: 0, theme: 0, haptics: true, sound: 0, liveStyle: 0, autoUpdate: true])
        return d
    }()

    static func register() { _ = defaults }
    static func int(_ key: String) -> Int { defaults.integer(forKey: key) }
    static func bool(_ key: String) -> Bool { defaults.bool(forKey: key) }

    /// Every `every`-th completed focus earns the long break (`every == 0` turns long breaks off).
    static func breakMinutes(focusCount: Int, every: Int, short: Int, long: Int) -> Int {
        every > 0 && focusCount > 0 && focusCount % every == 0 ? long : short
    }
}

// MARK: - Look

enum Theme: Int, CaseIterable, Identifiable {
    case ember, sage, tide, rose, plum
    var id: Int { rawValue }

    var name: LocalizedStringKey { ["Ember", "Sage", "Tide", "Rose", "Plum"][rawValue] }

    /// Light values are darker so glyphs keep ≥ 4.5:1 on parchment; dark values glow on espresso.
    var tint: Color {
        switch self {
        case .ember: Color(light: 0xB85A1E, dark: 0xF4A66A)
        case .sage: Color(light: 0x3F7350, dark: 0x9FD1A8)
        case .tide: Color(light: 0x2A6A9C, dark: 0x8CC4F0)
        case .rose: Color(light: 0xB0405A, dark: 0xF2A0B2)
        case .plum: Color(light: 0x74489C, dark: 0xC7A6F0)
        }
    }

    static var current: Theme { Theme(rawValue: Pref.int(Pref.theme)) ?? .ember }
    /// Text on a tinted fill.
    static let onTint = Color(light: 0xFFFFFF, dark: 0x2A1A10)
}

struct AppBackground: View {
    var tint: Color
    var body: some View {
        LinearGradient(colors: [Color(light: 0xFBF6EF, dark: 0x1C130E), Color(light: 0xF0E4D4, dark: 0x2A1C14)],
                       startPoint: .top, endPoint: .bottom)
            .overlay(RadialGradient(colors: [tint.opacity(0.22), .clear], center: .center, startRadius: 0, endRadius: 420))
            .ignoresSafeArea()
    }
}

/// The Pomly dial: 60 rounded ticks lit for what's left, a hand and a knob. Ticks glow in dark mode.
/// One drawing for the app and every widget.
struct DialFace: View, Animatable {
    var fraction: Double
    var tint: Color
    var lap = false
    var knobScale: CGFloat = 1
    var showsKnob = true
    @Environment(\.colorScheme) private var scheme

    /// Idle dial: one turn is an hour; past 60 minutes it starts a second lap.
    static func idleFraction(_ planned: TimeInterval) -> Double {
        let m = planned / 60
        return m > 60 ? (m - 60) / 60 : m / 60
    }

    /// Lets state changes sweep the ticks instead of jumping.
    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    var body: some View {
        let f = min(max(fraction, 0), 1)
        ZStack {
            // The glowing ticks only change every 1/60 of a session, so they redraw only then; the knob moves every second.
            DialTicks(lit: Int((f * 60).rounded(.up)), tint: tint, lap: lap, glow: scheme == .dark).equatable()
            if showsKnob {
                Canvas { gc, size in
                    let r = min(size.width, size.height) / 2, w = max(r / 80, 0.8)
                    let c = CGPoint(x: size.width / 2, y: size.height / 2)
                    let theta = f * 2 * .pi
                    let clear = 1 / ((sin(theta) / 0.62) * (sin(theta) / 0.62) + (cos(theta) / 0.34) * (cos(theta) / 0.34)).squareRoot()
                    var hand = Path()
                    hand.move(to: DialTicks.point(f, r * min(clear + 0.05, 0.62), c))
                    hand.addLine(to: DialTicks.point(f, r * 0.7, c))
                    gc.stroke(hand, with: .color(scheme == .dark ? tint.opacity(0.35) : .white.opacity(0.9)), style: StrokeStyle(lineWidth: w * 1.1, lineCap: .round))
                    let kp = DialTicks.point(f, r * 0.7, c), kr = r * 0.035 * knobScale
                    gc.fill(Path(ellipseIn: CGRect(x: kp.x - kr, y: kp.y - kr, width: kr * 2, height: kr * 2)), with: .color(tint))
                }
            }
        }
    }
}

/// The dial's 60 ticks, the first `lit` in the tint.
struct DialTicks: View, Equatable {
    let lit: Int
    let tint: Color
    let lap: Bool
    let glow: Bool

    static func point(_ turn: Double, _ radius: CGFloat, _ c: CGPoint) -> CGPoint {
        let a = turn * 2 * .pi - .pi / 2
        return CGPoint(x: c.x + cos(a) * radius, y: c.y + sin(a) * radius)
    }

    var body: some View {
        Canvas { gc, size in
            let r = min(size.width, size.height) / 2
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let w = max(r / 80, 0.8) // stroke scales with the dial
            var on = Path(), onMajor = Path(), off = Path(), offMajor = Path()
            for i in 0..<60 {
                let t = Double(i) / 60, major = i % 5 == 0
                var p = Path()
                p.move(to: Self.point(t, r * (major ? 0.79 : 0.85), c))
                p.addLine(to: Self.point(t, r * 0.95, c))
                if i < lit { major ? onMajor.addPath(p) : on.addPath(p) } else { major ? offMajor.addPath(p) : off.addPath(p) }
            }
            let dim = lap ? tint.opacity(0.45) : Color.secondary.opacity(0.3)
            gc.stroke(off, with: .color(dim), style: StrokeStyle(lineWidth: w, lineCap: .round))
            gc.stroke(offMajor, with: .color(dim), style: StrokeStyle(lineWidth: w * 1.6, lineCap: .round))
            gc.drawLayer { layer in
                if glow { layer.addFilter(.shadow(color: tint.opacity(0.75), radius: w * 2.2)) }
                layer.stroke(on, with: .color(tint), style: StrokeStyle(lineWidth: w, lineCap: .round))
                layer.stroke(onMajor, with: .color(tint), style: StrokeStyle(lineWidth: w * 1.6, lineCap: .round))
            }
        }
    }
}

/// Live Activity look, chosen in Settings.
enum LiveStyle: Int, CaseIterable, Identifiable {
    case ruler, controls, minimal
    var id: Int { rawValue }
    var name: LocalizedStringKey { ["Ruler", "Controls", "Minimal"][rawValue] }
    static var current: LiveStyle { LiveStyle(rawValue: Pref.int(Pref.liveStyle)) ?? .ruler }
}

struct GoalRing: View {
    var progress: Double
    var tint: Color
    var lineWidth: CGFloat = 3
    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.25), lineWidth: lineWidth)
            Circle().trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

extension Color {
    init(light: UInt32, dark: UInt32) {
        #if os(iOS)
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(rgb: dark) : UIColor(rgb: light) })
        #elseif os(macOS)
        self.init(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(rgb: dark) : NSColor(rgb: light) })
        #else
        self.init(uiColor: UIColor(rgb: dark)) // watchOS is always dark
        #endif
    }
}

#if os(macOS)
typealias PlatformColor = NSColor
#else
typealias PlatformColor = UIColor
#endif

extension PlatformColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat(rgb >> 16 & 0xFF) / 255, green: CGFloat(rgb >> 8 & 0xFF) / 255, blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

extension TimeInterval {
    /// Countdown text: 24:59 or 1:05:00.
    var clock: String {
        let s = Int(rounded(.up))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
    /// "15 sec", "5 min", "1 hr, 5 min".
    var shortText: String {
        self > 0 && self < 60 ? Duration.seconds(self).formatted(.units(allowed: [.seconds], width: .abbreviated)) : minutesText
    }
    /// "45 min", "1 hr, 5 min".
    var minutesText: String {
        Duration.seconds(self).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}
