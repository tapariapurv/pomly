import SwiftUI

@main
struct PomlyWatchApp: App {
    init() { Pref.register() }

    var body: some Scene {
        WindowGroup { WatchFocusView() }
            .modelContainer(Store.container)
    }
}

/// The phone's dial, edge to edge. The Digital Crown sets the length; controls sit in the corners like Timer.
struct WatchFocusView: View {
    private let engine = TimerEngine.shared
    @AppStorage(Pref.theme, store: .shared) private var themeRaw = 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var dim
    @State private var minutes = Double(Pref.int(Pref.focusMin))
    @State private var syncing = false

    private var tint: Color { (Theme(rawValue: themeRaw) ?? .ember).tint }

    var body: some View {
        let s = engine.snap
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let left = s.remaining(at: ctx.date)
                let fraction = s.status == .idle ? DialFace.idleFraction(s.planned) : s.status == .finished ? 1 : left / max(s.planned, 1)
                ZStack {
                    DialFace(fraction: fraction, tint: tint, lap: s.status == .idle && s.planned > 3600,
                             knobScale: s.status == .idle ? 1.85 : 1)
                        .opacity(dim ? 0.5 : 1)
                    VStack(spacing: 2) {
                        if !s.label.isEmpty {
                            Text(s.label).font(.footnote).fontDesign(.rounded).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Text((s.status == .idle ? s.planned : left).clock)
                            .font(.system(size: 36, design: .rounded).monospacedDigit())
                            .contentTransition(.numericText(countsDown: true))
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Circle().fill(tint).frame(width: 4, height: 4)
                            Text(status(s))
                        }
                        .font(.system(size: 10, weight: .semibold)).fontWidth(.expanded)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 30)
                }
                .padding(16) // clears the clock and corner buttons
                .animation(.snappy, value: fraction)
            }
            .ignoresSafeArea() // the round dial leaves the corners free for the clock and controls
            .focusable(s.status == .idle)
            .digitalCrownRotation($minutes, from: 1, through: 120, by: 1, sensitivity: .medium,
                                  isContinuous: false, isHapticFeedbackEnabled: true)
            .onChange(of: minutes) { _, m in engine.setDuration(m * 60) }
            .onChange(of: s.planned) { _, p in if p >= 60 { minutes = (p / 60).rounded() } }
            .accessibilityElement(children: .combine)
            .containerBackground(for: .navigation) {
                RadialGradient(colors: [tint.opacity(dim ? 0 : 0.3), .black], center: .center, startRadius: 0, endRadius: 150)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sync Devices", systemImage: "arrow.triangle.2.circlepath") { syncing = true }
                }
                ToolbarItemGroup(placement: .bottomBar) { controls(s) }
            }
            .sheet(isPresented: $syncing) { SyncView().tint(tint) }
        }
        .sensoryFeedback(.success, trigger: s.status == .finished) { _, new in new }
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active else { return }
            engine.refresh()
            Sync.shared.resume()
        }
    }

    private func status(_ s: TimerSnapshot) -> LocalizedStringKey {
        switch s.status {
        case .paused: "PAUSED"
        case .finished: s.phase == .focus ? "DONE" : "BREAK OVER"
        default: s.phase == .focus ? "FOCUS" : "BREAK"
        }
    }

    /// Secondary action on the left (neutral), the one likely action on the right (tinted).
    @ViewBuilder private func controls(_ s: TimerSnapshot) -> some View {
        let next: Phase = s.phase == .focus ? .rest : .focus
        switch s.status {
        case .idle:
            Button("Take a Break", systemImage: "cup.and.saucer.fill") { Task { await engine.start(.rest) } }
            Spacer()
            primary("Start", "play.fill") { Task { await engine.start(.focus, seconds: s.planned) } }
        case .running:
            Button("End", systemImage: "xmark") { engine.stop() }
            Spacer()
            primary("Pause", "pause.fill") { engine.pause() }
        case .paused:
            Button("End", systemImage: "xmark") { engine.stop() }
            Spacer()
            primary("Resume", "play.fill") { Task { await engine.resume() } }
        case .finished:
            Button("Done", systemImage: "checkmark") { engine.reset() }
            Spacer()
            primary(next == .rest ? "Take a Break" : "Focus", next == .rest ? "cup.and.saucer.fill" : "timer") {
                Task { await engine.start(next) }
            }
        }
    }

    private func primary(_ title: LocalizedStringKey, _ icon: String, run: @escaping () -> Void) -> some View {
        Button(title, systemImage: icon, action: run)
            .labelStyle(.iconOnly)
            .tint(tint)
            .foregroundStyle(Theme.onTint)
    }
}
