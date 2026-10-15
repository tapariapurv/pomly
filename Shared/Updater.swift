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

    /// At most hourly. On Mac, an idle app installs right away when automatic updates are on.
    func check(force: Bool = false) async {
        #if os(iOS)
        if !resolved { // only store installs have a verified App Store transaction
            resolved = true
            if case .verified(let t)? = try? await AppTransaction.shared, t.environment != .xcode { active = false } else { active = true }
        }
        #endif
        guard active, !installing, force || checked < .now - 3600 else { return }
        checked = .now
        struct Release: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: URL }
            let tag_name: String
            let assets: [Asset]
        }
        guard let (data, _) = try? await URLSession.shared.data(from: Self.api),
              let r = try? JSONDecoder().decode(Release.self, from: data) else { return }
        let v = r.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
        guard Self.isNewer(v, than: Self.current) else { latest = nil; return }
        latest = v
        download = r.assets.first { $0.name == "Pomly-macOS.zip" }?.browser_download_url
        installIfIdle()
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
        installing = true
        defer { installing = false }
        let fm = FileManager.default, dir = fm.temporaryDirectory.appending(path: "PomlyUpdate-\(UUID().uuidString)")
        guard let (zip, _) = try? await URLSession.shared.download(from: download),
              (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil,
              Self.run("/usr/bin/ditto", "-x", "-k", zip.path, dir.path) else { return }
        let fresh = dir.appending(path: "Pomly.app"), app = Bundle.main.bundleURL.path
        // ponytail: bundle-id check only; verify the code signature once releases are notarized.
        guard Bundle(url: fresh)?.bundleIdentifier == Bundle.main.bundleIdentifier else { return }
        let pid = ProcessInfo.processInfo.processIdentifier
        let swap = """
        while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done
        rm -rf "\(app)" && mv "\(fresh.path)" "\(app)"
        xattr -dr com.apple.quarantine "\(app)" 2>/dev/null
        open "\(app)"
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", swap]
        guard (try? p.run()) != nil else { return }
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ args: String...) -> Bool {
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
                    LabeledContent("Pomly \(Updater.current)", value: String(localized: "Up to Date"))
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
