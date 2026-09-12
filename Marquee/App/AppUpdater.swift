import Foundation
import AppKit

// Self-contained GitHub-releases updater: check latest release -> compare version -> download the
// .app zip asset -> swap it in for the running bundle -> relaunch. No Sparkle/external dependency,
// since the whole point is a couch setup never needs anyone to touch a terminal. Every release this
// project publishes MUST include an asset ending "-app.zip" containing Marquee.app at its root, or
// checkForUpdates has nothing to install (see tools/export-public.sh / release notes).
struct UpdateInfo {
    let version: String
    let assetURL: URL
    let notes: String
}

@MainActor
final class AppUpdater {
    static let shared = AppUpdater()
    private init() {}

    // owner/repo — the public GitHub repo this app checks against for new releases.
    // Fork releases must not be replaced by upstream builds without PlayCover support.
    private static let repoSlug = "Sai-Hakuto/Marquee"

    private(set) var isBusy = false

    var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    // `userInitiated` controls whether a no-op result (already up to date, or a network/parse
    // failure) surfaces anything — the silent startup check should never interrupt someone just
    // trying to play a game, but a manual "Check for Updates…" click always owes a response.
    func checkForUpdates(userInitiated: Bool, appState: AppState?) async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        let info: UpdateInfo
        do {
            info = try await fetchLatestRelease()
        } catch {
            if userInitiated { appState?.showToast("Couldn't check for updates — \(error.localizedDescription)") }
            return
        }
        guard isNewer(info.version, than: currentVersion) else {
            if userInitiated { appState?.showToast("You're up to date (v\(currentVersion))") }
            return
        }
        presentUpdateAlert(info, appState: appState)
    }

    private func fetchLatestRelease() async throws -> UpdateInfo {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repoSlug)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, _) = try await URLSession.marquee.data(for: request)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]],
              let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix("-app.zip") == true }),
              let urlString = asset["browser_download_url"] as? String,
              let url = URL(string: urlString)
        else { throw UpdateError.malformedRelease }
        return UpdateInfo(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
                           assetURL: url,
                           notes: json["body"] as? String ?? "")
    }

    // Plain dotted-numeric compare (1.2.3 vs 1.10.0) — string comparison alone would sort "1.10" before "1.2".
    private func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private func presentUpdateAlert(_ info: UpdateInfo, appState: AppState?) {
        let alert = NSAlert()
        alert.messageText = "Marquee \(info.version) is available"
        alert.informativeText = info.notes.isEmpty
            ? "You're currently on v\(currentVersion)."
            : String(info.notes.prefix(500))
        alert.addButton(withTitle: "Update & Relaunch")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await downloadAndInstall(info, appState: appState) }
    }

    private func downloadAndInstall(_ info: UpdateInfo, appState: AppState?) async {
        isBusy = true
        defer { isBusy = false }
        do {
            let (tmpFile, _) = try await URLSession.marquee.download(from: info.assetURL)
            let workDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
            let zipPath = workDir.appendingPathComponent("update.zip")
            try FileManager.default.moveItem(at: tmpFile, to: zipPath)

            try await unzip(zipPath, to: workDir)
            guard let newAppURL = try appBundle(in: workDir) else { throw UpdateError.noAppInArchive }

            try swapInPlace(newAppURL)
            relaunch()
        } catch {
            appState?.showToast("Update failed — \(error.localizedDescription)")
        }
    }

    // Shells out to /usr/bin/ditto (always present on macOS, unlike a bundled unzip library) to
    // expand the downloaded release zip.
    private func unzip(_ zip: URL, to dest: URL) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path, dest.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.unzipFailed }
    }

    private func appBundle(in dir: URL) throws -> URL? {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .first { $0.pathExtension == "app" }
    }

    // Moves the currently-running bundle aside (not deleted, in case the swap-in fails partway),
    // puts the freshly-downloaded one in its place, and cleans up the aside copy only once that
    // succeeds — a failed move leaves the user with the OLD app still intact and launchable rather
    // than no app at all.
    private func swapInPlace(_ newAppURL: URL) throws {
        let currentAppURL = Bundle.main.bundleURL
        let backupURL = currentAppURL.deletingLastPathComponent()
            .appendingPathComponent(".Marquee-preupdate.bak")
        try? FileManager.default.removeItem(at: backupURL)
        try FileManager.default.moveItem(at: currentAppURL, to: backupURL)
        do {
            try FileManager.default.moveItem(at: newAppURL, to: currentAppURL)
        } catch {
            try? FileManager.default.removeItem(at: currentAppURL)
            try? FileManager.default.moveItem(at: backupURL, to: currentAppURL)
            throw error
        }
        try? FileManager.default.removeItem(at: backupURL)
    }

    private func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    enum UpdateError: LocalizedError {
        case malformedRelease, noAppInArchive, unzipFailed
        var errorDescription: String? {
            switch self {
            case .malformedRelease: return "couldn't read the latest release"
            case .noAppInArchive:   return "the downloaded update didn't contain Marquee.app"
            case .unzipFailed:      return "couldn't unpack the downloaded update"
            }
        }
    }
}
