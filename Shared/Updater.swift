import SwiftUI
import StoreKit
#if os(macOS)
import AppKit
#endif

/// Updates for builds outside the App Store, from GitHub Releases (App Store and TestFlight builds update through Apple).
/// Mac direct downloads replace themselves and relaunch between sessions; sideloaded iPhone/iPad builds point to
/// the AltStore source, which installs updates; the Watch app ships inside the iPhone app.
@MainActor @Observable
final class Updater {
    static let shared = Updater()
    static let releases = URL(string: "https://github.com/tapariapurv/pomly/releases/latest")!
    static let altStore = URL(string: "altstore://source?url=https://tapariapurv.github.io/pomly/altstore.json")!
    private static let api = URL(string: "https://api.github.com/repos/tapariapurv/pomly/releases/latest")!

    /// A newer version on GitHub, if there is one.
    private(set) var latest: String?
    private(set) var installing = false
    private(set) var checking = false
    /// Why the last check or install failed, shown under the button.
    private(set) var error: String?
    @ObservationIgnored private var download: URL?
    @ObservationIgnored private var checked = Date.distantPast

    static var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }

    /// Direct Mac download, or an iPhone/iPad install that didn't come from the App Store or TestFlight.
    private(set) var active: Bool = {
        #if os(macOS) && DIRECT
        true
        #else
        false
        #endif
    }()
    #if os(iOS)
    @ObservationIgnored private var resolved = false
    #endif

    static func isNewer(_ a: String, than b: String) -> Bool { a.compare(b, options: .numeric) == .orderedDescending }

    /// At most hourly unless forced (the Check for Updates button). On Mac, an automatic check installs right away
    /// when the app is idle and automatic updates are on; a forced one leaves the choice to the person.
    func check(force: Bool = false) async {
        #if os(iOS)
        if !resolved { // only store installs have a verified App Store transaction
            resolved = true
            if case .verified(let t)? = try? await AppTransaction.shared, t.environment != .xcode { active = false } else { active = true }
        }
        #endif
        guard active, !installing, !checking, force || checked < .now - 3600 else { return }
        checking = true
        defer { checking = false }
        error = nil
        struct Release: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: URL }
            let tag_name: String
            let assets: [Asset]
        }
        guard let (data, response) = try? await URLSession.shared.data(from: Self.api),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let r = try? JSONDecoder().decode(Release.self, from: data) else {
            error = String(localized: "Couldn't reach GitHub. Check your connection and try again.")
            return
        }
        checked = .now
        let v = r.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard Self.isNewer(v, than: Self.current) else { latest = nil; return }
        latest = v
        download = r.assets.first { $0.name == "Pomly-macOS.zip" }?.browser_download_url
        if !force { installIfIdle() }
    }

    /// Called when a check finds something and whenever a session ends.
    func installIfIdle() {
        #if os(macOS)
        guard latest != nil, Pref.bool(Pref.autoUpdate), !TimerEngine.shared.snap.isActive else { return }
        Task { await install() }
        #endif
    }

    #if os(macOS)
    /// Download, unpack, then swap the app after we quit and relaunch it.
    func install() async {
        guard let download, !installing else { return }
        let fm = FileManager.default, app = Bundle.main.bundleURL
        // A read-only spot (a translocated or root-owned app) would fail the swap and relaunch the old app,
        // which would then try again on every launch.
        guard fm.isWritableFile(atPath: app.deletingLastPathComponent().path) else {
            error = String(localized: "Move Pomly to your Applications folder to update it.")
            return
        }
        installing = true
        error = nil
        defer { installing = false }
        let dir = fm.temporaryDirectory.appending(path: "PomlyUpdate-\(UUID().uuidString)")
        let fresh = dir.appending(path: "Pomly.app")
        // ponytail: bundle-id check only; verify the code signature once releases are notarized.
        guard let (zip, response) = try? await URLSession.shared.download(from: download),
              (response as? HTTPURLResponse)?.statusCode == 200,
              (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil,
              await Self.run("/usr/bin/ditto", "-x", "-k", zip.path, dir.path),
              Bundle(url: fresh)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            error = String(localized: "The update couldn't be downloaded. Try again later.")
            return
        }
        // Wait for us to quit, then swap; if the new copy can't move in, put the old one back.
        let swap = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        mv "$2" "$2.old" && { mv "$3" "$2" && rm -rf "$2.old" || mv "$2.old" "$2"; }
        xattr -dr com.apple.quarantine "$2" 2>/dev/null
        open "$2"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", swap, "sh", "\(ProcessInfo.processInfo.processIdentifier)", app.path, fresh.path]
        guard (try? p.run()) != nil else {
            error = String(localized: "The update couldn't be installed. Try again later.")
            return
        }
        NSApp.terminate(nil)
    }

    /// App menu › Check for Updates…: the usual Mac alert.
    func checkAndAlert() async {
        await check(force: true)
        NSApp.activate()
        let a = NSAlert()
        if let latest {
            a.messageText = String(localized: "Pomly \(latest) Is Available")
            a.informativeText = String(localized: "You have Pomly \(Self.current). Pomly quits and reopens to finish the update.")
            a.addButton(withTitle: String(localized: "Install and Relaunch"))
            a.addButton(withTitle: String(localized: "Later"))
            guard a.runModal() == .alertFirstButtonReturn else { return }
            await install()
            guard let error else { return }
            let e = NSAlert()
            e.messageText = error
            e.runModal()
        } else if let error {
            a.messageText = error
            a.runModal()
        } else {
            a.messageText = String(localized: "You're Up to Date")
            a.informativeText = String(localized: "Pomly \(Self.current) is the latest version.")
            a.runModal()
        }
    }

    /// Runs off the main thread so unpacking doesn't freeze the UI.
    @concurrent private nonisolated static func run(_ tool: String, _ args: String...) async -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
    #endif
}

#if !os(watchOS) // the Watch app updates with the iPhone app
/// Settings section: hidden entirely in App Store builds.
struct UpdatesSection: View {
    private let updater = Updater.shared
    @AppStorage(Pref.autoUpdate, store: .shared) private var auto = true
    @Environment(\.openURL) private var openURL

    var body: some View {
        if updater.active {
            Section {
                if let v = updater.latest {
                    Button {
                        #if os(macOS)
                        Task { await updater.install() }
                        #else
                        openURL(Updater.altStore) { opened in if !opened { openURL(Updater.releases) } }
                        #endif
                    } label: {
                        LabeledContent("Update to \(v)") { if updater.installing { ProgressView().controlSize(.small) } }
                    }
                    .disabled(updater.installing)
                } else {
                    LabeledContent("Pomly \(Updater.current)", value: updater.error == nil ? String(localized: "Up to Date") : "")
                }
                Button {
                    Task { await updater.check(force: true) }
                } label: {
                    LabeledContent("Check for Updates") { if updater.checking { ProgressView().controlSize(.small) } }
                }
                .disabled(updater.checking || updater.installing)
                if let e = updater.error {
                    Text(e).font(.footnote).foregroundStyle(.secondary)
                }
                #if os(macOS)
                Toggle("Install Updates Automatically", isOn: $auto)
                #endif
            } header: {
                Text("Updates")
            } footer: {
                #if os(macOS)
                Text("Pomly checks GitHub for new versions and installs them between sessions.")
                #else
                Text("Add the Pomly source in AltStore and updates install by themselves.")
                #endif
            }
            .task { await updater.check() }
        }
    }
}
#endif
