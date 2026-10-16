import SwiftUI
import AppIntents

@main
struct PomlyApp: App {
    @AppStorage(Pref.appearance, store: .shared) private var appearance = 0
    @AppStorage(Pref.theme, store: .shared) private var theme = 0

    #if os(macOS)
    @NSApplicationDelegateAdaptor(PomlyAppDelegate.self) private var appDelegate
    #endif

    init() {
        Pref.register()
        TimerEngine.didLog = { Planner.log($0) }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint((Theme(rawValue: theme) ?? .ember).tint)
                .preferredColorScheme(appearance == 1 ? .light : appearance == 2 ? .dark : nil)
        }
        .modelContainer(Store.container)
        #if os(macOS)
        .defaultSize(width: 920, height: 640)
        .commands { PomlyCommands() }
        #endif

        #if os(macOS)
        // "Full Screen" on Mac: a minimal timer window to park anywhere or take full screen.
        Window("Timer", id: "timer") { FullScreenTimer(tint: (Theme(rawValue: theme) ?? .ember).tint) }
            .defaultSize(width: 560, height: 360)
        Settings { SettingsView().frame(width: 460, height: 560).tint((Theme(rawValue: theme) ?? .ember).tint) }
            .modelContainer(Store.container)
        #endif
    }
}

struct RootView: View {
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            Tab("Focus", systemImage: "timer") { FocusView() }
            Tab("History", systemImage: "chart.bar.fill") { HistoryView() }
            Tab("Settings", systemImage: "gearshape.fill") { SettingsView() }
        }
        #if os(iOS)
        .tabBarMinimizeBehavior(.onScrollDown)
        #endif
        #if os(macOS)
        .frame(minWidth: 400, minHeight: 620)
        #endif
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active else { return }
            TimerEngine.shared.refresh()
            Sync.shared.resume()
            Task { await Updater.shared.check() }
        }
    }
}

struct PomlyShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: StartFocusIntent(), phrases: ["Start a focus in \(.applicationName)",
                                                          "Start focusing with \(.applicationName)",
                                                          "Start \(.applicationName)"],
                    shortTitle: "Start Focus", systemImageName: "timer")
        AppShortcut(intent: StartBreakIntent(), phrases: ["Take a break in \(.applicationName)"],
                    shortTitle: "Take a Break", systemImageName: "cup.and.saucer.fill")
        AppShortcut(intent: TimeLeftIntent(), phrases: ["How much time is left in \(.applicationName)",
                                                        "Check my \(.applicationName) timer"],
                    shortTitle: "Time Left", systemImageName: "hourglass")
        AppShortcut(intent: PauseIntent(), phrases: ["Pause \(.applicationName)"], shortTitle: "Pause", systemImageName: "pause.fill")
        AppShortcut(intent: ResumeIntent(), phrases: ["Resume \(.applicationName)"], shortTitle: "Resume", systemImageName: "play.fill")
        AppShortcut(intent: StopIntent(), phrases: ["Stop \(.applicationName)", "End my focus in \(.applicationName)"],
                    shortTitle: "End Session", systemImageName: "xmark.circle")
    }
}

/// Pair Pomly with a system Focus: the Focus silences notifications, Pomly starts the session.
struct PomlyFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Pomly"
    static let description: IntentDescription? = "Start a focus session when this Focus turns on."
    @Parameter(title: "Start a Session Automatically", default: false) var autoStart: Bool

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: autoStart ? "Starts a focus session" : "Doesn't start a session")
    }

    @MainActor func perform() async throws -> some IntentResult {
        if autoStart, !TimerEngine.shared.snap.isActive { await TimerEngine.shared.start(.focus) }
        return .result()
    }
}
