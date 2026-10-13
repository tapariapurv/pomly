import SwiftUI
import SwiftData
import UserNotifications
import WidgetKit
import OSLog
#if os(iOS)
import AlarmKit
import ActivityKit
#endif

/// Single source of truth for the current session. Date-based: stores `endDate`, never counts down.
/// iOS: AlarmKit owns the system countdown (Live Activity, alert). Elsewhere, and as the fallback, a local notification.
@MainActor @Observable
final class TimerEngine {
    static let shared = TimerEngine()

    private(set) var snap = TimerSnapshot.load() {
        didSet {
            guard snap != oldValue else { return }
            snap.save()
            Sync.shared.push(snap)
        }
    }
    private(set) var lifetimeCompleted = UserDefaults.shared.integer(forKey: "lifetimeCompleted") {
        didSet { UserDefaults.shared.set(lifetimeCompleted, forKey: "lifetimeCompleted") }
    }
    #if os(iOS)
    private var alarms: AlarmManager { .shared }
    /// Live Activity we run ourselves when AlarmKit isn't allowed; same attributes, so the same widget UI renders it.
    private var activity = Activity<PomlyActivityAttributes>.activities.first
    #endif

    private init() {
        #if os(iOS)
        Task { await observeAlarms() }
        #endif
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
        await arm(s)
    }

    func pause() {
        guard snap.status == .running else { return }
        snap.remaining = snap.remaining()
        snap.endDate = nil
        snap.status = .paused
        #if os(iOS)
        if let id = snap.alarmID { try? alarms.pause(id: id) }
        #endif
        removeNotification()
        surfacesChanged()
    }

    func resume() async {
        guard snap.status == .paused else { return }
        snap.endDate = .now + snap.remaining
        snap.status = .running
        #if os(iOS)
        if let id = snap.alarmID {
            try? alarms.resume(id: id)
            return surfacesChanged()
        }
        #endif
        await arm(snap)
    }

    /// Another device changed the session: mirror it and set this device's own end alert.
    func adoptRemote(_ remote: TimerSnapshot) {
        var r = remote, mine = snap
        r.alarmID = nil
        mine.alarmID = nil
        guard r != mine else { return }
        cancelAlert()
        snap = r
        if r.status == .running {
            endActivity()
            Task { await arm(r) }
        } else {
            surfacesChanged()
        }
    }

    /// Schedules the end alert, unless the session changed while the permission prompt was up.
    private func arm(_ s: TimerSnapshot) async {
        let id = await scheduleAlert(for: s)
        guard snap.endDate == s.endDate, snap.status == .running else { return cancelAlarm(id) }
        snap.alarmID = id
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

    #if os(iOS)
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
    #endif

    private func syncFromSystem() {
        #if os(iOS)
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
        #endif
    }

    // MARK: History

    private func log(_ duration: TimeInterval, completed: Bool) {
        guard duration >= 60 || snap.planned < 60 else { return } // quick test sessions count too
        let ctx = Store.container.mainContext
        let start = snap.startedAt ?? .now.addingTimeInterval(-duration)
        // A synced device may have logged this very session already.
        guard (try? ctx.fetchCount(FetchDescriptor<Session>(predicate: #Predicate { $0.start == start }))) == 0 else { return }
        let session = Session(start: start, duration: duration, planned: snap.planned, label: snap.label, completed: completed)
        ctx.insert(session)
        try? ctx.save()
        cacheToday()
        Sync.shared.add(session)
    }

    private func cacheToday() {
        let start = Calendar.current.startOfDay(for: .now)
        let today = (try? Store.container.mainContext.fetch(FetchDescriptor<Session>(predicate: #Predicate { $0.start >= start }))) ?? []
        Today.store(today.reduce(0) { $0 + $1.duration }, count: today.count)
    }

    private func surfacesChanged() {
        WidgetCenter.shared.reloadAllTimelines()
        #if os(iOS)
        ControlCenter.shared.reloadAllControls()
        updateActivity()
        #endif
    }

    #if os(iOS)

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

    #endif

    private func endActivity() {
        #if os(iOS)
        guard let a = activity else { return }
        activity = nil
        Task { await a.end(nil, dismissalPolicy: .immediate) }
        #endif
    }

    // MARK: Alerts

    private func scheduleAlert(for s: TimerSnapshot) async -> UUID? {
        #if os(iOS)
        if alarms.authorizationState == .notDetermined { _ = try? await alarms.requestAuthorization() }
        if alarms.authorizationState == .authorized {
            let config: AlarmManager.AlarmConfiguration<PomlyMetadata> = .timer(
                duration: s.remaining(), attributes: attributes(for: s), stopIntent: FinishIntent(),
                secondaryIntent: s.phase == .focus ? StartBreakIntent() : StartFocusIntent(), sound: alertSound)
            let id = UUID()
            if (try? await alarms.schedule(id: id, configuration: config)) != nil { return id }
        }
        #endif
        await notify(s)
        return nil
    }

    private func cancelAlarm(_ id: UUID?) {
        #if os(iOS)
        if let id { try? alarms.cancel(id: id) }
        #endif
    }

    #if os(iOS)

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
    #endif

    private func notify(_ s: TimerSnapshot) async {
        guard let end = s.endDate else { return }
        let center = UNUserNotificationCenter.current()
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = s.phase == .focus ? String(localized: "Focus Complete") : String(localized: "Break's Over")
        content.body = s.phase == .focus ? String(localized: "Nice work. Time for a break.") : String(localized: "Ready to focus again?")
        #if os(watchOS)
        content.sound = .default
        #else
        content.sound = Pref.int(Pref.sound) == 1 ? UNNotificationSound(named: UNNotificationSoundName("chime.caf")) : .default
        #endif
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, end.timeIntervalSinceNow), repeats: false)
        try? await center.add(UNNotificationRequest(identifier: "pomly.end", content: content, trigger: trigger))
    }

    private func cancelAlert() {
        cancelAlarm(snap.alarmID)
        removeNotification()
    }

    /// Off the main thread: this is a synchronous XPC call that can stall if the notification daemon is busy.
    private func removeNotification() {
        Task.detached { UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["pomly.end"]) }
    }
}
