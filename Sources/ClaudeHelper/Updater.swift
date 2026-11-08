import AppKit
import CryptoKit
import Foundation
import HelperCore
import Observation

/// Keeps Relay up to date. It asks GitHub for `latest-mac.json` of the latest release (at launch and every
/// 6 hours, while the setting is on), and installs an update only when the DMG's Ed25519 signature matches
/// the public key below. Releases are signed in CI with the matching private key (scripts/sign-update.swift).
@MainActor
@Observable
final class Updater {
    nonisolated static let publicKey = "B4MPlHBjxggR3OWPCITthS6KPmjFGXZ44jRsSC2H+b4="
    static let feed = URL(string: "https://github.com/ShiNxz/Relay/releases/latest/download/latest-mac.json")!
    static let releasesPage = URL(string: "https://github.com/ShiNxz/Relay/releases/latest")!

    struct Release: Decodable, Equatable {
        let version: String
        let url: URL
        let signature: String
        let notes: String?
    }

    var available: Release?
    var checking = false
    var installing = false
    var error: String?
    var autoCheck: Bool {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "update.autoCheck") }
    }
    weak var model: AppModel?
    private var notified: String?
    private var timer: Timer?

    var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0" }

    init() {
        autoCheck = UserDefaults.standard.object(forKey: "update.autoCheck") as? Bool ?? true
    }

    /// Only a real app bundle updates itself; builds run from the command line or the self-check never do.
    var canUpdate: Bool { Bundle.main.bundleURL.pathExtension == "app" && SelfCheck.outputDir == nil }

    func start() {
        guard canUpdate else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            if self.autoCheck { await self.check(background: true) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.autoCheck else { return }
                await self.check(background: true)
            }
        }
    }

    /// "0.10.1" > "0.9.3"; a leading "v" is ignored, missing parts count as 0.
    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    nonisolated static func verify(_ data: Data, signature: String, publicKey: String = Updater.publicKey) -> Bool {
        guard let sig = Data(base64Encoded: signature), let raw = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { return false }
        return key.isValidSignature(sig, for: data)
    }

    func check(background: Bool) async {
        guard !checking, canUpdate else { return }
        checking = true
        error = nil
        defer { checking = false }
        do {
            var request = URLRequest(url: Self.feed)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 30
            let (data, response) = try await URLSession.shared.data(for: request)
            // A release without update information (older ones) means there is nothing to offer.
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { available = nil; return }
            let release = try JSONDecoder().decode(Release.self, from: data)
            available = Self.isNewer(release.version, than: current) ? release : nil
            if let a = available, background, notified != a.version {
                notified = a.version
                model?.notify("Relay \(a.version) is ready to install. Open the Relay menu and choose Install.", title: "Relay update available", system: true)
            }
        } catch {
            if !background { self.error = "Could not check for updates: " + error.localizedDescription }
        }
    }

    /// Check the download's signature, mount it, copy Relay out next to `appURL` and check its code signature.
    /// Returns the staged copy. Nothing is replaced yet.
    nonisolated static func stage(dmg: URL, signature: String, publicKey: String = Updater.publicKey, bundleId: String?,
                                  nextTo appURL: URL, work: URL) throws -> URL {
        let fm = FileManager.default
        guard verify(try Data(contentsOf: dmg, options: .mappedIfSafe), signature: signature, publicKey: publicKey) else {
            throw HelperError.message("The update's signature does not match. Nothing was installed.")
        }
        let mount = work.appendingPathComponent("mount", isDirectory: true)
        try BackupManager.run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        // Staged next to the current app, so the swap is a rename on one volume.
        let staged = appURL.deletingLastPathComponent().appendingPathComponent(".Relay-update-\(UUID().uuidString).app")
        let copied: Result<Void, Error> = Result {
            guard let newApp = try fm.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }),
                  Bundle(url: newApp)?.bundleIdentifier == bundleId else {
                throw HelperError.message("The update does not contain Relay.")
            }
            try BackupManager.run("/usr/bin/ditto", [newApp.path, staged.path])
        }
        _ = try? BackupManager.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
        try copied.get()
        do {
            try BackupManager.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged.path])
        } catch {
            try? fm.removeItem(at: staged)
            throw HelperError.message("The update's code signature is not valid. Nothing was installed.")
        }
        return staged
    }

    /// Put the staged copy in place of `appURL`. Returns where the old copy went; puts it back on failure.
    nonisolated static func swap(staged: URL, into appURL: URL) throws -> URL {
        let fm = FileManager.default
        let old = appURL.deletingLastPathComponent().appendingPathComponent(".Relay-old-\(UUID().uuidString).app")
        try fm.moveItem(at: appURL, to: old)
        do {
            try fm.moveItem(at: staged, to: appURL)
        } catch {
            try? fm.moveItem(at: old, to: appURL)
            try? fm.removeItem(at: staged)
            throw error
        }
        return old
    }

    func confirmAndInstall() {
        guard let r = available, !installing else { return }
        let alert = NSAlert()
        alert.messageText = "Install Relay \(r.version)?"
        alert.informativeText = "Relay downloads the update, checks its signature, replaces itself and restarts. Claude keeps running. You have \(current)."
        alert.addButton(withTitle: "Install and Restart")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await install(r) }
    }

    private func install(_ r: Release) async {
        installing = true
        error = nil
        defer { installing = false }
        let fm = FileManager.default
        let appURL = Bundle.main.bundleURL
        let parent = appURL.deletingLastPathComponent()
        let work = fm.temporaryDirectory.appendingPathComponent("relay-update-" + UUID().uuidString, isDirectory: true)
        defer { try? fm.removeItem(at: work) }
        do {
            guard fm.isWritableFile(atPath: parent.path) else {
                throw HelperError.message("Relay cannot replace itself in \(parent.path). Download the update from the release page instead.")
            }
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            let (downloaded, response) = try await URLSession.shared.download(from: r.url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw HelperError.message("The download failed.") }
            let dmg = work.appendingPathComponent("update.dmg")
            try fm.moveItem(at: downloaded, to: dmg)
            let staged = try Self.stage(dmg: dmg, signature: r.signature, bundleId: Bundle.main.bundleIdentifier, nextTo: appURL, work: work)
            let old = try Self.swap(staged: staged, into: appURL)
            // Once this process has exited: open the new version and remove the old one.
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"; /bin/rm -rf \"$1\"",
                                  appURL.path, old.path]
            try relaunch.run()
            NSApp.terminate(nil)
        } catch {
            self.error = error.localizedDescription
            model?.notify(error.localizedDescription, title: "Could not install the update", warning: true, system: true)
        }
    }
}
