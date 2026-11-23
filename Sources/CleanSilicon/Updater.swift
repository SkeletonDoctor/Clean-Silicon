import AppKit
import CryptoKit
import SwiftUI

/// Self-update from GitHub Releases.
///
/// Each release carries `CleanSilicon.zip` and `CleanSilicon.zip.sig`, an Ed25519 signature made with the
/// maintainer's private key (see Scripts/sign_update.swift). The app downloads the archive, checks the
/// signature against the public key below, stages the new bundle and swaps it in on restart or the next
/// quit. Nothing unsigned is ever installed.
@MainActor @Observable
final class Updater {
    /// The GitHub repository releases are pulled from. Forks: change this and `publicKey`.
    nonisolated static let repository = "SkeletonDoctor/Clean-Silicon"
    nonisolated static let publicKey = "qa9nFceNOuykHVSZkZvP79hZGneeatVBnR+bVxjRtHI="
    nonisolated static let archiveName = "CleanSilicon.zip"

    struct Release: Equatable {
        let version: String
        let archive: URL
        let signature: URL
    }

    enum Phase: Equatable {
        case idle, checking, upToDate
        case available(Release)
        case downloading(Release, Double)
        case ready(Release)
        case failed(String)
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static let shared = Updater()
    var phase: Phase = .idle

    @ObservationIgnored private var stagedApp: URL?
    @ObservationIgnored private var relaunchOnQuit = false
    @ObservationIgnored private var schedule: Task<Void, Never>?

    static var currentVersion: String? { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String }
    /// On unless turned off with `defaults write com.cleansilicon.app autoUpdate -bool NO`.
    static var automatic: Bool { UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true }

    /// Why this copy can't replace itself, or nil when it can.
    static var installBlocker: String? {
        let bundle = Bundle.main.bundleURL
        guard bundle.pathExtension == "app", currentVersion != nil else { return "This is a development build." }
        if bundle.path.contains("/AppTranslocation/") { return "Move Clean Silicon to the Applications folder and reopen it to enable updates." }
        if !FileManager.default.isWritableFile(atPath: bundle.deletingLastPathComponent().path) { return "Clean Silicon can't write to \(bundle.deletingLastPathComponent().path)." }
        return nil
    }

    private nonisolated static var staging: URL {
        Disk.home.appendingPathComponent("Library/Application Support/Clean Silicon/update", isDirectory: true)
    }

    var isBusy: Bool {
        switch phase { case .checking, .downloading: true; default: false }
    }

    /// Checks shortly after launch and then every six hours while the app stays open.
    func start() {
        guard schedule == nil else { return }
        try? FileManager.default.removeItem(at: Self.staging)   // leftovers from a previous run
        guard Self.currentVersion != nil else { return }
        schedule = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            while !Task.isCancelled {
                if let self, Self.automatic, !self.isBusy, self.stagedApp == nil { await self.check(userInitiated: false) }
                try? await Task.sleep(for: .seconds(6 * 60 * 60))
            }
        }
    }

    func check(userInitiated: Bool) async {
        guard !isBusy else { return }
        if case .ready = phase { return }
        phase = .checking
        do {
            guard let release = try await latestRelease(), Self.isVersion(release.version, newerThan: Self.currentVersion ?? "0") else {
                phase = .upToDate
                return
            }
            phase = .available(release)
            if Self.automatic || userInitiated, Self.installBlocker == nil { await download(release) }
        } catch {
            // Background checks fail silently (offline, rate limit); only report when the user asked.
            phase = userInitiated ? .failed(error.localizedDescription) : .idle
        }
    }

