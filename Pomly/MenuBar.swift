#if os(macOS)
import SwiftUI
import AppKit
import Carbon.HIToolbox

final class PomlyAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // A menu bar timer must never be reaped in the background (macOS can auto-terminate windowless SwiftUI apps).
        ProcessInfo.processInfo.disableAutomaticTermination("Pomly keeps a timer in the menu bar")
        ProcessInfo.processInfo.disableSuddenTermination()
        MenuBar.shared.install()
        HotKeys.register()
        if UserDefaults.standard.bool(forKey: "miniTimer") { MiniTimer.show() }
    }

    /// A menu bar timer keeps running when its window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// Menu bar: a compact live timer. Click for the panel; drag down from the icon to pull out a focus length.
/// Costs nothing while idle: the 1 s ticker runs only while a session runs.
@MainActor final class MenuBar: NSObject, NSPopoverDelegate {
    static let shared = MenuBar()

    /// Pomly's Light / Dark / System setting, for windows that live outside the SwiftUI scene.
    static var appearance: NSAppearance? {
        switch Pref.int(Pref.appearance) {
        case 1: NSAppearance(named: .aqua)
        case 2: NSAppearance(named: .darkAqua)
        default: nil
        }
    }

    @Observable final class Model {
        var dragMinutes = 0
        var from = CGPoint.zero // line ends, in overlay coordinates
        var to = CGPoint.zero
        var guided = false // started from the panel's button: no button held, click to set
        var pendingMinutes: Int? // set by a drag: ask what we're focusing on, then start
    }

