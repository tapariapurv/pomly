import SwiftUI
import SwiftData
import AlarmKit
import ActivityKit
import UserNotifications
import WidgetKit
import OSLog

/// Single source of truth for the current session. Date-based: stores `endDate`, never counts down.
/// AlarmKit owns the system countdown (Live Activity, alert); a local notification is the fallback.
@MainActor @Observable
final class TimerEngine {
    static let shared = TimerEngine()

    private(set) var snap = TimerSnapshot.load() {
        didSet { if snap != oldValue { snap.save() } }
    }
    private(set) var lifetimeCompleted = UserDefaults.shared.integer(forKey: "lifetimeCompleted") {
        didSet { UserDefaults.shared.set(lifetimeCompleted, forKey: "lifetimeCompleted") }
    }
    private var alarms: AlarmManager { .shared }
    /// Live Activity we run ourselves when AlarmKit isn't allowed; same attributes, so the same widget UI renders it.
    private var activity = Activity<PomlyActivityAttributes>.activities.first

    private init() {
        Task { await observeAlarms() }
        refresh()
    }

    // MARK: Actions

    func start(_ phase: Phase, seconds: TimeInterval? = nil) async {
        refresh()
        let duration = min(180 * 60, max(1, seconds ?? defaultSeconds(for: phase))) // before stop() resets the length
        if snap.isActive { stop() } else { cancelAlert() }
        var s = snap
        s.phase = phase
        s.status = .running
        s.planned = duration
        s.remaining = duration
        s.startedAt = .now
        s.endDate = .now + duration
        s.alarmID = nil
        snap = s
        endActivity()

        let id = await scheduleAlert(for: s)
        // The user may have stopped or restarted while the permission prompt was up.
        guard snap.startedAt == s.startedAt, snap.isActive else {
            if let id { try? alarms.cancel(id: id) }
            return
        }
        snap.alarmID = id
        surfacesChanged()
    }

    func pause() {
        guard snap.status == .running else { return }
        snap.remaining = snap.remaining()
        snap.endDate = nil
        snap.status = .paused
        if let id = snap.alarmID { try? alarms.pause(id: id) }
        removeNotification()
        surfacesChanged()
    }

    func resume() async {
        guard snap.status == .paused else { return }
        snap.endDate = .now + snap.remaining
        snap.status = .running
        if let id = snap.alarmID { try? alarms.resume(id: id) } else { await notify(snap) }
        surfacesChanged()
    }

    /// Ends early. Focus that ran at least a minute still counts.
    func stop() {
        if snap.phase == .focus, snap.isActive { log(snap.planned - snap.remaining(), completed: false) }
        reset()
    }

    /// Back to a fresh idle focus (keeps the label and long-break cycle).
    func reset() {
        cancelAlert()
        snap = TimerSnapshot(phase: .focus, planned: snap.planned < 60 ? 15 : TimeInterval(Pref.int(Pref.focusMin) * 60),
                             label: snap.label, focusCount: snap.focusCount)
        surfacesChanged()
    }

    func setDuration(_ seconds: TimeInterval) {
        guard snap.status == .idle else { return }
        snap.planned = seconds
    }

    func setLabel(_ label: String) { snap.label = label }

    /// Test builds: 15-second sessions (and breaks) to try the full cycle fast.
    func toggleQuick() {
        guard !snap.isActive else { return }
        cancelAlert()
        snap.status = .idle
        snap.phase = .focus
        snap.planned = snap.planned < 60 ? TimeInterval(Pref.int(Pref.focusMin) * 60) : 15
    }

    func defaultSeconds(for phase: Phase) -> TimeInterval {
        if snap.planned < 60 { return snap.planned } // quick test sessions keep their breaks quick too
        let minutes = phase == .focus ? Pref.int(Pref.focusMin)
            : Pref.breakMinutes(focusCount: snap.focusCount, every: Pref.int(Pref.longEvery),
                                short: Pref.int(Pref.breakMin), long: Pref.int(Pref.longBreakMin))
        return TimeInterval(minutes * 60)
    }

    // MARK: Sync

    /// Launch / foreground / alarm change: adopt pauses made from the Live Activity, finish elapsed sessions.
    func refresh() {
        syncFromSystem()
        if snap.status == .running, let end = snap.endDate, end <= .now { complete() }
        cacheToday()
    }

    func historyChanged() {
        cacheToday()
        surfacesChanged()
    }

    private func complete() {
        let phase = snap.phase
        if phase == .focus {
            log(snap.planned, completed: true)
            snap.focusCount += 1
            lifetimeCompleted += 1
        }
        snap.status = .finished
        snap.endDate = nil
        snap.remaining = 0
        surfacesChanged()
        if phase == .focus, Pref.bool(Pref.autoBreak) { Task { await start(.rest) } }
        if phase == .rest, Pref.bool(Pref.autoFocus) { Task { await start(.focus) } }
    }

    private func observeAlarms() async {
        for await list in alarms.alarmUpdates {
            guard let id = snap.alarmID else { continue }
            switch list.first(where: { $0.id == id })?.state {
            case .alerting?: if snap.isActive { complete() }
            case .paused?, .countdown?: syncFromSystem()
            default: refresh()
            }
        }
    }

