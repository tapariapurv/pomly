import SwiftUI
import SwiftData
#if os(iOS)
import AlarmKit
#endif

struct SettingsView: View {
    @AppStorage(Pref.focusMin, store: .shared) private var focusMin = 25
    @AppStorage(Pref.breakMin, store: .shared) private var breakMin = 5
    @AppStorage(Pref.goalMin, store: .shared) private var goalMin = 120
    @AppStorage(Pref.appearance, store: .shared) private var appearance = 0
    @AppStorage(Pref.theme, store: .shared) private var theme = 0
    @AppStorage(Pref.sound, store: .shared) private var sound = 0
    @AppStorage(Pref.haptics, store: .shared) private var haptics = true
    @AppStorage(Pref.liveStyle, store: .shared) private var liveStyle = 0
    @Environment(\.modelContext) private var context
    @Environment(\.openURL) private var openURL
    @State private var confirmReset = false
    @State private var syncing = false
    #if os(iOS)
    @State private var alarmsDenied = AlarmManager.shared.authorizationState == .denied
    #endif

    var body: some View {
        NavigationStack {
            Form {
                Section("Timer") {
                    Stepper(value: $focusMin, in: 5...120, step: 5) { LabeledContent("Focus", value: minutes(focusMin)) }
                    Stepper(value: $breakMin, in: 1...30) { LabeledContent("Break", value: minutes(breakMin)) }
                    Stepper(value: $goalMin, in: 15...600, step: 15) { LabeledContent("Daily Goal", value: minutes(goalMin)) }
                    NavigationLink("Advanced") { AdvancedSettings() }
                }

                Section {
                    #if os(macOS)
                    LabeledContent("Sync Devices") { Button(Sync.shared.isPaired ? "Manage…" : "Set Up…") { syncing = true } }
                    #else
                    Button { syncing = true } label: {
                        LabeledContent("Sync Devices") {
                            HStack(spacing: 6) {
                                Text(Sync.shared.isPaired ? "On" : "Off")
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                    #endif
                } footer: {
                    Text("Keep your timer and history the same on iPhone, iPad, Mac and Apple Watch.")
                }

                Section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        Text("System").tag(0)
                        Text("Light").tag(1)
                        Text("Dark").tag(2)
                    }
                    .pickerStyle(.segmented)
                    themeRow
                    #if os(iOS)
                    Picker("Live Activity", selection: $liveStyle) {
                        ForEach(LiveStyle.allCases) { Text($0.name).tag($0.rawValue) }
                    }
                    #endif
                }

                Section {
                    Picker("Alert Sound", selection: $sound) {
                        Text("Classic").tag(0)
                        Text("Soft Chime").tag(1)
                    }
                    Toggle("Haptics", isOn: $haptics)
                    #if os(iOS)
                    if alarmsDenied {
                        Button("Allow Alarms in Settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                    }
                    #endif
                } header: {
                    Text("Alerts")
                } footer: {
                    Text("Pomly rings when a session ends, even in Silent mode. Start a break right from the alert.")
                }

                Section {
                    NavigationLink("Silence Notifications") { SilenceGuide() }
                }

                Section {
                    Button("Reset History", role: .destructive) { confirmReset = true }
                } footer: {
                    Text("Pomly \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                }
            }
            .pomlyBackground()
            .navigationTitle("Settings")
            .sheet(isPresented: $syncing) { SyncView() }
            .onChange(of: focusMin) { _, m in TimerEngine.shared.setDuration(TimeInterval(m * 60)) }
            .onChange(of: liveStyle) { TimerEngine.shared.lookChanged() } // re-renders a running Live Activity
            .onChange(of: theme) { TimerEngine.shared.lookChanged() } // widgets and the control pick up the new tint
            .confirmationDialog("Delete all sessions?", isPresented: $confirmReset, titleVisibility: .visible) {
                Button("Delete All Sessions", role: .destructive) {
                    try? context.delete(model: Session.self)
                    Sync.shared.removeAll()
                    try? context.save()
                    TimerEngine.shared.historyChanged()
                }
            } message: {
                Text("This can't be undone.")
            }
        }
    }

    private var themeRow: some View {
        HStack {
            Text("Theme")
            Spacer(minLength: 8)
            ForEach(Theme.allCases) { t in
                Button { theme = t.rawValue } label: {
                    Circle().fill(t.tint).frame(width: 28, height: 28)
                        .overlay {
                            if theme == t.rawValue {
                                Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(Theme.onTint)
                            }
                        }
                        .frame(width: 40, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(t.name)
                .accessibilityAddTraits(theme == t.rawValue ? .isSelected : [])
            }
        }
    }
}

func minutes(_ m: Int) -> String { TimeInterval(m * 60).minutesText }

struct AdvancedSettings: View {
    @AppStorage(Pref.longBreakMin, store: .shared) private var longBreakMin = 15
    @AppStorage(Pref.longEvery, store: .shared) private var longEvery = 4
    @AppStorage(Pref.autoBreak, store: .shared) private var autoBreak = false
    @AppStorage(Pref.autoFocus, store: .shared) private var autoFocus = false

    var body: some View {
        Form {
            Section {
                Stepper(value: $longBreakMin, in: 5...60, step: 5) { LabeledContent("Long Break", value: minutes(longBreakMin)) }
                Stepper(value: $longEvery, in: 0...8) {
                    LabeledContent("Every", value: longEvery == 0 ? String(localized: "Off") : String(localized: "\(longEvery) sessions"))
                }
            } header: {
                Text("Long Breaks")
            } footer: {
                Text("After a few focus sessions, Pomly suggests a longer break.")
            }
            Section {
                Toggle("Start Breaks Automatically", isOn: $autoBreak)
                Toggle("Start Focus After Breaks", isOn: $autoFocus)
            } header: {
                Text("Auto-Start")
            } footer: {
                Text("Off by default, so you decide when to rest.")
            }
        }
        .pomlyBackground()
        .navigationTitle("Advanced")
    }
}

struct SilenceGuide: View {
    var body: some View {
        Form {
            Section {
                Label("Open Settings › Focus", systemImage: "1.circle")
                Label("Choose a Focus, like Work, or create one", systemImage: "2.circle")
                Label("Under Focus Filters, tap Add Filter, then Pomly", systemImage: "3.circle")
                Label("Turn on Start a Session Automatically", systemImage: "4.circle")
            } footer: {
                Text("iOS doesn't let apps silence notifications. A Focus does it system-wide, and Pomly's filter starts your session when it turns on.")
            }
        }
        .pomlyBackground()
        .navigationTitle("Silence Notifications")
    }
}

/// Warm app background behind lists and forms so every tab feels like one place.
/// App background plus a readable column: on iPad and Mac, forms and lists stop at ~680 pt instead of spanning the window.
struct PomlyBackground: ViewModifier {
    @AppStorage(Pref.theme, store: .shared) private var theme = 0
    @State private var width: CGFloat = 0

    func body(content: Content) -> some View {
        let side = (width - 680) / 2
        content
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .contentMargins(.horizontal, side > 0 ? side : nil, for: .scrollContent)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            #if os(iOS)
            .navigationBarTitleDisplayMode(side > 0 ? .inline : .automatic) // a centered column wants a centered title
            #endif
            .background(AppBackground(tint: (Theme(rawValue: theme) ?? .ember).tint))
    }
}

extension View {
    func pomlyBackground() -> some View { modifier(PomlyBackground()) }
}