    let model = Model()
    private let engine = TimerEngine.shared
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var preview: NSPanel?
    private var ticker: Timer?
    private var press: Timer?
    private var lineEnd = NSPoint.zero
    private var anchor: NSWindow?
    private var guide: (poll: Timer, catcher: NSWindow, monitors: [Any])?

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.item = item
        guard let b = item.button else { return }
        b.target = self
        b.action = #selector(pressed)
        b.sendAction(on: [.leftMouseDown, .rightMouseDown])
        b.imagePosition = .imageLeading
        b.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        b.setAccessibilityLabel("Pomly")
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: MenuBarPanel(model: model) { [weak self] in self?.popover.performClose(nil) })
        observe()
        // A menu bar app can run for days without coming forward: look for updates every 6 hours too.
        let t = Timer(timeInterval: 6 * 3600, repeats: true) { _ in Task { await Updater.shared.check() } }
        t.tolerance = 600
        RunLoop.main.add(t, forMode: .common)
        Task { await Updater.shared.check() }
    }

    func popoverDidClose(_ notification: Notification) {
        model.pendingMinutes = nil
        anchor?.orderOut(nil)
    }

    // MARK: Status item

    private func observe() {
        withObservationTracking { update(engine.snap) } onChange: { Task { @MainActor in self.observe() } }
    }

    private func update(_ s: TimerSnapshot) {
        ticker?.invalidate()
        ticker = nil
        if !s.isActive { Updater.shared.installIfIdle() } // a pending update lands between sessions
        if s.status == .running {
            let t = Timer(timeInterval: 1, repeats: true) { _ in Task { @MainActor in MenuBar.shared.draw() } }
            t.tolerance = 0.25
            RunLoop.main.add(t, forMode: .common)
            ticker = t
        }
        draw()
    }

    private func draw() {
        guard let b = item?.button else { return }
        let s = engine.snap, left = s.remaining()
        b.image = Self.ring(s.isActive ? left / max(s.planned, 1) : nil)
        b.title = s.isActive ? " " + left.clock : ""
        b.appearsDisabled = s.status == .paused
        if s.status == .running, left <= 0 { engine.refresh() }
    }

    /// Template ring: progress while a session runs, the dial's hand while idle.
    private static func ring(_ fraction: Double?) -> NSImage {
        let img = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { r in
            let c = NSPoint(x: r.midX, y: r.midY), radius: CGFloat = 6.5
            let track = NSBezierPath()
            track.appendArc(withCenter: c, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = 1.8
            NSColor.black.withAlphaComponent(fraction == nil ? 1 : 0.35).setStroke()
            track.stroke()
            let p = NSBezierPath()
            p.lineWidth = 1.8
            p.lineCapStyle = .round
            if let f = fraction {
                p.appendArc(withCenter: c, radius: radius, startAngle: 90, endAngle: 90 - 360 * min(max(f, 0.001), 1), clockwise: true)
            } else {
                p.move(to: c)
                p.line(to: NSPoint(x: c.x + 3.2, y: c.y + 3.2))
            }
            NSColor.black.setStroke()
            p.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }

    // MARK: Click or drag

    /// Guided drag: the line follows the pointer without holding the button. Click or Return sets it, Esc cancels.
    /// A faint full-screen layer catches that click, so it never lands in another app.
    func startGuided() {
        popover.performClose(nil)
        guard guide == nil, let b = item?.button, let win = b.window, let screen = win.screen ?? NSScreen.main else { return }
        let icon = win.convertToScreen(b.convert(b.bounds, to: nil)), start = NSPoint(x: icon.midX, y: icon.midY)
        model.guided = true
        model.dragMinutes = 0
        let catcher = KeyPanel(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        catcher.backgroundColor = NSColor.black.withAlphaComponent(0.12)
        catcher.isOpaque = false
        catcher.hidesOnDeactivate = false // panels hide when the app isn't frontmost; this one must not
        catcher.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue - 1)
        NSApp.activate()
        catcher.makeKeyAndOrderFront(nil)
        let poll = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated { MenuBar.shared.showPreview(to: NSEvent.mouseLocation, from: start) }
        }
        RunLoop.main.add(poll, forMode: .common)
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { e in
            MainActor.assumeIsolated {
                MenuBar.shared.endGuided(confirm: e.type == .leftMouseDown || e.keyCode == 36 || e.keyCode == 76) // click or Return sets; right-click, Esc or any other key cancels
            }
            return nil
        }
        // Backup: a click that still lands in another app ends the mode too, so it can never get stuck.
        let outside = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { e in
            MainActor.assumeIsolated { MenuBar.shared.endGuided(confirm: e.type == .leftMouseDown) }
        }
        guide = (poll, catcher, [monitor, outside].compactMap { $0 })
        showPreview(to: NSEvent.mouseLocation, from: start)
    }

    private func endGuided(confirm: Bool) {
        guard let g = guide else { return }
        guide = nil
        g.poll.invalidate()
        g.monitors.forEach(NSEvent.removeMonitor)
        g.catcher.orderOut(nil)
        model.guided = false
        released(dragged: confirm)
        if !confirm { popover.performClose(nil) }
    }

    /// Press on the icon: follow the pointer at 60 Hz until the button comes up. Polling needs no drag events,
    /// so it works with any mouse, trackpad or input tool, and runs only while the button is held.
    @objc private func pressed() {
        if NSApp.currentEvent?.type == .rightMouseDown { return togglePopover() }
        let start = NSEvent.mouseLocation
        var dragged = false
        model.dragMinutes = 0
        press?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                let bar = MenuBar.shared, p = NSEvent.mouseLocation
                if dragged || hypot(p.x - start.x, p.y - start.y) > 12 {
                    dragged = true
                    bar.showPreview(to: p, from: start)
                }
                if NSEvent.pressedMouseButtons & 1 == 0 {
                    bar.press?.invalidate()
                    bar.press = nil
                    bar.released(dragged: dragged)
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        press = t
    }

    private func released(dragged: Bool) {
        hidePreview()
        if !dragged { return togglePopover() }
        guard model.dragMinutes > 0 else { return } // dragged back up: cancel
        model.pendingMinutes = model.dragMinutes
        showPopover(at: lineEnd) // at the end of the line: works even when a menu bar manager hides the icon
    }

    /// 4 pt per minute of distance, snapped to 5 (25 min ≈ 100 pt). Under 24 pt cancels.
    static func minutes(forDrag length: CGFloat) -> Int {
        length < 24 ? 0 : min(120, max(5, (Int(length / 4) + 2) / 5 * 5))
    }

    /// The line runs from the icon to the pointer in any direction; its length sets the time.
    /// Back in the menu bar strip (or right by the icon) means cancel.
    private func showPreview(to cursor: NSPoint, from start: NSPoint) {
        guard let b = item?.button, let win = b.window, let screen = win.screen ?? NSScreen.main else { return }
        let icon = win.convertToScreen(b.convert(b.bounds, to: nil))
        let m = cursor.y >= icon.minY ? 0 : Self.minutes(forDrag: hypot(cursor.x - start.x, cursor.y - start.y))
        if m != model.dragMinutes {
            model.dragMinutes = m
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        let panel = preview ?? makePreview()
        let f = screen.frame
        if panel.frame != f { panel.setFrame(f, display: false) }
        model.from = CGPoint(x: icon.midX - f.minX, y: f.maxY - icon.minY)
        model.to = CGPoint(x: cursor.x - f.minX, y: f.maxY - cursor.y)
        lineEnd = cursor
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
        }
    }

    private func hidePreview() {
        guard let p = preview, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
    }

    private func makePreview() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.appearance = Self.appearance
        p.contentView = NSHostingView(rootView: MenuBarDragPreview(model: model))
        preview = p
        return p
    }

    private func togglePopover() { popover.isShown ? popover.performClose(nil) : showPopover() }

    private func showPopover(at point: NSPoint? = nil) {
        guard let b = item?.button else { return }
        popover.appearance = Self.appearance
        if let point {
            let w = anchor ?? NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.level = .statusBar
            anchor = w
            w.setFrame(NSRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2), display: false)
            w.orderFrontRegardless()
            popover.show(relativeTo: w.contentView?.bounds ?? .zero, of: w.contentView ?? b, preferredEdge: .minY)
        } else {
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        }
        NSApp.activate()
        popover.contentViewController?.view.window?.makeKey()
    }
}

