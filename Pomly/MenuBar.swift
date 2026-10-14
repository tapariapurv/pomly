#if os(macOS)
import SwiftUI
import AppKit

final class PomlyAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { MenuBar.shared.install() }
}

/// Menu bar: a compact live timer. Click for the panel; drag down from the icon to pull out a focus length.
/// Costs nothing while idle: the 1 s ticker runs only while a session runs.
@MainActor final class MenuBar: NSObject, NSPopoverDelegate {
    static let shared = MenuBar()

    @Observable final class Model {
        var dragMinutes = 0
        var pendingMinutes: Int? // set by a drag: ask what we're focusing on, then start
    }

    let model = Model()
    private let engine = TimerEngine.shared
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private var preview: NSPanel?
    private var ticker: Timer?

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
    }

    func popoverDidClose(_ notification: Notification) { model.pendingMinutes = nil }

    // MARK: Status item

    private func observe() {
        withObservationTracking { update(engine.snap) } onChange: { Task { @MainActor in self.observe() } }
    }

    private func update(_ s: TimerSnapshot) {
        ticker?.invalidate()
        ticker = nil
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

    @objc private func pressed() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseDown { return togglePopover() }
        let start = NSEvent.mouseLocation
        var dragged = false
        model.dragMinutes = 0
        // Follow the pointer until the button actually comes up (some input sources send moves, not drags).
        while let e = NSApp.nextEvent(matching: [.leftMouseDragged, .mouseMoved, .leftMouseUp], until: .distantFuture, inMode: .eventTracking, dequeue: true),
              e.type != .leftMouseUp, NSEvent.pressedMouseButtons & 1 == 1 {
            let length = start.y - NSEvent.mouseLocation.y
            if length > 12 || dragged {
                dragged = true
                showPreview(length: max(length, 0), from: start)
            }
        }
        preview?.orderOut(nil)
        if !dragged { return togglePopover() }
        guard model.dragMinutes > 0 else { return } // dragged back up: cancel
        model.pendingMinutes = model.dragMinutes
        showPopover()
    }

    /// 4 pt per minute, snapped to 5 (25 min ≈ 100 pt). Under 24 pt cancels.
    static func minutes(forDrag length: CGFloat) -> Int {
        length < 24 ? 0 : min(120, max(5, (Int(length / 4) + 2) / 5 * 5))
    }

    private func showPreview(length: CGFloat, from start: NSPoint) {
        let m = Self.minutes(forDrag: length)
        if m != model.dragMinutes {
            model.dragMinutes = m
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        guard let b = item?.button, let win = b.window else { return }
        let icon = win.convertToScreen(b.convert(b.bounds, to: nil))
        let panel = preview ?? makePreview()
        let w: CGFloat = 160, cursor = start.y - length
        let h = max(icon.minY - cursor, 0) + 44 // line down to the cursor, then the label
        panel.setFrame(NSRect(x: icon.midX - w / 2, y: icon.minY - h, width: w, height: h), display: true)
        panel.orderFrontRegardless()
    }

    private func makePreview() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.level = .statusBar
        p.contentView = NSHostingView(rootView: MenuBarDragPreview(model: model))
        preview = p
        return p
    }

    private func togglePopover() { popover.isShown ? popover.performClose(nil) : showPopover() }

    private func showPopover() {
        guard let b = item?.button else { return }
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        NSApp.activate()
        popover.contentViewController?.view.window?.makeKey()
    }
}

/// The line pulled down from the icon, with the length it will set.
struct MenuBarDragPreview: View {
    let model: MenuBar.Model
    @AppStorage(Pref.theme, store: .shared) private var theme = 0

    var body: some View {
        let tint = (Theme(rawValue: theme) ?? .ember).tint
        VStack(spacing: 0) {
            Capsule().fill(tint.gradient).frame(width: 3).frame(maxHeight: .infinity)
            Circle().fill(tint).frame(width: 12, height: 12)
            Text(model.dragMinutes > 0 ? "\(model.dragMinutes) min" : String(localized: "Cancel"))
                .font(.system(.callout, design: .rounded, weight: .semibold)).monospacedDigit()
                .contentTransition(.numericText())
                .padding(.horizontal, 10).padding(.vertical, 4)
                .glassEffect(.regular, in: .capsule)
                .padding(.top, 4)
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
        .tint(tint)
        .fontDesign(.rounded)
    }

    private func ask(_ m: Int) -> some View {
        VStack(spacing: 12) {
            Text("Focus for \(m) min").font(.title3.weight(.semibold))
            TextField("What are you focusing on?", text: $label)
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
        .onAppear { label = engine.snap.label; typing = true }
    }

    private func start(_ m: Int) {
        engine.setLabel(label.trimmingCharacters(in: .whitespacesAndNewlines))
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
                Text("Tip: drag down from the menu bar icon to set a time.")
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
