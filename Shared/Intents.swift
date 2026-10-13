import AppIntents

// LiveActivityIntent: always runs in the app process, also when tapped in a widget, control or Live Activity (iOS only).
#if os(iOS)
typealias PomlyIntent = LiveActivityIntent
#else
typealias PomlyIntent = AppIntent
#endif

struct StartFocusIntent: PomlyIntent {
    static let title: LocalizedStringResource = "Start Focus"
    static let description = IntentDescription("Starts a focus session.")
    @Parameter(title: "Minutes") var minutes: Int?

    init() {}
    init(minutes: Int?) { self.minutes = minutes }

    @MainActor func perform() async throws -> some IntentResult {
        await TimerEngine.shared.start(.focus, seconds: minutes.map { TimeInterval($0 * 60) })
        return .result()
    }
}

struct StartBreakIntent: PomlyIntent {
    static let title: LocalizedStringResource = "Take a Break"
    static let description = IntentDescription("Starts a break.")
    @Parameter(title: "Minutes") var minutes: Int?

    init() {}

    @MainActor func perform() async throws -> some IntentResult {
        await TimerEngine.shared.start(.rest, seconds: minutes.map { TimeInterval($0 * 60) })
        return .result()
    }
}

struct PauseIntent: PomlyIntent {
    static let title: LocalizedStringResource = "Pause Timer"
    @MainActor func perform() async throws -> some IntentResult {
        TimerEngine.shared.pause()
        return .result()
    }
}

struct ResumeIntent: PomlyIntent {
    static let title: LocalizedStringResource = "Resume Timer"
    @MainActor func perform() async throws -> some IntentResult {
        await TimerEngine.shared.resume()
        return .result()
    }
}

struct StopIntent: PomlyIntent {
    static let title: LocalizedStringResource = "End Session"
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
