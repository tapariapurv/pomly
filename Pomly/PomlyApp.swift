import SwiftUI
import AppIntents

@main
struct PomlyApp: App {
    @AppStorage(Pref.appearance, store: .shared) private var appearance = 0
    @AppStorage(Pref.theme, store: .shared) private var theme = 0

    init() { Pref.register() }

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint((Theme(rawValue: theme) ?? .ember).tint)
                .preferredColorScheme(appearance == 1 ? .light : appearance == 2 ? .dark : nil)
        }
        .modelContainer(Store.container)
        #if os(macOS)
        .defaultSize(width: 920, height: 640)
        #endif

        #if os(macOS)
        // "Full Screen" on Mac: a minimal timer window to park anywhere or take full screen.
        Window("Timer", id: "timer") { FullScreenTimer(tint: (Theme(rawValue: theme) ?? .ember).tint) }
            .defaultSize(width: 560, height: 360)
        MenuBarExtra { MenuBarMenu() } label: { MenuBarLabel() }
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
        }
    }
}

#if os(macOS)
/// Menu bar: the time left at a glance, the main actions one click away.
struct MenuBarLabel: View {
    private let engine = TimerEngine.shared
    var body: some View {
        let s = engine.snap
        if s.isActive {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                Label(s.remaining(at: ctx.date).clock, systemImage: s.status == .paused ? "pause.circle" : s.phase == .focus ? "timer" : "cup.and.saucer")
                    .monospacedDigit()
            }
        } else {
            Image(systemName: "timer")
        }
    }
}

struct MenuBarMenu: View {
    private let engine = TimerEngine.shared
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let s = engine.snap
        switch s.status {
        case .running:
            Button("Pause") { engine.pause() }.keyboardShortcut("p")
            Button("End Session") { engine.stop() }
        case .paused:
            Button("Resume") { Task { await engine.resume() } }.keyboardShortcut("p")
            Button("End Session") { engine.stop() }
        case .idle, .finished:
            Button("Start Focus") { Task { await engine.start(.focus) } }.keyboardShortcut("f")
            Button("Take a Break") { Task { await engine.start(.rest) } }.keyboardShortcut("b")
        }
        Divider()
        Button("Show Timer") { openWindow(id: "timer"); NSApp.activate() }
        Button("Open Pomly") { NSApp.activate(); NSApp.windows.first { $0.title == "Pomly" }?.makeKeyAndOrderFront(nil) }
        Divider()
        Button("Quit Pomly") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
#endif

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
