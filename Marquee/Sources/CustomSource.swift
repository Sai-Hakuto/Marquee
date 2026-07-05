import Foundation
import AppKit

// User-curated library entries — the escape hatch for anything the automatic scanners can't
// know about: games on a network volume or jump drive with a user-invented layout ("scan
// folders"), and individually added apps/exes, including non-games people want couch-launchable
// (Plex, Jellyfin, a streaming app) — added via drag & drop onto the window or Library ▸ Add
// Game…. Both lists persist in UserDefaults; scan() re-reads them every library refresh, so a
// yanked jump drive's games simply drop out of the scan (and return when it's plugged back in)
// without ever touching the saved entries.

// One individually-added game. `bottle` is only set for Windows .exe entries — they launch
// through CrossOver exactly like a scanned bottle game (`wine --bottle {bottle} {exe}` takes
// any unix path, the exe doesn't have to live inside the bottle).
struct CustomGameEntry: Codable, Equatable, Identifiable {
    var path: String
    var bottle: String?

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var isExe: Bool { path.lowercased().hasSuffix(".exe") }
}

struct CustomSource {
    private static let foldersKey = "customScanFolders"
    private static let gamesKey   = "customGameEntries"

    private static let iconCacheDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Marquee/CustomIcons")

    // MARK: - Persisted lists

    static var scanFolders: [String] {
        UserDefaults.standard.stringArray(forKey: foldersKey) ?? []
    }

    static var gameEntries: [CustomGameEntry] {
        guard let data = UserDefaults.standard.data(forKey: gamesKey),
              let entries = try? JSONDecoder().decode([CustomGameEntry].self, from: data)
        else { return [] }
        return entries
    }

    @discardableResult
    static func addScanFolder(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        var folders = scanFolders
        guard !folders.contains(path) else { return false }
        folders.append(path)
        UserDefaults.standard.set(folders, forKey: foldersKey)
        return true
    }

    static func removeScanFolder(_ path: String) {
        UserDefaults.standard.set(scanFolders.filter { $0 != path }, forKey: foldersKey)
    }

    @discardableResult
    static func addGameEntry(_ entry: CustomGameEntry) -> Bool {
        var entries = gameEntries
        guard !entries.contains(where: { $0.path == entry.path }) else { return false }
        entries.append(entry)
        persist(entries)
        return true
    }

    static func removeGameEntry(_ entry: CustomGameEntry) {
        persist(gameEntries.filter { $0.path != entry.path })
    }

    static func updateGameEntry(_ entry: CustomGameEntry) {
        var entries = gameEntries
        guard let idx = entries.firstIndex(where: { $0.path == entry.path }) else { return }
        entries[idx] = entry
        persist(entries)
    }

