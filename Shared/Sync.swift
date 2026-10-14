import SwiftUI
import SwiftData

/// Pairing-code sync over Firebase REST, no SDK. Each device signs in anonymously; paired devices share one
/// "space" holding the timer state and session history, and one streaming GET delivers every change instantly.
@MainActor @Observable
final class Sync {
    static let shared = Sync()
    private static let key = "AIzaSyCBlZMzIfz72TEyqZg-YvqGgIVimYkNRUU" // public by design; the database rules do the guarding
    private static let db = "https://pomly-43c42-default-rtdb.firebaseio.com"
    private static let device = UUID().uuidString // per launch, to drop our own echoes

    private(set) var space = UserDefaults.shared.string(forKey: "syncSpace") {
        didSet { UserDefaults.shared.set(space, forKey: "syncSpace") }
    }
    private(set) var members: Set<String> = []
    var isPaired: Bool { space != nil && members.count > 1 }

    // Plumbing, not UI state: views never need to re-render for these.
    @ObservationIgnored private var uid = UserDefaults.shared.string(forKey: "syncUID")
    @ObservationIgnored private var idToken: String?
    @ObservationIgnored private var expiry = Date.distantPast
    @ObservationIgnored private var code: String?
    @ObservationIgnored private var listener: Task<Void, Never>?
    /// Last byte from the stream. Firebase sends a keep-alive every 30 s, so a quiet stream is a dead one.
    @ObservationIgnored private var heard = Date.distantPast
    @ObservationIgnored private var outgoing: Task<Void, Never>?
    @ObservationIgnored private var lastState: TimerSnapshot?
    /// When the shared state last changed, here or elsewhere. A newer local change (e.g. made offline) beats an older remote one.
    @ObservationIgnored private var lastAt = UserDefaults.shared.double(forKey: "syncAt") {
        didSet { UserDefaults.shared.set(lastAt, forKey: "syncAt") }
    }

    private init() {}

    // MARK: Pairing

    /// A fresh code another device can enter to join this one. Valid for 10 minutes.
    func makeCode() async throws -> String {
        let me = try await signIn()
        if let code { _ = try? await call("codes/\(code)", "DELETE") }
        let target = space ?? Self.random(20)
        for _ in 0..<5 {
            let c = Self.random(6)
            let exp = (Date.now.timeIntervalSince1970 + 600) * 1000
            guard (try? await call("codes/\(c)", "PUT", Code(owner: me, space: target, exp: exp))) != nil else { continue } // taken
            try await call("spaces/\(target)/members/\(me)", "PUT", c)
            code = c
            if space != target {
                space = target
                await connect()
            }
            return c
        }
        throw URLError(.cannotCreateFile)
    }

    func join(_ entered: String) async throws {
        let me = try await signIn()
        guard let c = try? JSONDecoder().decode(Code.self, from: try await call("codes/\(entered)")),
              c.exp > Date.now.timeIntervalSince1970 * 1000 else { throw URLError(.fileDoesNotExist) }
        guard c.space != space else { return }
        await leave()
        try await call("spaces/\(c.space)/members/\(me)", "PUT", entered)
        lastAt = 0 // the joined devices' timer wins
        space = c.space
        await connect()
    }

    func leave() async {
        guard let old = space else { return }
        listener?.cancel()
        space = nil
        members = []
        if let code { _ = try? await call("codes/\(code)", "DELETE") }
        code = nil
        _ = try? await call("spaces/\(old)/members/\(uid ?? "-")", "DELETE")
    }

    /// Foreground: reopen the stream if it went quiet (its first event carries everything missed meanwhile).
    /// A live one stays, so window focus changes and wrist raises don't reconnect.
    func resume() {
        guard space != nil, heard < .now - 45 else { return }
        listen()
    }

    // MARK: Outgoing

    /// Every local timer change. Debounced, so dragging the dial sends only where it settles.
    func push(_ s: TimerSnapshot) {
        guard space != nil else { return }
        var s = s
        s.alarmID = nil // device-local
        guard s != lastState else { return }
        lastState = s
        lastAt = Date.now.timeIntervalSince1970
        outgoing?.cancel()
        outgoing = Task {
            try? await Task.sleep(for: .milliseconds(150))
            if !Task.isCancelled { send(s) }
        }
    }

    func add(_ session: Session) {
        guard let space else { return }
        Task { _ = try? await call("spaces/\(space)/sessions/\(session.key)", "PUT", Item(session)) }
    }

    func remove(_ sessions: [Session]) {
        guard let space, !sessions.isEmpty else { return }
        let gone = Dictionary(sessions.map { ($0.key, Item?.none) }, uniquingKeysWith: { a, _ in a })
        Task { _ = try? await call("spaces/\(space)/sessions", "PATCH", gone) }
    }

    func removeAll() {
        guard let space else { return }
        Task { _ = try? await call("spaces/\(space)/sessions", "DELETE") }
    }

    private func send(_ s: TimerSnapshot) {
        guard let space else { return }
        let wire = Wire(s: s, by: Self.device, at: lastAt)
        Task { _ = try? await call("spaces/\(space)/state", "PUT", wire) }
    }

