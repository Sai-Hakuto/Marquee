import Foundation
import AppKit

// Orchestrates the "get out of the way" behaviour around launching a game:
//
//   PLAY  → fade the music to silence over 2s + pause it, then miniaturize Marquee to the Dock.
//   …game runs…
//   quit  → restore the window exactly as it was (windowed or full screen), resume the music
//           from where it paused and swell it back up to the user's volume.
//
// All four PLAY paths (carousel, Detail page, List view, keyboard) route through `launch`.
@MainActor
@Observable
final class GameSessionManager {
    // Wired once at startup by MarqueeApp. We can't reach our AppDelegate via NSApp.delegate —
    // SwiftUI installs its own SwiftUI.AppDelegate wrapper there — so it's injected directly.
    var music: MusicPlayerController?
    weak var appDelegate: AppDelegate?
    var sound: SoundEffects?
    weak var appState: AppState?

    private(set) var activeGame: Game?
    var isInSession: Bool { activeGame != nil }

    private var sessionTask: Task<Void, Never>?

    @discardableResult
    func launch(_ game: Game) -> Bool {
        // Already babysitting a game? Just bring it forward again — don't stack sessions.
        guard sessionTask == nil else { return GameLauncher.launch(game) }

        // Snapshot the running GUI apps *before* launching so we can spot the new one that
        // appears: bundle IDs drive Steam/Epic start/stop detection; pids let us identify and
        // activate the game window (wine games have no bundle identifier).
        let baseline = GameProcessMonitor.regularAppBundleIDs()
        let baselinePIDs = GameProcessMonitor.runningAppPIDs()
        sound?.play(.confirm)   // the "launch" chime — covers all four PLAY paths
        guard GameLauncher.launch(game) else { return false }
        appState?.recordPlay(game)   // Most Played / Last Played sort tracking

        activeGame = game
        let music = self.music
        sessionTask = Task { [weak self] in
            await self?.runSession(game, baseline: baseline, baselinePIDs: baselinePIDs, music: music)
            self?.activeGame = nil
            self?.sessionTask = nil
        }
        return true
    }

    private func runSession(_ game: Game, baseline: Set<String>,
                            baselinePIDs: Set<pid_t>, music: MusicPlayerController?) async {
        let wasPlaying = music?.isPlaying ?? false

        // 1. Fade down + pause, then drop to the Dock.
        if wasPlaying { await music?.fadeOutAndPause(over: 2.0) }
        appDelegate?.minimizeForGameSession()

        // 2. Wait for the game to start and then exit. If it never positively shows up the
        //    grace period lapses and we restore anyway, so the user is never stranded. Once it
        //    starts, pull the game window to the front so macOS hides the Dock + menu bar for it
        //    (otherwise focus falls to Finder and a "borderless fullscreen" game looks windowed).
        //    `sessionStart` is stamped inside `onStarted` — i.e. once the game is CONFIRMED
        //    running, not at launch — so a game that never actually appears (grace period lapses)
        //    correctly contributes zero playtime instead of counting the whole wait.
        var sessionStart: Date?
        await GameProcessMonitor.awaitSession(for: game, baseline: baseline) {
            sessionStart = Date()
            await GameProcessMonitor.bringGameToFront(game: game, baselinePIDs: baselinePIDs)
        }
        if let sessionStart {
            appState?.addPlaytime(Date().timeIntervalSince(sessionStart), to: game)
        }

        // 3. Come back: restore the window first (instant return), then fade the music in.
        appDelegate?.restoreFromGameSession()
        if wasPlaying { await music?.resumeFadingIn(over: 2.0) }
    }
}

// MARK: - Process detection
//
// "We have the list of games, so surely we'd know if that process was running." Per source:
//   • CrossOver — resolve the .exe PLAY launches and look for it in the wine process arguments.
//   • Mac (.app) — match the bundle URL against NSWorkspace.runningApplications.
//   • Steam / Epic — we don't know the final executable, so watch for the new GUI app that
//     appears after launch (anything that isn't us or a known launcher) and track its lifetime.
@MainActor
enum GameProcessMonitor {
    private static let pollInterval: TimeInterval = 2.0
    private static let appearTimeout: TimeInterval = 60.0       // give the game this long to show up
    private static let appActivateTimeout: TimeInterval = 30.0  // and this long for its window to register

