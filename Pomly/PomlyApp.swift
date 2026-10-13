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
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active else { return }
            TimerEngine.shared.refresh()
            Sync.shared.resume()
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