    private func latestRelease() async throws -> Release? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil }   // no releases published yet
        guard status == 200 else { throw Failure("GitHub didn't answer the update check (HTTP \(status)).") }

        struct Payload: Decodable {
            struct Asset: Decodable { let name: String; let browser_download_url: URL }
            let tag_name: String
            let assets: [Asset]
        }
        let payload = try JSONDecoder().decode(Payload.self, from: data)
        guard let archive = payload.assets.first(where: { $0.name == Self.archiveName }),
              let signature = payload.assets.first(where: { $0.name == Self.archiveName + ".sig" })
        else { return nil }   // a release without a signed build isn't installable
        let version = payload.tag_name.hasPrefix("v") ? String(payload.tag_name.dropFirst()) : payload.tag_name
        return Release(version: version, archive: archive.browser_download_url, signature: signature.browser_download_url)
    }

    /// Numeric, component-wise comparison: 1.10 > 1.9, 1.2 == 1.2.0.
    nonisolated static func isVersion(_ a: String, newerThan b: String) -> Bool {
        func parts(_ s: String) -> [Int] { s.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 } }
        let (x, y) = (parts(a), parts(b))
        for i in 0..<max(x.count, y.count) {
            let (l, r) = (i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
            if l != r { return l > r }
        }
        return false
    }

    func download(_ release: Release) async {
        if let blocker = Self.installBlocker { phase = .failed(blocker); return }
        phase = .downloading(release, 0)
        do {
            let fm = FileManager.default
            try? fm.removeItem(at: Self.staging)
            try fm.createDirectory(at: Self.staging, withIntermediateDirectories: true)

            let zip = try await fetchArchive(release)
            defer { try? fm.removeItem(at: zip) }
            let (signature, _) = try await URLSession.shared.data(from: release.signature)
            try Self.verify(archive: zip, signature: signature)

            let unpacked = Self.staging.appendingPathComponent("unpacked", isDirectory: true)
            try Self.runTool("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
            guard let app = (try? fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil))?.first(where: { $0.pathExtension == "app" }),
                  let staged = Bundle(url: app),
                  staged.bundleIdentifier == Bundle.main.bundleIdentifier,
                  let stagedVersion = staged.infoDictionary?["CFBundleShortVersionString"] as? String,
                  Self.isVersion(stagedVersion, newerThan: Self.currentVersion ?? "0")
            else { throw Failure("The downloaded update isn't a newer copy of Clean Silicon.") }
            try? Self.runTool("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])

            stagedApp = app
            phase = .ready(release)
        } catch {
            try? FileManager.default.removeItem(at: Self.staging)
            phase = .failed(error.localizedDescription)
        }
    }

    private func fetchArchive(_ release: Release) async throws -> URL {
        try await withCheckedThrowingContinuation { cont in
            var observation: NSKeyValueObservation?
            let task = URLSession.shared.downloadTask(with: release.archive) { tmp, response, error in
                observation?.invalidate()
                if let error { cont.resume(throwing: error); return }
                guard let tmp, (response as? HTTPURLResponse)?.statusCode == 200 else { cont.resume(throwing: Failure("Couldn't download the update.")); return }
                let keep = Self.staging.appendingPathComponent(Self.archiveName)
                do { try FileManager.default.moveItem(at: tmp, to: keep); cont.resume(returning: keep) } catch { cont.resume(throwing: error) }
            }
            observation = task.progress.observe(\.fractionCompleted) { progress, _ in
                let value = progress.fractionCompleted
                Task { @MainActor in if case .downloading(let r, _) = self.phase { self.phase = .downloading(r, value) } }
            }
            task.resume()
        }
    }

    nonisolated static func verify(archive: URL, signature: Data) throws {
        let text = String(decoding: signature, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sig = Data(base64Encoded: text),
              let keyData = Data(base64Encoded: publicKey),
              let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData),
              let data = try? Data(contentsOf: archive, options: .mappedIfSafe),
              key.isValidSignature(sig, for: data)
        else { throw Failure("The update's signature didn't verify, so it was discarded.") }
    }

    private nonisolated static func runTool(_ path: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure("\((path as NSString).lastPathComponent) failed while unpacking the update.") }
    }

    /// Quits, swaps the bundle and reopens the app.
    func installAndRelaunch() {
        guard stagedApp != nil else { return }
        relaunchOnQuit = true
        NSApp.terminate(nil)
    }

    /// Called while quitting: installs a staged update, if there is one.
    func finishOnQuit() {
        guard let staged = stagedApp, Self.installBlocker == nil else { return }
        let fm = FileManager.default
        let current = Bundle.main.bundleURL
        let old = Self.staging.appendingPathComponent("previous.app")
        do {
            try? fm.removeItem(at: old)
            try fm.moveItem(at: current, to: old)
            do { try fm.moveItem(at: staged, to: current) } catch {
                try? fm.moveItem(at: old, to: current)   // put the running version back
                throw error
            }
        } catch {
            NSLog("Clean Silicon: update install failed: \(error)")
            return
        }
        stagedApp = nil
        try? fm.removeItem(at: Self.staging)
        guard relaunchOnQuit else { return }
        // Opens the new copy as soon as this process has exited.
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"", current.path]
        try? waiter.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) { Updater.shared.start() }
    func applicationWillTerminate(_ notification: Notification) { Updater.shared.finishOnQuit() }
}

/// Sidebar line showing the installed version and the state of the updater.
struct UpdateRow: View {
    @State private var updater = Updater.shared

    var body: some View {
        let version = Updater.currentVersion ?? "dev"
        HStack(spacing: 6) {
            switch updater.phase {
            case .ready(let r):
                Button { updater.installAndRelaunch() } label: {
                    Label("Restart to update", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Palette.mint).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Version \(r.version) is downloaded and verified. It also installs by itself the next time you quit.")
            case .available(let r):
                Button { Task { await updater.download(r) } } label: {
                    Label("Get version \(r.version)", systemImage: "arrow.down.circle")
                        .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Palette.sky)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            default:
                Image(systemName: icon).font(.system(size: 12)).foregroundStyle(tint)
                    .symbolEffect(.pulse, isActive: updater.isBusy)
                Text(status(version)).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                    .contentTransition(.numericText())
                Spacer(minLength: 0)
                Button { Task { await updater.check(userInitiated: true) } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 10.5, weight: .bold)).foregroundStyle(.white.opacity(0.6))
                        .frame(width: 22, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain).disabled(updater.isBusy).help(failure ?? "Check GitHub for a newer version")
            }
        }
        .padding(.horizontal, 12).padding(.bottom, 6)
        .animation(.spring(duration: 0.35), value: updater.phase)
    }

    private var failure: String? { if case .failed(let m) = updater.phase { m } else { nil } }
    private var icon: String {
        switch updater.phase {
        case .failed: "exclamationmark.triangle.fill"
        case .upToDate: "checkmark.circle.fill"
        default: "arrow.triangle.2.circlepath"
        }
    }
    private var tint: Color {
        switch updater.phase { case .failed: Palette.orange; case .upToDate: Palette.mint; default: .white.opacity(0.6) }
    }
    private func status(_ version: String) -> String {
        switch updater.phase {
        case .checking: "Checking…"
        case .downloading(let r, let p): "Updating · \(Int(p * 100))%"
        case .upToDate: "v\(version) · Up to date"
        case .failed: "Update failed"
        default: "Version \(version)"
        }
    }
}