    // Waits for the game to start, fires `onStarted` once, then waits for it to exit.
    static func awaitSession(for game: Game, baseline: Set<String>,
                             onStarted: () async -> Void) async {
        switch game.source {
        case .applications(let bundleURL), .gog(_, let bundleURL), .playCover(_, let bundleURL):
            let target = bundleURL.standardizedFileURL
            await waitStartThenExit(isRunning: { macAppRunning(target) }, onStarted: onStarted)

        case .crossOver:
            guard let exe = GameLauncher.crossOverExeName(for: game)?.lowercased() else { return }
            await waitStartThenExit(isRunning: { await psContains(exe) }, onStarted: onStarted)

        case .steam, .epic:
            await waitForLauncherGame(baseline: baseline, onStarted: onStarted)
        }
    }

    // Block until `isRunning` first becomes true (or the grace period lapses), fire `onStarted`,
    // then block until it becomes false again.
    private static func waitStartThenExit(isRunning: () async -> Bool, onStarted: () async -> Void) async {
        let deadline = Date().addingTimeInterval(appearTimeout)
        var started = false
        while Date() < deadline {
            if await isRunning() { started = true; break }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        guard started else { return }
        await onStarted()
        while await isRunning() {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    // Steam/Epic: identify the new GUI app(s) that appear after launch, then wait for them to quit.
    private static func waitForLauncherGame(baseline: Set<String>, onStarted: () async -> Void) async {
        let deadline = Date().addingTimeInterval(appearTimeout)
        var tracked: Set<String> = []
        while Date() < deadline {
            let candidates = newGameCandidates(baseline: baseline)
            if !candidates.isEmpty { tracked = candidates; break }
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
        guard !tracked.isEmpty else { return }
        await onStarted()
        while !regularAppBundleIDs().isDisjoint(with: tracked) {
            try? await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        }
    }

    // Pull the freshly-launched game to the front so macOS hides the Dock + menu bar for it.
    // The game's GUI app registers a little after its process spawns, so poll for the new app
    // (the one that wasn't running before launch), then activate it — re-asserting once because
    // games often grab/lose focus while their window finishes initializing.
    static func bringGameToFront(game: Game, baselinePIDs: Set<pid_t>) async {
        let exeName = GameLauncher.crossOverExeName(for: game)?.lowercased()
        let deadline = Date().addingTimeInterval(appActivateTimeout)
        while Date() < deadline {
            if let app = newGameApp(baselinePIDs: baselinePIDs, exeName: exeName) {
                app.activate(options: [.activateAllWindows])
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                app.activate(options: [.activateAllWindows])
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    // The new regular (GUI) app that appeared since launch — i.e. the game. Matches the CrossOver
    // exe by name when known; otherwise the most recently launched non-launcher app.
    private static func newGameApp(baselinePIDs: Set<pid_t>, exeName: String?) -> NSRunningApplication? {
        let new = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
                && !baselinePIDs.contains($0.processIdentifier)
                && $0.processIdentifier != getpid()
        }
        guard !new.isEmpty else { return nil }
        if let exeName, let match = new.first(where: {
            $0.executableURL?.lastPathComponent.lowercased() == exeName
                || $0.localizedName?.lowercased() == exeName
        }) { return match }
        let filtered = new.filter { app in
            let id = app.bundleIdentifier ?? ""
            return !id.contains("steam") && !id.contains("epicgames")
                && !id.contains("crossover") && !id.contains("codeweavers")
        }
        return (filtered.isEmpty ? new : filtered)
            .max(by: { ($0.launchDate ?? .distantPast) < ($1.launchDate ?? .distantPast) })
    }

    // GUI apps that appeared since `baseline`, excluding ourselves and the storefront launchers.
    private static func newGameCandidates(baseline: Set<String>) -> Set<String> {
        let me = Bundle.main.bundleIdentifier
        return regularAppBundleIDs().subtracting(baseline).filter { id in
            id != me
                && !id.contains("steam")
                && !id.contains("epicgames")
                && !id.contains("crossover")
                && !id.contains("codeweavers")
        }
    }

    // MARK: Primitives

    static func regularAppBundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { $0.bundleIdentifier })
    }

    static func runningAppPIDs() -> Set<pid_t> {
        Set(NSWorkspace.shared.runningApplications.map { $0.processIdentifier })
    }

    private static func macAppRunning(_ standardizedURL: URL) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleURL?.standardizedFileURL == standardizedURL
        }
    }

    // Does any running process's command line contain `needle` (a lowercased .exe filename)?
    // CrossOver runs the game through wine, so the unix path to the .exe shows up in `ps`.
    private static func psContains(_ needle: String) async -> Bool {
        await Task.detached(priority: .utility) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/ps")
            p.arguments = ["-axww", "-o", "command="]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            do { try p.run() } catch { return false }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self).lowercased().contains(needle)
        }.value
    }
}
