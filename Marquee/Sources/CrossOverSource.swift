import Foundation

struct CrossOverSource {
    private static let bottlesRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CrossOver/Bottles")

    // MARK: - Known-launcher filtering
    //
    // CrossOver bottles routinely run a genuine Windows storefront client (Steam, Epic Games
    // Launcher, GOG Galaxy, ...) for games that aren't natively supported on macOS or by
    // CrossOver's handling of that specific title — a common setup: install CrossOver, install
    // Windows Steam INSIDE a bottle, install the game through it. Every scan strategy
    // below is shortcut/file-based and has no idea a matched shortcut is the storefront app
    // itself rather than a game — a bottle like that carries a real "Steam.lnk"/cxmenu.conf
    // "Steam" entry in its Start Menu and Desktop that would otherwise show up
    // as a fake game titled "Steam". Filtered by title AND by the resolved exe's basename (a
    // title match alone would miss a differently-named shortcut pointing at steam.exe; an exe
    // match alone would miss the cxmenu.conf "Steam" entry, which carries no Path/exe at all).
    private static let knownLauncherTitles: Set<String> = [
        "steam", "epic games launcher", "gog galaxy", "origin", "ea desktop",
        "battle.net", "ubisoft connect", "uplay", "rockstar games launcher",
    ]
    private static let knownLauncherExeNames: Set<String> = [
        "steam.exe", "steamwebhelper.exe", "epicgameslauncher.exe",
        "galaxyclient.exe", "galaxyclientservice.exe", "origin.exe", "eadesktop.exe",
        "battle.net.exe", "upc.exe", "ubisoftconnect.exe",
        "rockstargameslauncher.exe", "launcherpatcher.exe",
    ]

    private static func isKnownLauncher(title: String, exePath: String) -> Bool {
        if knownLauncherTitles.contains(title.lowercased()) { return true }
        guard !exePath.isEmpty else { return false }
        return knownLauncherExeNames.contains((exePath as NSString).lastPathComponent.lowercased())
    }

    static func scan() -> [Game] {
        guard let bottles = try? FileManager.default.contentsOfDirectory(
            at: bottlesRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let bottleDirs = bottles.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }

        let shortcutGames = bottleDirs.flatMap { scanBottle(at: $0, name: $0.lastPathComponent) }

        // Deduplicate across bottles — first occurrence wins
        var seen = Set<String>()
        let dedupedShortcutGames = shortcutGames.filter { game in
            seen.insert(game.title.lowercased().filter { !$0.isWhitespace }).inserted
        }

        // Folder fallback runs LAST, across ALL bottles, seeded with every already-known
        // title — not scoped to a single bottle. Both scanners above are 100% shortcut-
        // based (Start Menu .lnk / Desktop.lnk / cxmenu.conf), so a game that's genuinely
        // installed and playable (real save data on disk, launchable straight from CrossOver's
        // own "Windows Applications" list) but never got a shortcut created for it is invisible
        // to both — installers that skip Start Menu integration are the usual cause. Scoped to
        // drive_c/GAMES specifically (a conventional spot for manual game installs), so
        // false-positive risk is low, unlike scanning all of Program Files would be.
        // Must see EVERY bottle's titles, not just its own bottle's — a game's
        // shortcut and its actual files can live in different bottles.
        var knownTitles = dedupedShortcutGames.map { $0.title }
        var folderGames: [Game] = []
        for bottle in bottleDirs {
            // The bottled storefront library scan runs BEFORE the raw drive_c/GAMES
            // folder fallback, seeded with the same growing knownTitles list, so a game found
            // via a Steam manifest here is never also picked up as a spurious second entry by
            // the folder scan below.
            let bottledSteam = scanBottledSteamLibrary(at: bottle, bottleName: bottle.lastPathComponent,
                                                        skipTitles: knownTitles)
            knownTitles.append(contentsOf: bottledSteam.map { $0.title })
            folderGames.append(contentsOf: bottledSteam)

            let found = scanGamesFolderFallback(at: bottle, bottleName: bottle.lastPathComponent,
                                                 skipTitles: knownTitles)
            knownTitles.append(contentsOf: found.map { $0.title })
            folderGames.append(contentsOf: found)
        }

        return dedupedShortcutGames + folderGames
    }

