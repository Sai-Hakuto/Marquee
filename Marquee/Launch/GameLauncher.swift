import Foundation
import AppKit

// Launcher wired to the Detail page PLAY button. Each source uses its native launch
// mechanism. CrossOver shells out to the bundled wine binary.
enum GameLauncher {
    @discardableResult
    static func launch(_ game: Game) -> Bool {
        switch game.source {
        case .steam(let appId):
            return NSWorkspace.shared.open(URL(string: "steam://rungameid/\(appId)")!)

        case .epic(let appName, let catalogItemId):
            let str = "com.epicgames.launcher://apps/\(catalogItemId)%3A\(appName)?action=launch&silent=true"
            guard let url = URL(string: str) else { return false }
            return NSWorkspace.shared.open(url)

        case .applications(let bundleURL), .gog(_, let bundleURL):
            NSWorkspace.shared.openApplication(at: bundleURL,
                                               configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
            return true

        case .crossOver(let bottleName, let exePath):
            return launchCrossOver(bottleName: bottleName, exePath: exePath, title: game.title,
                                    steamAppId: game.metadata.viaLauncherAppId)
        }
    }

    // Debug: what PLAY would invoke, without launching (used by MARQUEE_SIZECHECK).
    static func debugLaunchTarget(_ game: Game) -> String {
        switch game.source {
        case .steam(let id):           return "steam://rungameid/\(id)"
        case .epic(let app, let cat):  return "epic apps/\(cat):\(app)"
        case .applications(let u), .gog(_, let u): return u.path
        case .crossOver(let bottle, let exePath):
            let bottleURL = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/CrossOver/Bottles/\(bottle)")
            if let appId = game.metadata.viaLauncherAppId {
                if let steamExe = bottledSteamExe(bottleURL: bottleURL) {
                    return "wine \(steamExe.lastPathComponent) -applaunch \(appId)"
                }
                return "⚠️ BOTTLED STEAM CLIENT NOT FOUND (appId \(appId))"
            }
            if let exe = resolveWineExe(exePath: exePath, bottleURL: bottleURL, title: game.title) {
                return "wine \(exe.lastPathComponent)"
            }
            return "⚠️ NO LAUNCHABLE EXE FOUND"
        }
    }

    // The filename of the .exe that PLAY would launch for a CrossOver game (e.g.
    // "Solarpunk.exe"). GameSessionManager matches this against the wine process arguments to
    // tell whether the game is still running. Returns nil for non-CrossOver games.
    static func crossOverExeName(for game: Game) -> String? {
        guard case .crossOver(let bottleName, let exePath) = game.source else { return nil }
        let bottleURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CrossOver/Bottles/\(bottleName)")
        return resolveWineExe(exePath: exePath, bottleURL: bottleURL, title: game.title)?.lastPathComponent
    }

    // MARK: - CrossOver

    private static func launchCrossOver(bottleName: String, exePath: String, title: String,
                                         steamAppId: Int?) -> Bool {
        let bottleURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CrossOver/Bottles/\(bottleName)")
        let wine = "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine"
        guard FileManager.default.fileExists(atPath: wine) else {
            NSLog("[Marquee] CrossOver wine binary not found at \(wine)")
            return false
        }

        // Bottled-Steam games (CrossOverSource.scanBottledSteamLibrary) MUST launch through the
        // bottled Steam client itself, not their resolved exe directly — launching the exe under
        // wine mostly doesn't work for these: the game checks for a live
        // Steam client / initializes steam_api on startup (DRM, overlay, cloud saves) and fails
        // or hangs without it. `-applaunch` is the same flag a real Steam desktop shortcut uses.
        if let appId = steamAppId {
            guard let steamExe = bottledSteamExe(bottleURL: bottleURL) else {
                NSLog("[Marquee] CrossOver: bottled Steam client not found for \(title) (appId \(appId))")
                return false
            }
            // Spawned with TCC responsibility disclaimed (see DisclaimedProcess) so CrossOver's
            // own .app-shortcut housekeeping isn't attributed to Marquee by macOS.
            guard DisclaimedProcess.spawn(
                executable: URL(fileURLWithPath: wine),
                arguments: ["--bottle", bottleName, steamExe.path, "-applaunch", "\(appId)"],
                currentDirectory: steamExe.deletingLastPathComponent()
            ) else {
                NSLog("[Marquee] CrossOver Steam launch failed for \(title)")
                return false
            }
            NSLog("[Marquee] Launching \(title) via bottled Steam: wine --bottle \(bottleName) "
                + "\"\(steamExe.path)\" -applaunch \(appId)")
            return true
        }

        guard let exe = resolveWineExe(exePath: exePath, bottleURL: bottleURL, title: title) else {
            NSLog("[Marquee] CrossOver: could not find an .exe to launch for \(title)")
            return false
        }
        // Run the exe as a POSITIONAL argument to CrossOver's wine Perl script with --bottle.
        // The script sets up the full environment (CX_ROOT, WINELOADER, WINESERVER, DYLD,
        // arch detection, etc.) from the bottle.
        //
        // NOTE: do NOT use --cx-app here. Despite the name, `wine --bottle X --cx-app <unix path>`
        // makes wine resolve the program relative to drive_c and fails with
        // "could not find '<path>' in '.../drive_c'. Is it installed?" even for a path that
        // exists. The bare positional form (`wine --bottle X <unix exe path>`) is what actually
        // launches the game — verified live against notepad.exe and real games.
        //
        // Spawned with TCC responsibility disclaimed (see DisclaimedProcess) so CrossOver's
        // own .app-shortcut housekeeping isn't attributed to Marquee by macOS.
        guard DisclaimedProcess.spawn(
            executable: URL(fileURLWithPath: wine),
            arguments: ["--bottle", bottleName, exe.path],
            currentDirectory: exe.deletingLastPathComponent()
        ) else {
            NSLog("[Marquee] CrossOver launch failed for \(title)")
            return false
        }
        NSLog("[Marquee] Launching \(title): wine --bottle \(bottleName) \"\(exe.path)\"")
        return true
    }

    // Same two candidate roots CrossOverSource.scanBottledSteamLibrary scans for steamapps —
    // the client exe lives one level up from steamapps itself.
    private static func bottledSteamExe(bottleURL: URL) -> URL? {
        for relPath in ["drive_c/Program Files (x86)/Steam/steam.exe",
                         "drive_c/Program Files/Steam/steam.exe"] {
            let candidate = bottleURL.appendingPathComponent(relPath)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    // exePath may be a real .exe, a game FOLDER, or empty — resolve to a launchable .exe.
    private static func resolveWineExe(exePath: String, bottleURL: URL, title: String) -> URL? {
        if exePath.lowercased().hasSuffix(".exe"), FileManager.default.fileExists(atPath: exePath) {
            return URL(fileURLWithPath: exePath)
        }
        guard let dir = GameDetailsFetcher.crossOverGameDir(
            bottleURL: bottleURL, exePath: exePath, title: title) else { return nil }
        return bestExecutable(in: dir, title: title)
    }

    // Pick the most game-like .exe in a folder: skip installers/redists/crash handlers,
    // prefer an Unreal "-Shipping" exe, then a title-name match, then the largest binary.
    // Not private — CrossOverSource's drive_c/GAMES folder-fallback scan
    // reuses this exact heuristic to resolve a real launch target for games that were found on
    // disk but have no Start Menu/Desktop shortcut for the primary scanners to key off of.
    static func bestExecutable(in dir: URL, title: String) -> URL? {
        let junk = ["unins", "redist", "vcredist", "vc_redist", "setup", "dxsetup", "directx",
                    "crashpad", "crashreport", "dotnet", "oalinst", "easyanticheat", "eac",
                    "prereq", "ue4prereq", "ue5prereq", "notification_helper", "support",
                    "uninstall", "config", "launcher_installer"]
        var candidates: [(url: URL, size: Int64)] = []
        if let en = FileManager.default.enumerator(
            at: dir, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) {
            var scanned = 0
            for case let f as URL in en {
                scanned += 1
                if scanned > 5000 { break }
                guard f.pathExtension.lowercased() == "exe" else { continue }
                let name = f.lastPathComponent.lowercased()
                if junk.contains(where: { name.contains($0) }) { continue }
                let size = Int64((try? f.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
                candidates.append((f, size))
            }
        }
        guard !candidates.isEmpty else { return nil }

        // Prefer an exe sitting directly in the game's own root folder over ones buried in a
        // subdirectory, when any root-level candidate exists — installer-bundled SDKs/dev tools
        // (e.g. a Steam copy of Portal ships Source SDK's bin/ compiler
        // toolset — vbsp.exe, studiomdl.exe, hammer.exe, elementviewer.exe, etc. — alongside the
        // real launcher; elementviewer.exe alone outweighs the actual launcher, hl2.exe, so
        // largest-file-wins picked the wrong one) typically live in a subfolder, while the real
        // launcher conventionally sits at the game's own root. Games with no root-level exe at
        // all (e.g. Fable Anniversary, only Binaries/Win32/*.exe) fall through to the full set.
        let rootLevel = candidates.filter {
            $0.url.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL
        }
        let pool = rootLevel.isEmpty ? candidates : rootLevel

        if let ship = pool.first(where: { $0.url.lastPathComponent.lowercased().contains("shipping") }) {
            return ship.url
        }
        let t = normalize(title)
        if t.count >= 4, let named = pool.first(where: {
            let n = normalize($0.url.deletingPathExtension().lastPathComponent)
            return n.count >= 3 && (n.contains(t) || t.contains(n))
        }) { return named.url }

        return pool.max(by: { $0.size < $1.size })?.url
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }
}