    /// Uploads this device's history, then listens.
    private func connect() async {
        guard let space else { return }
        if let d = try? await call("spaces/\(space)/members"), let m = try? JSONDecoder().decode([String: String].self, from: d) {
            members = Set(m.keys)
        }
        let all = (try? Store.container.mainContext.fetch(FetchDescriptor<Session>())) ?? []
        if !all.isEmpty {
            _ = try? await call("spaces/\(space)/sessions", "PATCH", Dictionary(all.map { ($0.key, Item($0)) }, uniquingKeysWith: { a, _ in a }))
        }
        listen()
    }

    // MARK: Incoming

    private func listen() {
        listener?.cancel()
        guard let space else { return }
        heard = .now // a fresh stream gets the benefit of the doubt; it retries by itself if it fails
        listener = Task {
            while !Task.isCancelled, self.space == space {
                do {
                    var req = URLRequest(url: try await url("spaces/\(space)"))
                    req.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    let (bytes, res) = try await URLSession.shared.bytes(for: req)
                    if (res as? HTTPURLResponse)?.statusCode == 401 { return lost() }
                    var event = ""
                    for try await line in bytes.lines {
                        heard = .now
                        if line.hasPrefix("event:") { event = line.dropFirst(6).trimmingCharacters(in: .whitespaces); continue }
                        guard line.hasPrefix("data:") else { continue }
                        switch event {
                        case "put", "patch": apply(Data(line.dropFirst(5).utf8))
                        case "auth_revoked": expiry = .distantPast // the stream closes; reconnect with a fresh token
                        case "cancel": return lost()
                        default: break
                        }
                    }
                } catch {}
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// The rules no longer let us read the space (removed from it).
    private func lost() {
        space = nil
        members = []
    }

    private func apply(_ data: Data) {
        guard let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = msg["path"] as? String else { return }
        let value = msg["data"].flatMap { $0 is NSNull ? nil : $0 }
        let p = path.split(separator: "/").map(String.init)
        switch p.first {
        case nil:
            let root = value as? [String: Any] ?? [:]
            members = Set((root["members"] as? [String: Any] ?? [:]).keys)
            merge(root["sessions"] as? [String: Any] ?? [:])
            adopt(root["state"])
        case "state":
            adopt(value)
        case "members":
            if p.count > 1 { if value == nil { members.remove(p[1]) } else { members.insert(p[1]) } }
            else { members = Set((value as? [String: Any] ?? [:]).keys) }
        case "sessions":
            if p.count > 1 { merge([p[1]: value ?? NSNull()]) }
            else if let v = value as? [String: Any] { merge(v) }
            else { clearHistory() }
        default: break
        }
    }

    private func adopt(_ value: Any?) {
        guard let value, let d = try? JSONSerialization.data(withJSONObject: value),
              let w = try? JSONDecoder().decode(Wire.self, from: d) else { return send(TimerEngine.shared.snap) } // empty space: seed it
        guard w.by != Self.device, w.at >= lastAt else {
            if w.at < lastAt { send(TimerEngine.shared.snap) } // ours is newer
            return
        }
        lastAt = w.at
        lastState = w.s
        TimerEngine.shared.adoptRemote(w.s)
    }

    private func merge(_ items: [String: Any]) {
        guard !items.isEmpty else { return }
        let ctx = Store.container.mainContext
        let local = Dictionary(((try? ctx.fetch(FetchDescriptor<Session>())) ?? []).map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        var changed = false
        for (k, v) in items {
            if v is NSNull {
                if let s = local[k] { ctx.delete(s); changed = true }
            } else if local[k] == nil, let d = try? JSONSerialization.data(withJSONObject: v),
                      let item = try? JSONDecoder().decode(Item.self, from: d) {
                ctx.insert(item.session)
                changed = true
            }
        }
        guard changed else { return }
        try? ctx.save()
        TimerEngine.shared.historyChanged()
    }

    private func clearHistory() {
        let ctx = Store.container.mainContext
        try? ctx.delete(model: Session.self)
        try? ctx.save()
        TimerEngine.shared.historyChanged()
    }

    // MARK: REST

    private func signIn() async throws -> String {
        _ = try await token()
        guard let uid else { throw URLError(.userAuthenticationRequired) }
        return uid
    }

    private func token() async throws -> String {
        if let idToken, expiry > .now { return idToken }
        let refresh = UserDefaults.shared.string(forKey: "syncRefresh")
        var req = URLRequest(url: URL(string: refresh == nil
            ? "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=\(Self.key)"
            : "https://securetoken.googleapis.com/v1/token?key=\(Self.key)")!)
        req.httpMethod = "POST"
        if let refresh {
            req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data("grant_type=refresh_token&refresh_token=\(refresh)".utf8)
        } else {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = Data(#"{"returnSecureToken":true}"#.utf8)
        }
        let (data, res) = try await URLSession.shared.data(for: req)
        let j = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        guard let t = (j["idToken"] ?? j["id_token"]) as? String, let u = (j["localId"] ?? j["user_id"]) as? String,
              let r = (j["refreshToken"] ?? j["refresh_token"]) as? String else {
            // Rejected refresh token (account gone): start over with a new anonymous account next time.
            if (res as? HTTPURLResponse)?.statusCode == 400 { UserDefaults.shared.removeObject(forKey: "syncRefresh") }
            throw URLError(.userAuthenticationRequired)
        }
        let life = Double((j["expiresIn"] ?? j["expires_in"]) as? String ?? "") ?? 3600
        idToken = t
        expiry = .now + life - 120
        uid = u
        UserDefaults.shared.set(u, forKey: "syncUID")
        UserDefaults.shared.set(r, forKey: "syncRefresh")
        return t
    }

    private func url(_ path: String) async throws -> URL {
        URL(string: "\(Self.db)/\(path).json?auth=\(try await token())")!
    }

    @discardableResult
    private func call(_ path: String, _ method: String = "GET", _ body: (any Encodable)? = nil) async throws -> Data {
        var req = URLRequest(url: try await url(path))
        req.httpMethod = method
        if let body { req.httpBody = try JSONEncoder().encode(body) }
        let (data, res) = try await URLSession.shared.data(for: req)
        guard (res as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }

    private static func random(_ n: Int) -> String {
        String((0..<n).map { _ in "ABCDEFGHJKLMNPQRSTUVWXYZ23456789".randomElement()! }) // no 0/O or 1/I mix-ups
    }

    private struct Code: Codable { var owner: String; var space: String; var exp: Double }
    private struct Wire: Codable { var s: TimerSnapshot; var by: String; var at: Double }
    private struct Item: Codable {
        var start, duration, planned: Double
        var label: String
        var completed: Bool
        init(_ s: Session) {
            start = s.start.timeIntervalSince1970; duration = s.duration; planned = s.planned; label = s.label; completed = s.completed
        }
        var session: Session {
            Session(start: Date(timeIntervalSince1970: start), duration: duration, planned: planned, label: label, completed: completed)
        }
    }
}

extension Session {
    /// Same session, same key on every device: both may log it when it ends.
    var key: String { String(Int64((start.timeIntervalSince1970 * 1000).rounded())) }
}

/// The one sync screen on every platform: show this device's code, or type another device's.
struct SyncView: View {
    @Environment(\.dismiss) private var dismiss
    private let sync = Sync.shared
    @State private var code: String?
    @State private var entry = ""
    @State private var working = false
    @State private var failed: LocalizedStringKey?

    #if os(watchOS)
    private let codeFont = Font.system(.title2, design: .monospaced, weight: .semibold), codeKerning = 2.0
    #else
    private let codeFont = Font.system(size: 44, weight: .semibold, design: .monospaced), codeKerning = 6.0
    #endif

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    VStack(spacing: 8) {
                        Image(systemName: sync.isPaired ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                            .font(.system(size: 34, weight: .medium))
                            .foregroundStyle(.tint)
                            .contentTransition(.symbolEffect(.replace))
                        Text(sync.isPaired ? "Devices Synced" : "Sync Your Devices")
                            .font(.title2.weight(.semibold)).fontDesign(.rounded)
                        Text(sync.isPaired ? "Add another device with this code." : "Enter this code on your other device, or enter its code below.")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(code ?? "POMLY0")
                        .font(codeFont).kerning(codeKerning)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .redacted(reason: code == nil ? .placeholder : [])
                        #if !os(watchOS)
                        .textSelection(.enabled)
                        #endif
                        .accessibilityLabel(code.map { $0.map(String.init).joined(separator: " ") } ?? "")
                    TextField("Enter a Code", text: $entry)
                        .font(.system(.title3, design: .monospaced, weight: .medium))
                        .multilineTextAlignment(.center)
                        .autocorrectionDisabled()
                        .disabled(working)
                        .onChange(of: entry) { _, v in typed(v) }
                        #if !os(watchOS)
                        .textFieldStyle(.plain)
                        .padding(.vertical, 12)
                        .frame(maxWidth: 240)
                        .background(.fill.tertiary, in: .capsule)
                        #endif
                    if working { ProgressView() }
                    if let failed {
                        Text(failed).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                    }
                    if sync.isPaired {
                        Button("Stop Syncing", role: .destructive) { Task { await sync.leave(); dismiss() } }
                    }
                }
                .padding(24)
                .frame(maxWidth: 440)
                .frame(maxWidth: .infinity)
                .animation(.snappy, value: sync.isPaired)
            }
            #if !os(watchOS) // watchOS adds its own close button
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            #endif
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])
        #endif
        .task {
            do { code = try await sync.makeCode() } catch { failed = "Can't reach sync right now. Check your connection." }
        }
        .onDisappear {
            if !sync.isPaired { Task { await sync.leave() } } // nobody joined: don't keep a one-device space open
        }
    }

    private func typed(_ v: String) {
        let clean = String(v.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(6))
        guard clean == v else { return entry = clean }
        guard clean.count == 6, clean != code else { return }
        working = true
        failed = nil
        Task {
            do { try await sync.join(clean); entry = "" } catch { failed = "That code didn't work. Check it, or make a new one." }
            working = false
        }
    }
}
