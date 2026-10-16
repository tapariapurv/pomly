import SwiftUI
import SwiftData
import EventKit

/// One EventKit store for Reminders and Calendar.
@MainActor let eventStore = EKEventStore()

/// A short "what are you doing in this block?" list. The picked task becomes the session label.
struct FocusTask: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var reminderID: String?
}

@MainActor @Observable
final class Tasks {
    static let shared = Tasks()
    var editing = false
    private(set) var items: [FocusTask] = {
        guard let d = UserDefaults.shared.data(forKey: "tasks") else { return [] }
        return (try? JSONDecoder().decode([FocusTask].self, from: d)) ?? []
    }() {
        didSet { UserDefaults.shared.set(try? JSONEncoder().encode(items), forKey: "tasks") }
    }

    func add(_ title: String, reminderID: String? = nil) {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !items.contains(where: { $0.title == t }) else { return }
        items.append(FocusTask(title: t, reminderID: reminderID))
    }

    func delete(at offsets: IndexSet) { items.remove(atOffsets: offsets) }
    func delete(_ task: FocusTask) { items.removeAll { $0 == task } }
    func task(named label: String) -> FocusTask? { label.isEmpty ? nil : items.first { $0.title == label } }

    /// Done: off the list, and completed in Reminders if it came from there.
    func complete(_ task: FocusTask) {
        delete(task)
        if let id = task.reminderID, let r = eventStore.calendarItem(withIdentifier: id) as? EKReminder {
            r.isCompleted = true
            try? eventStore.save(r, commit: true)
        }
    }

    /// Opt-in: asks for Reminders access on first tap, then brings in up to 5 open reminders (soonest due first).
    func importReminders() async {
        guard (try? await eventStore.requestFullAccessToReminders()) == true else { return }
        let predicate = eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        let found: [(String, String, Date)] = await withCheckedContinuation { cont in
            eventStore.fetchReminders(matching: predicate) { list in
                cont.resume(returning: (list ?? []).map { ($0.title ?? "", $0.calendarItemIdentifier, $0.dueDateComponents?.date ?? .distantFuture) })
            }
        }
        for (title, id, _) in found.sorted(by: { $0.2 < $1.2 }).prefix(5) { add(title, reminderID: id) }
    }
}

/// Tasks at the top of the label menu.
struct TaskMenuSection: View {
    let tasks = Tasks.shared
    var body: some View {
        Section("What are you doing in this block?") {
            ForEach(tasks.items) { t in
                Button(t.title, systemImage: t.reminderID == nil ? "circle" : "checklist") { TimerEngine.shared.setLabel(t.title) }
            }
            Button("Tasks…", systemImage: "list.bullet") { tasks.editing = true }
        }
    }
}

struct TaskSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    private let tasks = Tasks.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Add a Task", text: $draft).onSubmit { tasks.add(draft); draft = "" }
                }
                Section {
                    ForEach(tasks.items) { t in
                        Button {
                            TimerEngine.shared.setLabel(t.title)
                            dismiss()
                        } label: {
                            Label(t.title, systemImage: TimerEngine.shared.snap.label == t.title ? "largecircle.fill.circle" : "circle")
                        }
                        .foregroundStyle(.primary)
                        .contextMenu { Button("Delete", systemImage: "trash", role: .destructive) { tasks.delete(t) } }
                    }
                    .onDelete { tasks.delete(at: $0) }
                } footer: {
                    Text("Pick one for this block. At the end, mark it Done or carry it over.")
                }
            }
            .pomlyBackground()
            .navigationTitle("Tasks")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Import from Reminders", systemImage: "square.and.arrow.down") { Task { await tasks.importReminders() } }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 420)
        #endif
    }
}

extension View {
    /// Presents the task list when the label menu asks for it.
    func taskSheet() -> some View { modifier(TaskSheetModifier()) }
}

private struct TaskSheetModifier: ViewModifier {
    @Bindable private var tasks = Tasks.shared
    func body(content: Content) -> some View { content.sheet(isPresented: $tasks.editing) { TaskSheet() } }
}

// MARK: - End-of-session ritual

enum Ritual {
    static let tips: [LocalizedStringResource] = ["Stand up and stretch.", "Grab a glass of water.", "Look at something far away.", "Roll your shoulders and breathe."]
    static func tip(_ n: Int) -> String { String(localized: tips[abs(n) % tips.count]) }

    static func rate(sessionStart: Date?, feel: Int, in context: ModelContext) {
        guard let start = sessionStart,
              let s = try? context.fetch(FetchDescriptor<Session>(predicate: #Predicate { $0.start == start })).first else { return }
        s.feel = feel
        try? context.save()
    }
}

/// Under "Session Logged": Done / Carry Over for the task and an optional 1–5 feel. All skippable; nothing blocks the next action.
struct WrapUp: View {
    let snap: TimerSnapshot
    let tint: Color
    @AppStorage(Pref.haptics, store: .shared) private var haptics = true
    @Environment(\.modelContext) private var context
    @State private var feel = 0
    @State private var decided = false

    var body: some View {
        VStack(spacing: 8) {
            if !decided, let task = Tasks.shared.task(named: snap.label) {
                HStack(spacing: 10) {
                    Button("Done", systemImage: "checkmark") {
                        Tasks.shared.complete(task)
                        TimerEngine.shared.setLabel("")
                        decided = true
                    }
                    .tint(tint)
                    Button("Carry Over", systemImage: "arrow.uturn.forward") { decided = true }
                }
                .font(.subheadline.weight(.semibold))
                .glassCapsule(neutral: true)
            }
            ViewThatFits {
                HStack(spacing: 4) { prompt; dots }
                VStack(spacing: 2) { prompt; dots }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: feel) { _, _ in haptics }
    }

    private var prompt: some View {
        Text("How did it feel?").font(.subheadline).fontDesign(.rounded).foregroundStyle(.secondary)
    }

    private var dots: some View {
        HStack(spacing: 0) {
            ForEach(1...5, id: \.self) { n in
                Button {
                    feel = n
                    Ritual.rate(sessionStart: snap.startedAt, feel: n, in: context)
                } label: {
                    Image(systemName: n <= feel ? "circle.fill" : "circle")
                        .font(.body).foregroundStyle(n <= feel ? tint : .secondary)
                        .frame(width: 44, height: 44).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(n) of 5")
                .accessibilityAddTraits(feel == n ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("How did it feel?")
    }
}
