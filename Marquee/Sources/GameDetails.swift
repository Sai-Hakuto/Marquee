import Foundation

// The metadata shown on the game Detail page. A mix of online data (Steam store
// appdetails — publisher, release date, genre, players, description) and locally
// computed fields (install location, file size, a fun stable Game ID).
struct GameDetails: Sendable, Equatable {
    var publisher: String
    var releaseDate: String
    var players: String
    var gameID: String
    var fileSize: String
    var location: String
    var genre: String
    var about: String
    var logoURL: URL?     // Steam wordmark logo (stylised title image) when available
    var screenshots: [URL]    // Steam store screenshots (thumbnails) — media rail
    var trailerURL: URL?      // first Steam movie (mp4) — muted autoplay trailer

    static func placeholder(for game: Game) -> GameDetails {
        GameDetails(
            publisher: game.sourceBadgeTitle,
            releaseDate: "—",
            players: "—",
            gameID: GameDetailsFetcher.funGameID(for: game),
            fileSize: "Calculating…",
            location: "—",
            genre: "—",
            about: "Loading details…",
            logoURL: nil,
            screenshots: [],
            trailerURL: nil
        )
    }
}

actor GameDetailsFetcher {
    static let shared = GameDetailsFetcher()
    private init() {}

    private var cache: [UUID: GameDetails] = [:]
    // Games whose Steam lookup was skipped/failed while offline. Their cached entries are
    // placeholders, not truth — invalidated on reconnect (see invalidateOfflineMisses) so the
    // next Detail open fetches for real instead of showing dashes forever.
    private var offlineMisses: Set<UUID> = []

    private static let steamAppsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Steam/steamapps")
    private static let bottlesDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CrossOver/Bottles")

    // MARK: - Public

    func details(for game: Game) async -> GameDetails {
        if let hit = cache[game.id] { return hit }

        // Local fields first — always available, fast.
        let (locationDisplay, fsURL) = Self.resolveLocation(for: game)
        let gameID = Self.funGameID(for: game)

        // Online fields from the Steam store (no API key). Offline, skip straight to the
        // local-only placeholder rather than burning three doomed store-search attempts.
        let online = NetworkMonitor.isOnlineNow
        let apple: PlayCoverStoreInfo?
        if online, case .playCover(let bundleID, _) = game.source {
            apple = await PlayCoverCatalog.shared.storeInfo(bundleID: bundleID)
        } else { apple = nil }
        let steam = online && apple == nil ? await fetchSteam(for: game) : nil

        // File size from disk (can be slow on big installs — already off-main here).
        let fileSize = fsURL.map { Self.formattedDirectorySize($0) } ?? "—"

        let details = GameDetails(
            publisher: apple.map { "\($0.publisher) (via PlayCover)" }
                ?? steam?.publisher ?? game.sourceBadgeTitle,
            releaseDate: apple?.releaseDate ?? steam?.releaseDate ?? "—",
            players: steam?.players ?? "—",
            gameID: gameID,
            fileSize: fileSize,
            location: locationDisplay,
            genre: apple?.genre.nilIfEmpty ?? steam?.genre ?? (game.metadata.genre ?? "—"),
            about: apple?.about.nilIfEmpty ?? steam?.about ?? (online
                ? "No catalog description available for this title."
                : "You're offline — details for this game will load once you reconnect."),
            logoURL: steam?.logoURL,
            screenshots: apple?.screenshots ?? steam?.screenshots ?? [],
            trailerURL: steam?.trailerURL
        )
        cache[game.id] = details
        if apple == nil && steam == nil && !online { offlineMisses.insert(game.id) }
        return details
    }

    // Called (via MarqueeApp's NetworkMonitor.onReconnect wiring) when connectivity returns:
    // drops every entry that was built without network so its next open re-fetches for real.
    func invalidateOfflineMisses() {
        for id in offlineMisses { cache.removeValue(forKey: id) }
        offlineMisses.removeAll()
    }

    // MARK: - Steam store appdetails

    private struct SteamInfo {
        var publisher: String
        var releaseDate: String
        var players: String
        var genre: String
        var about: String
        var logoURL: URL?
        var screenshots: [URL]
        var trailerURL: URL?
    }

    private func fetchSteam(for game: Game) async -> SteamInfo? {
        let appId: Int?
        switch game.source {
        case .steam(let id):
            appId = id
        case .playCover:
            let override = UserDefaults.standard.integer(forKey: "coverSteamId_\(game.id.uuidString)")
            appId = override > 0 ? override
                : await PlayCoverCatalog.shared.exactSteamAppID(title: game.title)
        default:
            // Honour a Fix-Cover Steam App ID override, else resolve via store search.
            let override = UserDefaults.standard.integer(forKey: "coverSteamId_\(game.id.uuidString)")
            appId = override > 0 ? override : await resolveSteamAppId(title: game.title)
        }
        guard let id = appId else { return nil }

        guard let url = URL(string: "https://store.steampowered.com/api/appdetails?appids=\(id)&l=english"),
              let (data, _) = try? await URLSession.marquee.data(from: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root["\(id)"] as? [String: Any],
              (entry["success"] as? Bool) == true,
              let d = entry["data"] as? [String: Any] else { return nil }

        let publishers = (d["publishers"] as? [String]) ?? []
        let developers = (d["developers"] as? [String]) ?? []
        let pubName = publishers.first ?? developers.first ?? game.sourceBadgeTitle
        let publisher = "\(pubName) (via \(game.sourceBadgeTitle))"

        let releaseDate = ((d["release_date"] as? [String: Any])?["date"] as? String)?
            .trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "—"

        let genres = (d["genres"] as? [[String: Any]])?.compactMap { $0["description"] as? String } ?? []
        let genre = genres.isEmpty ? "—" : genres.prefix(3).joined(separator: ", ")

        let categories = (d["categories"] as? [[String: Any]])?.compactMap { $0["description"] as? String } ?? []
        let players = derivePlayers(from: categories)

        let about = (d["short_description"] as? String)?.nilIfEmpty
            ?? (d["about_the_game"] as? String)?.strippingHTML.nilIfEmpty
            ?? "No description available for this title."

        let logoURL = URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(id)/logo.png")

        // Store screenshots (use the thumbnail variant for the rail) + first trailer (mp4).
        let screenshots = ((d["screenshots"] as? [[String: Any]]) ?? [])
            .compactMap { ($0["path_thumbnail"] as? String).flatMap(URL.init(string:)) }

        // Steam's movie payload: prefer HLS (`.m3u8`, which AVPlayer streams natively) — the newer
        // format. Fall back to the legacy `mp4:{max,480}` for apps that still carry it. (DASH
        // `.mpd` is skipped: AVFoundation can't play it out of the box.)
        let movies = (d["movies"] as? [[String: Any]]) ?? []
        let trailerURL: URL? = movies.first.flatMap { movie -> URL? in
            let mp4 = movie["mp4"] as? [String: Any]
            let candidate = (movie["hls_h264"] as? String)
                ?? (mp4?["max"] as? String) ?? (mp4?["480"] as? String)
            // Steam serves some of these over http; upgrade so ATS doesn't block them.
            return candidate.map { $0.replacingOccurrences(of: "http://", with: "https://") }
                            .flatMap(URL.init(string:))
        }

        return SteamInfo(publisher: publisher, releaseDate: releaseDate, players: players,
                         genre: genre, about: about, logoURL: logoURL,
                         screenshots: screenshots, trailerURL: trailerURL)
    }

    private func derivePlayers(from categories: [String]) -> String {
        let lowered = categories.map { $0.lowercased() }
        var tags: [String] = []
        if lowered.contains(where: { $0.contains("single-player") }) { tags.append("Single-player") }
        if lowered.contains(where: { $0.contains("co-op") }) { tags.append("Co-op") }
        else if lowered.contains(where: { $0.contains("multi-player") || $0.contains("pvp") }) { tags.append("Multiplayer") }
        return tags.isEmpty ? "—" : tags.joined(separator: " · ")
    }

    // Resolve a Steam appId for a non-Steam title via the public store search.
    private func resolveSteamAppId(title: String) async -> Int? {
        let override = UserDefaults.standard.string(forKey: "coverSearch_\(title)")  // unused; kept simple
        _ = override
        let words = title.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }

        let attempts = [words, Array(words.prefix(3)), Array(words.prefix(2))]
            .map { $0.joined(separator: " ") }
        for term in attempts {
            guard let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://store.steampowered.com/api/storesearch/?term=\(encoded)&l=english&cc=US"),
                  let (data, _) = try? await URLSession.marquee.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]],
                  let first = items.first,
                  let id = first["id"] as? Int else { continue }
            return id
        }
        return nil
    }

    // MARK: - Local field helpers

    // Location + the directory to measure for file size. For CrossOver we resolve the
    // GAME folder (climbing up from the exe), never the whole bottle — many users pile
    // dozens of games into one bottle, so bottle size is meaningless.
    static func debugLocationSize(for game: Game) -> (location: String, size: String) {
        let (loc, fsURL) = resolveLocation(for: game)
        return (loc, fsURL.map { formattedDirectorySize($0) } ?? "—")
    }

    static func resolveLocation(for game: Game) -> (display: String, fsURL: URL?) {
        switch game.source {
        case .steam(let appId):
            if let dir = steamInstallDir(appId: appId) { return (dir.path, dir) }
            return ("Steam Library · app \(appId)", nil)
        case .crossOver(let bottle, let exePath):
            let bottleURL = bottlesDir.appendingPathComponent(bottle)
            if let dir = crossOverGameDir(bottleURL: bottleURL, exePath: exePath, title: game.title) {
                return (dir.path, dir)
            }
            // Unknown game folder — show the bottle but DON'T measure it (would be the
            // size of every game in that bottle).
            return ("\(bottleURL.path) (bottle — game folder not found)", nil)
        case .applications(let url), .gog(_, let url), .playCover(_, let url):
            return (url.path, FileManager.default.fileExists(atPath: url.path) ? url : nil)
        case .epic(let appName, _):
            return ("Epic Games · \(appName)", nil)
        }
    }

    // Dirs that hold game folders / are not themselves a game (never measure these).
    private static let containerDirs: Set<String> = [
        "program files", "program files (x86)", "games", "gog games",
        "common", "steamapps", "drive_c", "epic games", "origin games", "ubisoft"
    ]
    // Engine binary subfolders — when the exe lives in one of these, the real game root
    // is a few levels up (e.g. CoolGame/Binaries/Win64/CoolGame-Shipping.exe).
    private static let binarySubdirs: Set<String> = [
        "binaries", "win64", "win32", "win", "x64", "x86", "bin", "retail", "shipping", "release"
    ]

    // CrossOver stores either a real .exe path OR (often) just the game folder, AND
    // sometimes nothing. Resolve the GAME folder to measure / show.
    static func crossOverGameDir(bottleURL: URL, exePath: String, title: String) -> URL? {
        if !exePath.isEmpty {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: exePath, isDirectory: &isDir) {
                let url = URL(fileURLWithPath: exePath)
                let startDir = isDir.boolValue ? url : url.deletingLastPathComponent()
                return gameFolder(from: startDir, bottleURL: bottleURL)
            }
        }
        return searchGameDirByTitle(bottleURL: bottleURL, title: title)
    }

    // Default to the exe's own folder (the game's files are usually right there).
    // Only climb OUT of engine binary subfolders (Binaries/Win64/…). Never return a
    // container dir or the bottle/drive_c.
    static func gameFolder(from startDir: URL, bottleURL: URL) -> URL {
        let driveC = bottleURL.appendingPathComponent("drive_c").path
        var dir = startDir
        var steps = 0
        while steps < 6, binarySubdirs.contains(dir.lastPathComponent.lowercased()) {
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path || parent.path == driveC || parent.path == bottleURL.path { break }
            dir = parent
            steps += 1
        }
        if dir.path == driveC || dir.path == bottleURL.path
            || containerDirs.contains(dir.lastPathComponent.lowercased()) {
            return startDir
        }
        return dir
    }

    // Fallback for games with no exe path: match a folder by title. Searches the usual
    // Windows install roots AND any non-system top-level folder in drive_c (games are
    // often dropped into custom folders like drive_c/voices38/Hi-Fi RUSH).
    static func searchGameDirByTitle(bottleURL: URL, title: String) -> URL? {
        let driveC = bottleURL.appendingPathComponent("drive_c")
        let target = normalize(title)
        guard target.count >= 3 else { return nil }

        let systemDirs: Set<String> = [
            "windows", "programdata", "users", "$recycle.bin", "msocache", "perflogs",
            "system volume information", "windows.old", "intel", "amd", "nvidia"
        ]
        var roots = ["Program Files", "Program Files (x86)", "GOG Games", "Games",
                     "Program Files (x86)/Steam/steamapps/common",
                     "Program Files/Steam/steamapps/common"]
            .map { driveC.appendingPathComponent($0) }
        if let top = try? FileManager.default.contentsOfDirectory(
            at: driveC, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
            for u in top where isDir(u) && !systemDirs.contains(u.lastPathComponent.lowercased()) {
                roots.append(u)
            }
        }

        func childDirs(_ root: URL) -> [URL] {
            guard let e = try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]) else { return [] }
            return e.filter { isDir($0) }
        }

        // Pass 1: exact normalized match anywhere (most reliable).
        for root in roots {
            if let hit = childDirs(root).first(where: { normalize($0.lastPathComponent) == target }) {
                return hit
            }
        }
        // Pass 2: substring match (handles "Hi-Fi RUSH" folder vs "Hi-Fi-RUSH" title etc.).
        for root in roots {
            if let hit = childDirs(root).first(where: {
                let n = normalize($0.lastPathComponent)
                return n.count >= 4 && (n.contains(target) || target.contains(n))
            }) { return hit }
        }
        return nil
    }

    private static func isDir(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init).joined()
    }

    private static func steamInstallDir(appId: Int) -> URL? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: Self.steamAppsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return nil }
        let acf = Self.steamAppsDir.appendingPathComponent("appmanifest_\(appId).acf")
        let target = files.contains(acf) ? acf : nil
        guard let url = target, let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        for line in content.components(separatedBy: .newlines) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("\"installdir\"") {
                let parts = t.components(separatedBy: "\"")
                if parts.count >= 4 {
                    let dir = Self.steamAppsDir.appendingPathComponent("common/\(parts[3])")
                    return FileManager.default.fileExists(atPath: dir.path) ? dir : nil
                }
            }
        }
        return nil
    }

    // A fun, stable, made-up catalog ID derived from the title initials + a hash of
    // the game's stable UUID. e.g. "Stardew Valley" → "SV-GID-417".
    static func funGameID(for game: Game) -> String {
        let words = game.title.uppercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        var initials = words.prefix(3).compactMap { $0.first }.map(String.init).joined()
        if initials.count < 2 {
            initials = String(game.title.uppercased().filter { $0.isLetter }.prefix(3))
        }
        if initials.isEmpty { initials = "GME" }
        let hex = game.id.uuidString.replacingOccurrences(of: "-", with: "").prefix(4)
        let n = (UInt(hex, radix: 16) ?? 0) % 999 + 1
        return "\(initials)-GID-\(String(format: "%03d", n))"
    }

    private static func formattedDirectorySize(_ url: URL) -> String {
        var total: Int64 = 0
        if let en = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
            options: [.skipsHiddenFiles]) {
            for case let f as URL in en {
                let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
                total += Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
            }
        }
        if total == 0 {
            // url itself may be a single file (an .app bundle or exe)
            let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            total = Int64(v?.totalFileAllocatedSize ?? 0)
        }
        guard total > 0 else { return "—" }
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useMB, .useGB]
        fmt.countStyle = .file
        return fmt.string(fromByteCount: total)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
    var strippingHTML: String {
        replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
