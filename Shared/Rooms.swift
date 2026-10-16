import SwiftUI

/// Shared focus rooms ("body doubling") over the same Firebase REST plumbing as `Sync`.
/// `rooms/$code/members/$uid` holds when that member stops counting as present (ms); `rooms/$code/state` the shared timer.
/// Knowing the 8-character code is the invitation: writing your own member entry is how you join.
@MainActor @Observable
final class Room {
    static let shared = Room()
    private var sync: Sync { .shared }

    private(set) var code = UserDefaults.shared.string(forKey: "room") {
        didSet { UserDefaults.shared.set(code, forKey: "room") }
    }
    /// uid → present until (ms since 1970).
    private(set) var members: [String: Double] = [:]

    @ObservationIgnored private var listener: Task<Void, Never>?
    @ObservationIgnored private var beats: Task<Void, Never>?
    @ObservationIgnored private var heard = Date.distantPast
    @ObservationIgnored private var outgoing: Task<Void, Never>?
    @ObservationIgnored private var lastState: TimerSnapshot?
    @ObservationIgnored private var lastAt = 0.0

    private init() {}

    /// Members whose heartbeat hasn't lapsed. Stale ones drop off without anyone having to clean up.
    nonisolated static func present(_ members: [String: Double], at now: Date) -> Int {
        members.values.filter { $0 > now.timeIntervalSince1970 * 1000 }.count
    }

    static func link(_ code: String, room: Bool = true) -> URL {
        URL(string: "https://tapariapurv.github.io/pomly/join/?\(room ? "room" : "code")=\(code)")!
    }

    /// `pomly://room?code=…` joins a room, `pomly://join?code=…` pairs a device.
    static func open(_ url: URL) {
        guard url.scheme == "pomly",
              let c = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value?.uppercased(),
              (6...8).contains(c.count), c.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return } // it ends up in a database path
        Task {
            switch url.host() {
            case "room": try? await shared.join(c)
            case "join": try? await Sync.shared.join(c)
            default: break
            }
        }
    }

    // MARK: Joining

    func create() async throws {
        try await enter(Sync.random(8), fresh: true)
    }

    func join(_ entered: String) async throws {
        guard entered != code else { return }
        try await enter(entered, fresh: false)
    }

    private func enter(_ c: String, fresh: Bool) async throws {
        let me = try await sync.signIn()
        try await sync.call("rooms/\(c)/members/\(me)", "PUT", until)
        if !fresh {
            // A typo would quietly create an empty room: a real one has a timer or someone in it.
            let room = (try? JSONSerialization.jsonObject(with: try await sync.call("rooms/\(c)"))) as? [String: Any] ?? [:]
            let others = (room["members"] as? [String: Double] ?? [:]).filter { $0.key != me }
            guard room["state"] != nil || !others.isEmpty else {
                _ = try? await sync.call("rooms/\(c)/members/\(me)", "DELETE")
                throw URLError(.fileDoesNotExist)
            }
            lastAt = Self.present(others, at: .now) > 0 ? 0 : Date.now.timeIntervalSince1970 // nobody around: my timer seeds it
        }
        leave()
        code = c
        lastState = nil
        if fresh { lastAt = Date.now.timeIntervalSince1970 }
        listen()
    }

    /// One tap, no confirmation: the timer keeps running here.
    func leave() {
        guard let old = code else { return }
        code = nil
        members = [:]
        listener?.cancel()
        beats?.cancel()
        Task { _ = try? await sync.call("rooms/\(old)/members/\(sync.uid ?? "-")", "DELETE") }
    }

    /// Foreground: reopen a quiet stream. Firebase keeps a live one chatty (keep-alive every 30 s).
    func resume() {
        guard code != nil, heard < .now - 45 else { return }
        listen()
    }

    // MARK: Presence

    /// Present for 90 s after each heartbeat, or until the running session ends (a locked phone still counts).
    private var until: Double {
        let s = TimerEngine.shared.snap
        let end = s.status == .running ? s.endDate ?? .now : .now
        return max(Date.now + 90, end).timeIntervalSince1970 * 1000
    }

    private func beat(_ c: String) async throws {
        let me = try await sync.signIn()
        try await sync.call("rooms/\(c)/members/\(me)", "PUT", until)
    }

    // MARK: Timer

    /// What the room shares: phase and timing. Label and counts stay personal.
    private static func common(_ s: TimerSnapshot) -> TimerSnapshot {
        var s = s
        s.alarmID = nil
        s.label = ""
        s.focusCount = 0
        return s
    }

    func push(_ s: TimerSnapshot) {
        guard let c = code else { return }
        let s = Self.common(s)
        guard s != lastState else { return }
        lastState = s
        lastAt = Date.now.timeIntervalSince1970
        outgoing?.cancel()
        outgoing = Task {
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            send(s)
            try? await beat(c) // a new end date extends presence
        }
    }

    private func send(_ s: TimerSnapshot) {
        guard let c = code else { return }
        let wire = Sync.Wire(s: Self.common(s), by: Sync.device, at: lastAt)
        Task { _ = try? await sync.call("rooms/\(c)/state", "PUT", wire) }
    }

    private func adopt(_ value: Any?) {
        let mine = TimerEngine.shared.snap
        guard let value, let d = try? JSONSerialization.data(withJSONObject: value),
              let w = try? JSONDecoder().decode(Sync.Wire.self, from: d) else { return send(mine) } // empty room: seed it
        guard w.by != Sync.device, w.at >= lastAt else {
            if w.at < lastAt { send(mine) } // ours is newer
            return
        }
        lastAt = w.at
        lastState = Self.common(w.s)
        var s = w.s
        s.label = mine.label
        s.focusCount = mine.focusCount
        TimerEngine.shared.adoptRemote(s)
    }

    // MARK: Stream

    private func listen() {
        listener?.cancel()
        beats?.cancel()
        guard let c = code else { return }
        heard = .now
        beats = Task {
            while !Task.isCancelled, code == c {
                try? await Task.sleep(for: .seconds(30))
                try? await beat(c)
                // Anyone may clear a lapsed entry (the rules check it lapsed); keeps rooms from filling with ghosts.
                for (uid, t) in members where t < Date.now.timeIntervalSince1970 * 1000 && uid != sync.uid {
                    _ = try? await sync.call("rooms/\(c)/members/\(uid)", "DELETE")
                }
            }
        }
        listener = Task {
            while !Task.isCancelled, code == c {
                do {
                    try await beat(c) // re-enter first: a pruned member can't read the room
                    var req = URLRequest(url: try await sync.url("rooms/\(c)"))
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, _) = try await URLSession.shared.bytes(for: req)
                    var event = ""
                    for try await line in bytes.lines {
                        heard = .now
                        if line.hasPrefix("event:") { event = line.dropFirst(6).trimmingCharacters(in: .whitespaces); continue }
                        guard line.hasPrefix("data:"), event == "put" || event == "patch" else { continue }
                        apply(Data(line.dropFirst(5).utf8))
                    }
                } catch {}
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func apply(_ data: Data) {
        guard let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = msg["path"] as? String else { return }
        let value = msg["data"].flatMap { $0 is NSNull ? nil : $0 }
        let p = path.split(separator: "/").map(String.init)
        switch p.first {
        case nil:
            let root = value as? [String: Any] ?? [:]
            members = root["members"] as? [String: Double] ?? [:]
            adopt(root["state"])
        case "members" where p.count > 1: members[p[1]] = value as? Double
        case "members": members = value as? [String: Double] ?? [:]
        case "state": adopt(value)
        default: break
        }
    }
}
