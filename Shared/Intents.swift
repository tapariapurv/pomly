import AppIntents

// LiveActivityIntent: always runs in the app process, also when tapped in a widget, control or Live Activity (iOS only).
#if os(iOS)
typealias PomlyIntent = LiveActivityIntent
#else
typealias PomlyIntent = AppIntent
#endif

struct StartFocusIntent: PomlyIntent {
    static let title: LocalizedStringResource = "Start Focus"
    static let description = IntentDescription("Starts a focus session, optionally with a length and a label, like writing for 50 minutes.")
    @Parameter(title: "Minutes", inclusiveRange: (1, 180)) var minutes: Int?
    @Parameter(title: "Label") var label: String?

    static var parameterSummary: some ParameterSummary { Summary("Focus on \(\.$label) for \(\.$minutes) minutes") }

    init() {}
    init(minutes: Int?, label: String? = nil) { self.minutes = minutes; self.label = label }

    @MainActor func perform() async throws -> some IntentResult {
        if let label = label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty { TimerEngine.shared.setLabel(label) }
        await TimerEngine.shared.start(.focus, seconds: minutes.map { TimeInterval($0 * 60) })
        return .result()
    }
}

struct StartBreakIntent: PomlyIntent {
    static let title: LocalizedStringResource = "Take a Break"
    static let description = IntentDescription("Starts a break.")
    @Parameter(title: "Minutes", inclusiveRange: (1, 60)) var minutes: Int?

    static var parameterSummary: some ParameterSummary { Summary("Take a break for \(\.$minutes) minutes") }

    init() {}

    @MainActor func perform() async throws -> some IntentResult {
        await TimerEngine.shared.start(.rest, seconds: minutes.map { TimeInterval($0 * 60) })
        return .result()
    }
}

struct PauseIntent: PomlyIntent {
    static let title: LocalizedStringResource = "Pause Timer"
    static let description = IntentDescription("Pauses the current session.")
    @MainActor func perform() async throws -> some IntentResult {
        TimerEngine.shared.pause()
        return .result()
    }
}

struct ResumeIntent: PomlyIntent {
    static let title: LocalizedStringResource = "Resume Timer"
    static let description = IntentDescription("Resumes a paused session.")
    @MainActor func perform() async throws -> some IntentResult {
        await TimerEngine.shared.resume()
        return .result()
    }
}

struct StopIntent: PomlyIntent {
    static let title: LocalizedStringResource = "End Session"
    static let description = IntentDescription("Ends the current session. Focus that ran a minute or more still counts.")
    @MainActor func perform() async throws -> some IntentResult {
        TimerEngine.shared.stop()
        return .result()
    }
}

/// "Done" on the end-of-session alarm.
struct FinishIntent: PomlyIntent {
    static let title: LocalizedStringResource = "Finish Session"
    static let isDiscoverable = false
    @MainActor func perform() async throws -> some IntentResult {
        TimerEngine.shared.refresh()
        TimerEngine.shared.reset()
        return .result()
    }
}

/// Control Center / Lock Screen / Action Button toggle.
struct ToggleFocusIntent: SetValueIntent, PomlyIntent {
    static let title: LocalizedStringResource = "Toggle Focus"
    static let isDiscoverable = false
    @Parameter(title: "Focusing") var value: Bool

    @MainActor func perform() async throws -> some IntentResult {
        if value { await TimerEngine.shared.start(.focus) } else { TimerEngine.shared.stop() }
        return .result()
    }
}

/// "How much time is left?" for Siri, Spotlight and Apple Intelligence: answers without opening the app.
struct TimeLeftIntent: AppIntent {
    static let title: LocalizedStringResource = "Time Left"
    static let description = IntentDescription("Tells you how much is left of the current focus session or break.")

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog {
        let s = TimerEngine.shared.snap
        let minutes = Int((s.remaining() / 60).rounded(.up))
        let what = s.phase == .focus ? String(localized: "focus") : String(localized: "break")
        let dialog: IntentDialog = switch s.status {
        case .running: "\(minutes) min left in your \(what)."
        case .paused: "Your \(what) is paused with \(minutes) min left."
        default: "No session running. Say \"Start a focus in Pomly\" to begin."
        }
        return .result(value: s.isActive ? minutes : 0, dialog: dialog)
    }
}