private final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true } // so Return and Esc reach us in guided mode
}

/// The line pulled from the icon to the pointer, with the length it will set.
struct MenuBarDragPreview: View {
    let model: MenuBar.Model
    @AppStorage(Pref.theme, store: .shared) private var theme = 0

    var body: some View {
        let tint = (Theme(rawValue: theme) ?? .ember).tint, on = model.dragMinutes > 0
        ZStack {
            Path { p in p.move(to: model.from); p.addLine(to: model.to) }
                .stroke(tint.opacity(on ? 1 : 0.4), style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: on ? [] : [4, 6]))
            Circle().fill(tint).frame(width: 12, height: 12).position(model.to)
            VStack(spacing: 6) {
                Text(on ? "\(model.dragMinutes) min" : model.guided ? String(localized: "Click to Cancel") : String(localized: "Release to Cancel"))
                    .font(.system(.callout, design: .rounded, weight: .semibold)).monospacedDigit()
                    .contentTransition(.numericText())
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .glassEffect(.regular, in: .capsule)
                if model.guided {
                    Text(on ? "Click to set · Esc to cancel" : "Move away from the icon to choose a length")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .glassEffect(.regular, in: .rect(cornerRadius: 10))
                }
            }
            .fixedSize()
            .position(x: model.to.x, y: model.to.y + (model.guided ? 52 : 28))
        }
        .animation(.snappy(duration: 0.15), value: model.dragMinutes)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Click the icon: the dial, the time and the main actions. After a drag: what are you focusing on?
struct MenuBarPanel: View {
    let model: MenuBar.Model
    let close: () -> Void
    private let engine = TimerEngine.shared
    @AppStorage(Pref.theme, store: .shared) private var theme = 0
    @State private var label = ""
    @FocusState private var typing: Bool

    private var tint: Color { (Theme(rawValue: theme) ?? .ember).tint }

    var body: some View {
        Group {
            if let m = model.pendingMinutes { ask(m) } else { status }
        }
        .padding(16)
        .frame(width: 260)
        .animation(.snappy(duration: 0.25), value: model.pendingMinutes)
        .animation(.snappy(duration: 0.3), value: engine.snap.status)
        .tint(tint)
        .fontDesign(.rounded)
    }

    private func ask(_ m: Int) -> some View {
        VStack(spacing: 12) {
            Text("Focus for \(m) min").font(.title3.weight(.semibold))
            TextField(engine.snap.label.isEmpty ? String(localized: "What are you focusing on?") : engine.snap.label, text: $label)
                .textFieldStyle(.roundedBorder)
                .focused($typing)
                .onSubmit { start(m) }
            HStack {
                Button("Cancel") { model.pendingMinutes = nil; close() }
                Spacer()
                Button("Start Focus") { start(m) }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .task {
            label = "" // the last label shows as the placeholder; Return keeps it
            try? await Task.sleep(for: .milliseconds(80)) // the popover must be key before the field can take focus
            typing = true
        }
    }

    private func start(_ m: Int) {
        let typed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { engine.setLabel(typed) }
        model.pendingMinutes = nil
        close()
        Task { await engine.start(.focus, seconds: TimeInterval(m * 60)) }
    }

    private var status: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            let s = engine.snap, left = s.remaining(at: ctx.date)
            VStack(spacing: 12) {
                ZStack {
                    DialFace(fraction: s.status == .idle ? DialFace.idleFraction(s.planned) : s.status == .finished ? 1 : left / max(s.planned, 1),
                             tint: tint, knobScale: s.status == .idle ? 1.85 : 1)
                    VStack(spacing: 2) {
                        Text((s.status == .idle ? s.planned : left).clock)
                            .font(.system(size: 30, weight: .light)).monospacedDigit()
                        Text(caption(s)).font(.caption2.weight(.semibold)).fontWidth(.expanded).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 150, height: 150)
                if !s.label.isEmpty { Text(s.label).font(.headline).lineLimit(1) }
                controls(s)
                HStack {
                    Button("Open Pomly") { openApp() }
                    Spacer()
                    Button("Quit") { NSApp.terminate(nil) }
                }
                .buttonStyle(.plain).font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Set by Dragging", systemImage: "arrow.down.to.line") { MenuBar.shared.startGuided() }
                    Button("Mini Timer", systemImage: "pip") { close(); MiniTimer.toggle() }
                }
                .glassCapsule(neutral: true)
                .controlSize(.regular)
                    .help("Pull a line down from the menu bar to pick a length, then click.")
                Text("Or press and drag from the menu bar icon. ⌃⌥P start or pause · ⌃⌥D drag")
                    .font(.caption2).foregroundStyle(.tertiary).multilineTextAlignment(.center)
            }
        }
    }