    // MARK: - Bottled Steam library scanner (Steam installed INSIDE a CrossOver bottle)
    //
    // None of the three scan strategies above catch this setup: the resulting shortcuts are
    // `.url` InternetShortcut files (`URL=steam://rungameid/{id}`, no exe Path at all), not
    // `.lnk`/cxmenu `.lnk` sections, so they're invisible to both the LNK scanner and
    // parseCxmenuConf (which only accepts sections ending ".lnk"). A bottle with half a dozen
    // games installed this way can show zero of them through the shortcut scanners.
    // Reads the bottled Steam's own `steamapps/*.acf` manifests directly (same
    // format SteamSource already parses for the native macOS Steam library) to get each game's
    // real title, install folder, AND Steam appId. The resolved exe (via the same
    // `GameLauncher.bestExecutable` heuristic the drive_c/GAMES fallback uses) is kept for
    // size/location lookups and process-exit detection, but is deliberately NOT what PLAY
    // launches directly — launching a bottled Steam game's exe straight
    // under wine mostly doesn't work (these games check for a live Steam client / initialize
    // steam_api on startup for DRM/overlay/cloud-saves and fail or hang without it). The appId is
    // carried in `GameMetadata.viaLauncherAppId` so `GameLauncher` can instead route PLAY through
    // the bottled Steam client itself (`steam.exe -applaunch {id}`), same as a normal Steam
    // desktop shortcut would.
    private static let bottledSteamRelativePaths = [
        "drive_c/Program Files (x86)/Steam/steamapps",
        "drive_c/Program Files/Steam/steamapps",
    ]

    // Non-game entries Steam's own manifest system creates alongside real games (shared
    // redistributable/runtime packages, not launchable titles) — name-matched rather than a
    // hardcoded appid list so it doesn't bit-rot as Valve adds more of these over time.
    private static let nonGameSteamNameFragments = [
        "steamworks common redistributables", "steam linux runtime", "proton ",
    ]