    /// The AlarmKit Live Activity holds the exact pause/resume state when it changed outside the app.
    private func syncFromSystem() {
        guard snap.isActive, let id = snap.alarmID,
              let mode = Activity<AlarmAttributes<PomlyMetadata>>.activities
                .first(where: { $0.content.state.alarmID == id })?.content.state.mode else { return }
        let before = snap
        switch mode {
        case .countdown(let c):
            snap.status = .running
            snap.endDate = c.fireDate
        case .paused(let p):
            snap.status = .paused
            snap.endDate = nil
            snap.remaining = p.totalCountdownDuration - p.previouslyElapsedDuration
        default: break
        }
        if snap != before { surfacesChanged() }
    }

    // MARK: History

    private func log(_ duration: TimeInterval, completed: Bool) {
        guard duration >= 60 || snap.planned < 60 else { return } // quick test sessions count too
        let ctx = Store.container.mainContext
        ctx.insert(Session(start: snap.startedAt ?? .now.addingTimeInterval(-duration), duration: duration,
                           planned: snap.planned, label: snap.label, completed: completed))
        try? ctx.save()
        cacheToday()
    }

    private func cacheToday() {
        let start = Calendar.current.startOfDay(for: .now)
        let today = (try? Store.container.mainContext.fetch(FetchDescriptor<Session>(predicate: #Predicate { $0.start >= start }))) ?? []
        Today.store(today.reduce(0) { $0 + $1.duration }, count: today.count)
    }

    private func surfacesChanged() {
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
        updateActivity()
    }

    private func updateActivity() {
        guard snap.alarmID == nil else { return } // AlarmKit runs its own
        guard snap.isActive else { return endActivity() }
        let s = snap
        let state = PomlyActivityAttributes.ContentState(end: s.status == .running ? s.endDate : nil, remaining: s.remaining(), total: s.planned)
        let content = ActivityContent(state: state, staleDate: s.endDate)
        if let activity {
            Task { await activity.update(content) }
        } else {
            do { activity = try Activity.request(attributes: PomlyActivityAttributes(phase: s.phase, label: s.label), content: content) }
            catch { Logger(subsystem: "com.purvt.pomly", category: "timer").error("Live Activity failed: \(error, privacy: .public)") }
        }
    }

    private func endActivity() {
        guard let a = activity else { return }
        activity = nil
        Task { await a.end(nil, dismissalPolicy: .immediate) }
    }

    // MARK: Alerts

    private func scheduleAlert(for s: TimerSnapshot) async -> Alarm.ID? {
        if alarms.authorizationState == .notDetermined { _ = try? await alarms.requestAuthorization() }
        guard alarms.authorizationState == .authorized else {
            await notify(s)
            return nil
        }
        let config: AlarmManager.AlarmConfiguration<PomlyMetadata> = .timer(
            duration: s.planned, attributes: attributes(for: s), stopIntent: FinishIntent(),
            secondaryIntent: s.phase == .focus ? StartBreakIntent() : StartFocusIntent(), sound: alertSound)
        let id = UUID()
        do {
            _ = try await alarms.schedule(id: id, configuration: config)
            return id
        } catch {
            await notify(s)
            return nil
        }
    }

    private var alertSound: AlertConfiguration.AlertSound { Pref.int(Pref.sound) == 1 ? .named("chime.caf") : .default }

    private func attributes(for s: TimerSnapshot) -> AlarmAttributes<PomlyMetadata> {
        let focus = s.phase == .focus
        let tint = Theme.current.tint
        let done: LocalizedStringResource = focus ? "Focus Complete" : "Break's Over"
        let next: LocalizedStringResource = focus ? "Take a Break" : "Focus Again"
        let running: LocalizedStringResource = focus ? "Focusing" : "On a Break"
        let presentation = AlarmPresentation(
            alert: .init(title: done,
                         stopButton: .init(text: "Done", textColor: tint, systemImageName: "checkmark"),
                         secondaryButton: .init(text: next, textColor: tint, systemImageName: focus ? "cup.and.saucer.fill" : "timer"),
                         secondaryButtonBehavior: .custom),
            countdown: .init(title: running, pauseButton: .init(text: "Pause", textColor: tint, systemImageName: "pause.fill")),
            paused: .init(title: "Paused", resumeButton: .init(text: "Resume", textColor: tint, systemImageName: "play.fill")))
        return AlarmAttributes(presentation: presentation, metadata: PomlyMetadata(phase: s.phase, label: s.label), tintColor: tint)
    }

    private func notify(_ s: TimerSnapshot) async {
        guard let end = s.endDate else { return }
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = s.phase == .focus ? String(localized: "Focus Complete") : String(localized: "Break's Over")
        content.body = s.phase == .focus ? String(localized: "Nice work. Time for a break.") : String(localized: "Ready to focus again?")
        content.sound = Pref.int(Pref.sound) == 1 ? UNNotificationSound(named: UNNotificationSoundName("chime.caf")) : .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, end.timeIntervalSinceNow), repeats: false)
        try? await center.add(UNNotificationRequest(identifier: "pomly.end", content: content, trigger: trigger))
    }

    private func cancelAlert() {
        if let id = snap.alarmID { try? alarms.cancel(id: id) }
        removeNotification()
    }

    /// Off the main thread: this is a synchronous XPC call that can stall if the notification daemon is busy.
    private func removeNotification() {
        Task.detached { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["pomly.end"]) }
    }
}