    private func caption(_ s: TimerSnapshot) -> LocalizedStringKey {
        switch s.status {
        case .paused: "PAUSED"
        case .finished: "DONE"
        default: s.phase == .focus ? "FOCUS" : "BREAK"
        }
    }

    @ViewBuilder private func controls(_ s: TimerSnapshot) -> some View {
        HStack(spacing: 10) {
            switch s.status {
            case .idle, .finished:
                Button("Start Focus", systemImage: "play.fill") { Task { await engine.start(.focus) } }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
                Button("Break", systemImage: "cup.and.saucer.fill") { Task { await engine.start(.rest) } }
                    .glassCapsule(neutral: true)
            case .running:
                Button("End", systemImage: "xmark") { engine.stop() }.glassCapsule(neutral: true)
                Button("Pause", systemImage: "pause.fill") { engine.pause() }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            case .paused:
                Button("End", systemImage: "xmark") { engine.stop() }.glassCapsule(neutral: true)
                Button("Resume", systemImage: "play.fill") { Task { await engine.resume() } }
                    .buttonStyle(.glassProminent).keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
    }

    private func openApp() {
        close()
        NSApp.activate()
        if let w = NSApp.windows.first(where: { $0.title == "Pomly" }) { w.makeKeyAndOrderFront(nil) }
        else { NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: .init()) } // reopen makes a new window
    }
}
#endif

#if os(macOS)
/// Timer menu in the Mac menu bar: the main actions by keyboard.
struct PomlyCommands: Commands {
    var body: some Commands {
        CommandMenu("Timer") {
            Button("Start Focus") { Task { await TimerEngine.shared.start(.focus) } }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Pause or Resume") {
                let e = TimerEngine.shared
                if e.snap.status == .running { e.pause() } else { Task { await e.resume() } }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            Button("End Session") { TimerEngine.shared.stop() }
            Divider()
            Button("Set Focus by Dragging") { MenuBar.shared.startGuided() }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Mini Timer") { MiniTimer.toggle() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
        }
    }
}
#endif

#if os(macOS)
/// Global shortcuts from any app (Carbon hot keys: no Accessibility permission needed).
/// ⌃⌥P start, pause or resume · ⌃⌥D set a focus by dragging.
enum HotKeys {
    private static var refs: [EventHotKeyRef?] = []

    static func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeys.fire(id.id) } }
            return noErr
        }, 1, &spec, nil, nil)
        for (id, key) in [(UInt32(1), kVK_ANSI_P), (2, kVK_ANSI_D)] {
            var ref: EventHotKeyRef?
            RegisterEventHotKey(UInt32(key), UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x504F_4D59, id: id),
                                GetApplicationEventTarget(), 0, &ref)
            refs.append(ref)
        }
    }

    @MainActor static func fire(_ id: UInt32) {
        let e = TimerEngine.shared
        switch (id, e.snap.status) {
        case (1, .running): e.pause()
        case (1, .paused): Task { await e.resume() }
        case (1, _): Task { await e.start(.focus) }
        default: MenuBar.shared.startGuided()
        }
    }
}
#endif

#if os(macOS)
/// Picture-in-picture timer: the signature dial floating above everything, draggable, on every Space.
@MainActor enum MiniTimer {
    private static var panel: NSPanel?

