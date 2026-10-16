import SwiftUI

/// Focus screen, header: opens the room sheet.
struct RoomButton: View {
    @State private var open = false

    var body: some View {
        let inRoom = Room.shared.code != nil
        Button { open = true } label: {
            Image(systemName: inRoom ? "person.2.fill" : "person.2").font(.subheadline).frame(width: 44, height: 44).contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(inRoom ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .glassEffect(.regular.interactive(), in: .circle)
        .accessibilityLabel("Focus Together")
        .sheet(isPresented: $open) { RoomView() }
    }
}

/// Focus screen, under the title: who's here, and one tap to leave.
struct RoomLine: View {
    private let room = Room.shared

    var body: some View {
        if room.code != nil {
            TimelineView(.periodic(from: .now, by: 15)) { t in
                let n = max(1, Room.present(room.members, at: t.date))
                let s = TimerEngine.shared.snap
                let text: LocalizedStringKey = s.phase == .focus && s.status == .running
                    ? "^[\(n) person](inflect: true) focusing" : "^[\(n) person](inflect: true) here"
                HStack(spacing: 10) {
                    Label(text, systemImage: "person.2.fill").contentTransition(.numericText())
                    Button("Leave") { room.leave() }.buttonStyle(.borderless).frame(minHeight: 44)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
        }
    }
}

/// Start a room, join one by code, or invite to the current one.
struct RoomView: View {
    @Environment(\.dismiss) private var dismiss
    private let room = Room.shared
    @State private var entry = ""
    @State private var working = false
    @State private var failed: LocalizedStringKey?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 8) {
                        Image(systemName: "person.2.fill").font(.system(size: 34, weight: .medium)).foregroundStyle(.tint)
                        Text("Focus Together").font(.title2.weight(.semibold)).fontDesign(.rounded)
                        Text(room.code == nil ? "Share one timer with friends. When anyone starts or ends a session, everyone does." : "Invite friends with the link or this code.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let code = room.code {
                        Text(code)
                            .font(.system(size: 40, weight: .semibold, design: .monospaced)).kerning(4)
                            .lineLimit(1).minimumScaleFactor(0.6)
                            .textSelection(.enabled)
                            .accessibilityLabel(code.map(String.init).joined(separator: " "))
                        ShareLink(item: Room.link(code), message: Text("Focus with me in Pomly")) {
                            Label("Invite", systemImage: "square.and.arrow.up")
                        }
                        .glassCapsule()
                        Button("Leave Room", role: .destructive) { room.leave() }
                    } else {
                        Button("Start a Room") { run { try await room.create() } }
                            .glassCapsule()
                            .disabled(working)
                        TextField("Enter a Code", text: $entry)
                            .font(.system(.title3, design: .monospaced, weight: .medium))
                            .multilineTextAlignment(.center)
                            .autocorrectionDisabled()
                            .disabled(working)
                            .onChange(of: entry) { _, v in typed(v) }
                            .textFieldStyle(.plain)
                            .padding(.vertical, 12)
                            .frame(maxWidth: 260)
                            .background(.fill.tertiary, in: .capsule)
                    }
                    if working { ProgressView() }
                    if let failed {
                        Text(failed).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                    }
                }
                .padding(24)
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
                .animation(.snappy, value: room.code)
            }
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
    }

    private func typed(_ v: String) {
        let clean = String(v.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(8))
        guard clean == v else { return entry = clean }
        guard clean.count == 8 else { return }
        run { try await room.join(clean); entry = "" }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        working = true
        failed = nil
        Task {
            do { try await work() } catch { failed = "That didn't work. Check the code and your connection." }
            working = false
        }
    }
}
