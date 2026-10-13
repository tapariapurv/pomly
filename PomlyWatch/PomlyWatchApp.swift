import SwiftUI

@main
struct PomlyWatchApp: App {
    init() { Pref.register() }

    var body: some Scene {
        WindowGroup { WatchFocusView() }
            .modelContainer(Store.container)
    }
}

/// The phone's focus screen, sized for the wrist: same dial, same flow. The Digital Crown sets the length.
struct WatchFocusView: View {
    private let engine = TimerEngine.shared
    @AppStorage(Pref.theme, store: .shared) private var themeRaw = 0
    @Environment(\.scenePhase) private var scenePhase
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
                    VStack(spacing: 0) {
                        Text(s.status == .finished ? "DONE" : s.phase == .focus ? "FOCUS" : "BREAK")
                            .font(.caption2.weight(.semibold)).fontWidth(.expanded)
                            .foregroundStyle(tint)
                        Text((s.status == .idle ? s.planned : left).clock)
                            .font(.system(size: 34, weight: .regular, design: .serif).monospacedDigit())
                            .contentTransition(.numericText(countsDown: true))
                            .minimumScaleFactor(0.6)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 24)
                }
                .animation(.snappy, value: fraction)
            }
            .focusable(s.status == .idle)
            .digitalCrownRotation($minutes, from: 1, through: 120, by: 1, sensitivity: .medium,
                                  isContinuous: false, isHapticFeedbackEnabled: true)
            .onChange(of: minutes) { _, m in engine.setDuration(m * 60) }
            .onChange(of: s.planned) { _, p in if p >= 60 { minutes = (p / 60).rounded() } }
            .accessibilityElement(children: .combine)
            .accessibilityValue(s.status == .idle ? "\(Int(s.planned / 60)) minutes" : "")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sync Devices", systemImage: "arrow.triangle.2.circlepath") { syncing = true }
                }
                ToolbarItemGroup(placement: .bottomBar) { controls(s) }
            }
            .sheet(isPresented: $syncing) { SyncView() }
        }
        .tint(tint)
        .sensoryFeedback(.success, trigger: s.status == .finished) { _, new in new }
        .onChange(of: scenePhase, initial: true) { _, phase in
            guard phase == .active else { return }
            engine.refresh()
            Sync.shared.resume()
        }
    }

    @ViewBuilder private func controls(_ s: TimerSnapshot) -> some View {
        switch s.status {
        case .idle:
            Spacer()
            Button("Start", systemImage: "play.fill") { Task { await engine.start(.focus, seconds: s.planned) } }
                .buttonStyle(.glassProminent)
            Spacer()
        case .running, .paused:
            Button("End", systemImage: "xmark") { engine.stop() }
            Spacer()
            if s.status == .running {
                Button("Pause", systemImage: "pause.fill") { engine.pause() }.buttonStyle(.glassProminent)
            } else {
                Button("Resume", systemImage: "play.fill") { Task { await engine.resume() } }.buttonStyle(.glassProminent)
            }
        case .finished:
            Button("Done", systemImage: "checkmark") { engine.reset() }
            Spacer()
            let next: Phase = s.phase == .focus ? .rest : .focus
            Button(next == .rest ? "Take a Break" : "Focus", systemImage: next == .rest ? "cup.and.saucer.fill" : "timer") {
                Task { await engine.start(next) }
            }
            .buttonStyle(.glassProminent)
        }
    }
}