    static func toggle() { panel?.isVisible == true ? hide() : show() }
    static func refreshAppearance() { panel?.appearance = MenuBar.appearance }

    static func show() {
        let p = panel ?? make()
        p.appearance = MenuBar.appearance
        UserDefaults.standard.set(true, forKey: "miniTimer")
        guard !p.isVisible else { return }
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.2; p.animator().alphaValue = 1 }
    }

    static func hide() {
        UserDefaults.standard.set(false, forKey: "miniTimer")
        guard let p = panel, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
    }

    private static func make() -> NSPanel {
        let side: CGFloat = 136
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: side, height: side), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true
        // Borderless windows can be dragged off-screen; pull it back so it's always reachable.
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { _ in
            MainActor.assumeIsolated {
                guard let v = (p.screen ?? NSScreen.main)?.visibleFrame else { return }
                var f = p.frame
                f.origin.x = min(max(f.minX, v.minX - f.width / 3), v.maxX - f.width * 2 / 3)
                f.origin.y = min(max(f.minY, v.minY), v.maxY - f.height)
                if f.origin != p.frame.origin { p.setFrameOrigin(f.origin) }
            }
        }
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.contentView = NSHostingView(rootView: MiniTimerView())
        if !p.setFrameUsingName("PomlyMini"), let v = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: v.maxX - side - 24, y: v.maxY - side - 24))
        }
        p.setFrameAutosaveName("PomlyMini") // remembers where you left it
        panel = p
        return p
    }
}

struct MiniTimerView: View {
    private let engine = TimerEngine.shared
    @AppStorage(Pref.theme, store: .shared) private var theme = 0
    @AppStorage(Pref.appearance, store: .shared) private var look = 0
    @State private var hover = false
    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let s = engine.snap, tint = (Theme(rawValue: theme) ?? .ember).tint
        // Redraws once a second only while running; paused or idle it costs nothing.
        TimelineView(.animation(minimumInterval: 1, paused: s.status != .running)) { ctx in
            let left = s.remaining(at: ctx.date)
            ZStack {
                DialFace(fraction: s.status == .idle ? DialFace.idleFraction(s.planned) : s.status == .finished ? 1 : left / max(s.planned, 1),
                         tint: tint, showsKnob: false)
                    .padding(6)
                VStack(spacing: 2) {
                    Text((s.status == .idle ? s.planned : left).clock)
                        .font(.system(size: 24, weight: .light, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText(countsDown: true))
                    if hover {
                        HStack(spacing: 6) {
                            control(s.status == .running ? "pause.fill" : "play.fill") {
                                switch s.status {
                                case .running: engine.pause()
                                case .paused: Task { await engine.resume() }
                                default: Task { await engine.start(.focus) }
                                }
                            }
                            control("xmark") { MiniTimer.hide() }
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                    } else if s.status == .paused {
                        Text("PAUSED").font(.system(size: 8, weight: .semibold)).fontWidth(.expanded).foregroundStyle(.secondary)
                    }
                }
            }
            .animation(.snappy(duration: 0.25), value: Int(left))
        }
        .frame(width: 124, height: 124)
        .background(Circle().fill(Color(light: 0xFBF6EF, dark: 0x1C130E).opacity(0.82))) // the app's face, for contrast
        .glassEffect(.regular, in: .circle)
        .scaleEffect(shown || reduceMotion ? 1 : 0.6)
        .frame(width: 136, height: 136)
        .contentShape(.circle)
        .gesture(WindowDragGesture()) // grab the dial anywhere to move it
        .allowsWindowActivationEvents(true)
        .onAppear { withAnimation(.spring(duration: 0.35, bounce: 0.3)) { shown = true } }
        .animation(.snappy(duration: 0.2), value: hover)
        .onHover { hover = $0 }
        .onTapGesture(count: 2) { NSApp.activate(); NSApp.windows.first { $0.title == "Pomly" }?.makeKeyAndOrderFront(nil) }
        .contextMenu {
            if s.status == .running { Button("Pause") { engine.pause() } }
            if s.status == .paused { Button("Resume") { Task { await engine.resume() } } }
            if s.isActive { Button("End Session") { engine.stop() } } else { Button("Start Focus") { Task { await engine.start(.focus) } } }
            Divider()
            Button("Hide Mini Timer") { MiniTimer.hide() }
        }
        .tint(tint)
        .onChange(of: look) { MiniTimer.refreshAppearance() }
    }

    private func control(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.system(size: 10, weight: .bold)).frame(width: 22, height: 22) }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: .circle)
    }
}
#endif