    private static func scanBottledSteamLibrary(at bottleURL: URL, bottleName: String,
                                                 skipTitles: [String]) -> [Game] {
        // Exact whitespace-stripped dedup (same key style as the primary shortcut scan), NOT
        // the folder-fallback's fuzzy prefix-containment match — ACF manifest names are already
        // clean, canonical Steam titles with no messy-folder-name cleanup needed, and fuzzy
        // prefix matching actively breaks numbered sequels: "Portal" silently
        // vanished because `"portal2".hasPrefix("portal")` treated it as an already-seen
        // duplicate of "Portal 2" — two genuinely different games, not a formatting mismatch.
        var seenKeys = Set(skipTitles.map { $0.lowercased().filter { !$0.isWhitespace } })
        var games: [Game] = []
        for relPath in bottledSteamRelativePaths {
            let steamAppsDir = bottleURL.appendingPathComponent(relPath)
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: steamAppsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ) else { continue }

            for file in files where file.pathExtension == "acf" {
                guard let (title, installDir, appId) = parseACFTitleInstallDirAndAppId(at: file) else { continue }
                guard !nonGameSteamNameFragments.contains(where: { title.lowercased().contains($0) })
                else { continue }
                guard !isKnownLauncher(title: title, exePath: "") else { continue }

                let key = title.lowercased().filter { !$0.isWhitespace }
                guard !seenKeys.contains(key) else { continue }

                let commonDir = steamAppsDir.appendingPathComponent("common")
                    .appendingPathComponent(installDir)
                guard let exe = GameLauncher.bestExecutable(in: commonDir, title: title) else { continue }

                seenKeys.insert(key)
                games.append(Game(title: title, source: .crossOver(bottleName: bottleName, exePath: exe.path),
                                   metadata: GameMetadata(viaLauncher: "steam", viaLauncherAppId: appId)))
            }
        }
        return games
    }

    private static func parseACFTitleInstallDirAndAppId(
        at url: URL
    ) -> (title: String, installDir: String, appId: Int)? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var name: String?
        var installDir: String?
        var appId: Int?
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if name == nil, trimmed.hasPrefix("\"name\"") {
                name = extractACFValue(from: trimmed)
            } else if installDir == nil, trimmed.hasPrefix("\"installdir\"") {
                installDir = extractACFValue(from: trimmed)
            } else if appId == nil, trimmed.hasPrefix("\"appid\"") {
                appId = Int(extractACFValue(from: trimmed))
            }
            if name != nil && installDir != nil && appId != nil { break }
        }
        guard let n = name, !n.isEmpty, let d = installDir, !d.isEmpty, let id = appId else { return nil }
        return (n, d, id)
    }

    // Extract value from VDF line: "key"\t\t"value" — same format SteamSource.extractValue reads.
    private static func extractACFValue(from line: String) -> String {
        let parts = line.components(separatedBy: "\"")
        return parts.count >= 4 ? parts[3] : ""
    }

    private static func scanBottle(at url: URL, name bottleName: String) -> [Game] {
        var games: [Game] = []
        var seenTitles: Set<String> = []

        // Primary: scan Start Menu Programs directories for .lnk files
        let lnkGames = scanLNKs(at: url, bottleName: bottleName)
        for g in lnkGames {
            seenTitles.insert(g.title.lowercased().filter { !$0.isWhitespace })
            games.append(g)
        }

        // Fallback: parse cxmenu.conf for games without Programs .lnk entries
        let confGames = parseCxmenuConf(at: url, bottleName: bottleName, skipTitles: seenTitles)
        games.append(contentsOf: confGames)

        return games
    }

    // MARK: - drive_c/GAMES raw folder scanner (fallback for games with no shortcut at all)

    private static func scanGamesFolderFallback(at bottleURL: URL, bottleName: String,
                                                  skipTitles: [String]) -> [Game] {
        let gamesDir = bottleURL.appendingPathComponent("drive_c/GAMES")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: gamesDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        // Fuzzy dedup keyed on GameLauncher's alphanumeric-only normalize (not just whitespace-
        // stripping) with prefix containment in EITHER direction — catches e.g. a raw release-
        // style folder "Subnautica.2.v2026.05.20" (normalizes to "subnautica2v20260520") against
        // an already-scanned shortcut titled "Subnautica2" ("subnautica2" is a prefix of it).
        // A plain exact-match dedup missed exactly that case and shipped a spurious duplicate —
        // shortcut titles and raw install-folder names rarely agree on formatting even when
        // they're unambiguously the same game.
        var seenKeys = skipTitles.map { GameLauncher.normalize($0) }
        var games: [Game] = []
        for folder in entries {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { continue }
            let title = titleFromFolderName(folder.lastPathComponent)
            let key = GameLauncher.normalize(title)
            guard key.count >= 3 else { continue }
            guard !seenKeys.contains(where: { $0.hasPrefix(key) || key.hasPrefix($0) }) else { continue }
            // Reuses GameLauncher's own "most game-like .exe" heuristic (skip installers/
            // redists, prefer -Shipping, else largest) — the same logic that already resolves
            // a launch target at PLAY time for shortcut-based entries with an empty/folder-only
            // exePath, just run here at SCAN time so this entry stores a real, verified .exe
            // path immediately instead of depending on that lazy resolution succeeding later.
            guard let exe = GameLauncher.bestExecutable(in: folder, title: title) else { continue }
            seenKeys.append(key)
            games.append(Game(title: title, source: .crossOver(bottleName: bottleName, exePath: exe.path)))
        }
        return games
    }

    // Best-effort "FolderNameLikeThis" → "Folder Name Like This" for games with no shortcut to
    // source a real display title from. Folder names that already contain spaces (the common
    // case for anything with a proper installer) pass through unchanged since there's no
    // lowercase→uppercase transition to split on.
    private static func titleFromFolderName(_ raw: String) -> String {
        var result = ""
        let chars = Array(raw)
        for (i, c) in chars.enumerated() {
            if i > 0, c.isUppercase, chars[i - 1].isLowercase {
                result.append(" ")
            }
            result.append(c)
        }
        return result
    }

    // MARK: - .lnk scanner (primary)

    private static func scanLNKs(at bottleURL: URL, bottleName: String) -> [Game] {
        let programsDir = bottleURL.appendingPathComponent(
            "drive_c/ProgramData/Microsoft/Windows/Start Menu/Programs"
        )
        let iconsDir = bottleURL.appendingPathComponent(
            "windata/cxmenu/icons/hicolor/256x256/apps"
        )
        // Pre-load icon filenames once for efficient matching
        let iconFiles = (try? FileManager.default.contentsOfDirectory(at: iconsDir,
            includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []

        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: programsDir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        return folders.compactMap { folder -> Game? in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else { return nil }
            let gameName = folder.lastPathComponent
            guard gameName != "CrossOver", gameName != "Accessibility",
                  gameName != "Startup", gameName != "Administrative Tools" else { return nil }
            let lnk = folder.appendingPathComponent("\(gameName).lnk")
            guard FileManager.default.fileExists(atPath: lnk.path) else { return nil }
            let exePath = parseLNK(at: lnk, bottleURL: bottleURL) ?? ""
            guard !isKnownLauncher(title: gameName, exePath: exePath) else { return nil }
            let iconPath = findBundledIcon(for: gameName, in: iconFiles)
            return Game(title: gameName, source: .crossOver(bottleName: bottleName, exePath: exePath),
                        metadata: GameMetadata(bundledIconPath: iconPath))
        }
    }

    // Scan iconsDir for a .png whose filename contains a slug of the game title
    // Icons are named {HASH}_{GameName}.0.png — match on the game name portion
    private static func findBundledIcon(for gameName: String, in iconFiles: [URL]) -> URL? {
        // Build two slugs: one with dashes (e.g. "hi-fi-rush"), one bare (e.g. "hifirush")
        // CrossOver icon filenames vary: some use dashes, others concatenate words.
        let base = gameName.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: ".", with: "")
        let slugDash = base.replacingOccurrences(of: " ", with: "-")
        let slugBare = base.replacingOccurrences(of: " ", with: "")

        return iconFiles.first { file in
            guard file.pathExtension == "png" else { return false }
            // Strip the .png extension; fname is like "35C7_EverybodysGolfHotShots.0"
            let fname = file.deletingPathExtension().lastPathComponent.lowercased()
            let tail: String
            if let underIdx = fname.firstIndex(of: "_") {
                tail = String(fname[fname.index(after: underIdx)...])
            } else {
                tail = fname
            }
            return tail.hasPrefix(slugDash) || tail.hasPrefix(slugBare)
        }
    }

    // MARK: - cxmenu.conf parser (fallback for games without .lnk in Programs)

    private static func parseCxmenuConf(at bottleURL: URL, bottleName: String,
                                        skipTitles: Set<String>) -> [Game] {
        let confURL = bottleURL.appendingPathComponent("cxmenu.conf")
        guard let content = try? String(contentsOf: confURL, encoding: .utf8) else { return [] }

        let iconsDir = bottleURL.appendingPathComponent(
            "windata/cxmenu/icons/hicolor/256x256/apps"
        )

        var games: [Game] = []
        var seenTitles = skipTitles
        var currentTitle: String? = nil
        var currentIconName: String? = nil
        var currentWinExePath: String? = nil  // "Path" key from cxmenu.conf

        func flush() {
            guard let title = currentTitle else { return }
            defer { currentTitle = nil; currentIconName = nil; currentWinExePath = nil }

            // Normalize: strip whitespace so "Subnautica2" == "Subnautica 2"
            let key = title.lowercased().filter { !$0.isWhitespace }
            guard !seenTitles.contains(key) else { return }

            // Verify exe exists — filters stale/uninstalled cxmenu.conf entries
            var resolvedExePath = ""
            if let winPath = currentWinExePath {
                let macSubpath = winPath
                    .replacingOccurrences(of: "C:\\", with: "drive_c/")
                    .replacingOccurrences(of: "\\", with: "/")
                let exeURL = bottleURL.appendingPathComponent(macSubpath)
                guard FileManager.default.fileExists(atPath: exeURL.path) else { return }
                resolvedExePath = exeURL.path
            }

            guard !isKnownLauncher(title: title, exePath: resolvedExePath) else { return }

            seenTitles.insert(key)

            var iconPath: URL? = nil
            if let name = currentIconName {
                let candidate = iconsDir.appendingPathComponent("\(name).png")
                if FileManager.default.fileExists(atPath: candidate.path) { iconPath = candidate }
            }

            games.append(Game(
                title: title,
                source: .crossOver(bottleName: bottleName, exePath: resolvedExePath),
                metadata: GameMetadata(bundledIconPath: iconPath)
            ))
        }

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                flush()
                let section = String(trimmed.dropFirst().dropLast())

                // Only process Desktop and user roaming AppData shortcuts
                // (ProgramData ones are caught by the .lnk scanner)
                guard section.hasPrefix("Desktop.") ||
                      section.contains("AppData_Roaming_Microsoft_Windows_Start") else { continue }

                guard let slashIdx = section.lastIndex(of: "/"),
                      section.hasSuffix(".lnk") else { continue }

                var name = String(section[section.index(after: slashIdx)...])
                name = String(name.dropLast(4)) // drop ".lnk"

                // Decode CrossOver URL encoding
                name = name
                    .replacingOccurrences(of: "^3A", with: ":")
                    .replacingOccurrences(of: "^5E", with: "^")
                    .replacingOccurrences(of: "^2B", with: "+")
                    .replacingOccurrences(of: "+", with: " ")

                let lower = name.lowercased()
                guard !lower.isEmpty,
                      !lower.contains("uninstall"),
                      !lower.hasSuffix("-win64-shipping"),
                      !lower.hasSuffix("-win64"),
                      !lower.hasSuffix("-shipping") else { continue }

                currentTitle = name

            } else if trimmed.hasPrefix("\"Icon\""), let eq = trimmed.range(of: " = \"") {
                let rest = String(trimmed[eq.upperBound...])
                currentIconName = rest.hasSuffix("\"") ? String(rest.dropLast()) : rest

            } else if trimmed.hasPrefix("\"Path\""), let eq = trimmed.range(of: " = \"") {
                let rest = String(trimmed[eq.upperBound...])
                currentWinExePath = rest.hasSuffix("\"") ? String(rest.dropLast()) : rest
            }
        }
        flush()
        return games
    }

    // MARK: - .lnk binary parser

    private static func parseLNK(at url: URL, bottleURL: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let bytes = [UInt8](data)
        let pattern: [UInt8] = [0x43, 0x00, 0x3A, 0x00, 0x5C, 0x00] // UTF-16 LE "C:\"
        guard let start = findPattern(pattern, in: bytes) else { return nil }

        var utf16Bytes: [UInt8] = []
        var i = start
        while i + 1 < bytes.count {
            if bytes[i] == 0 && bytes[i + 1] == 0 { break }
            utf16Bytes.append(bytes[i])
            utf16Bytes.append(bytes[i + 1])
            i += 2
        }

        guard let winPath = String(data: Data(utf16Bytes), encoding: .utf16LittleEndian) else { return nil }
        let macSubpath = winPath
            .replacingOccurrences(of: "C:\\", with: "drive_c/")
            .replacingOccurrences(of: "\\", with: "/")
        return bottleURL.appendingPathComponent(macSubpath).path
    }

    private static func findPattern(_ pattern: [UInt8], in bytes: [UInt8]) -> Int? {
        guard pattern.count <= bytes.count else { return nil }
        for i in 0...(bytes.count - pattern.count) {
            if Array(bytes[i..<(i + pattern.count)]) == pattern { return i }
        }
        return nil
    }
}