    private static func persist(_ entries: [CustomGameEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: gamesKey)
        }
    }

    // MARK: - Scan

    static func scan() -> [Game] {
        var games: [Game] = []

        for entry in gameEntries where FileManager.default.fileExists(atPath: entry.path) {
            if entry.isExe {
                if let bottle = entry.bottle ?? defaultBottle() {
                    games.append(exeGame(exePath: entry.path, bottle: bottle))
                }
            } else if entry.path.hasSuffix(".app") {
                if let game = appGame(at: entry.url) { games.append(game) }
            }
        }

        for folder in scanFolders {
            games += scanFolder(URL(fileURLWithPath: folder))
        }
        return games
    }

    // A user-chosen folder is scanned on its own terms — the user pointed at it and said
    // "my games live here", so unlike /Applications there's no category allowlist:
    //   • every .app bundle (up to 2 levels deep, so Games/Mac/Foo.app still hits)
    //   • every loose top-level .exe
    //   • every top-level subfolder containing a Windows game (resolved with the same
    //     bestExecutable heuristic the drive_c/GAMES fallback uses)
    // Windows finds are skipped entirely when CrossOver has no bottles — an entry that can
    // never launch is worse than an absent one.
    private static func scanFolder(_ folder: URL) -> [Game] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDir), isDir.boolValue,
              let entries = try? fm.contentsOfDirectory(
                  at: folder, includingPropertiesForKeys: [.isDirectoryKey],
                  options: [.skipsHiddenFiles])
        else { return [] }

        var games: [Game] = []
        let bottle = defaultBottle()

        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDirectory = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true

            if entry.pathExtension == "app" {
                if let game = appGame(at: entry) { games.append(game) }
            } else if entry.pathExtension.lowercased() == "exe" {
                if let bottle { games.append(exeGame(exePath: entry.path, bottle: bottle)) }
            } else if isDirectory {
                // One level down: a nested .app wins; otherwise treat the folder as a
                // Windows game if it contains a launchable exe.
                let nested = (try? fm.contentsOfDirectory(
                    at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                let nestedApps = nested.filter { $0.pathExtension == "app" }
                if !nestedApps.isEmpty {
                    games += nestedApps.compactMap(appGame)
                } else if let bottle,
                          let exe = GameLauncher.bestExecutable(
                              in: entry, title: prettyTitle(from: entry.lastPathComponent)) {
                    games.append(exeGame(exePath: exe.path, bottle: bottle,
                                          title: prettyTitle(from: entry.lastPathComponent)))
                }
            }
        }
        return games
    }

    // MARK: - Game construction

    private static func appGame(at bundleURL: URL) -> Game? {
        let plist = NSDictionary(contentsOf: bundleURL.appendingPathComponent("Contents/Info.plist"))
        let title = (plist?["CFBundleDisplayName"] as? String)
            ?? (plist?["CFBundleName"] as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
        let iconPath = extractAndCacheIcon(
            appURL: bundleURL, key: plist?["CFBundleIdentifier"] as? String)
        return Game(
            title: title,
            source: .applications(bundleURL: bundleURL),
            metadata: GameMetadata(bundledIconPath: iconPath)
        )
    }

    private static func exeGame(exePath: String, bottle: String, title: String? = nil) -> Game {
        let name = title ?? prettyTitle(
            from: (exePath as NSString).lastPathComponent.replacingOccurrences(of: ".exe", with: ""))
        return Game(title: name, source: .crossOver(bottleName: bottle, exePath: exePath))
    }

    // First bottle alphabetically = the launch default for exes added without an explicit
    // bottle choice (Settings' Added Games list offers a per-entry picker when there's more
    // than one). nil when CrossOver isn't installed or has no bottles.
    static func defaultBottle() -> String? {
        CrossOverSource.availableBottles().first
    }

    // "RuneFactory_5" / "StardewValley" / "half.life.2" → a readable title. Folder/exe names
    // are the only naming signal a custom location has.
    static func prettyTitle(from raw: String) -> String {
        var s = raw
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "-", with: " ")
        var out = ""
        for (i, c) in s.enumerated() {
            if i > 0, c.isUppercase {
                let prev = s[s.index(s.startIndex, offsetBy: i - 1)]
                if prev.isLowercase || prev.isNumber { out.append(" ") }
            }
            out.append(c)
        }
        s = out.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
        return s.isEmpty ? raw : s
    }

    // Same icon-fallback pattern as ApplicationsSource/EpicSource: the bundle's own icon,
    // cached once as a PNG, feeds ArtFetcher's bundledIconPath tier when no Steam match
    // exists — which for a Plex/Jellyfin-style non-game is the common case, and their own
    // icon is exactly the right poster.
    private static func extractAndCacheIcon(appURL: URL, key: String?) -> URL? {
        let name = key ?? appURL.path.replacingOccurrences(of: "/", with: "_")
        let dest = iconCacheDir.appendingPathComponent("\(name).png")
        if FileManager.default.fileExists(atPath: dest.path) { return dest }

        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        guard let tiff = icon.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return nil }

        try? FileManager.default.createDirectory(at: iconCacheDir, withIntermediateDirectories: true)
        guard (try? png.write(to: dest)) != nil else { return nil }
        return dest
    }
}
