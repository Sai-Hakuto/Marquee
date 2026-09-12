import Foundation
import ImageIO

actor ArtFetcher {
    static let shared = ArtFetcher()
    private init() {}
    private var playCoverMigration: [UUID: Task<Void, Never>] = [:]

    private let userArtDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Marquee/Art")

    func fetch(for game: Game) async -> URL? {
        await preparePlayCoverArt(for: game)
        if let cached = await ArtCache.shared.cachedURL(for: game.id) { return cached }

        // User-placed files always win regardless of preference
        if let url = await checkUserOwnArt(for: game) { return url }

        let pref = UserDefaults.standard.string(forKey: "artSourcePreference") ?? "automatic"
        guard pref != "own" else { return nil }

        // Offline: every remaining tier needs the network. Show the bundled icon (if the scanner
        // extracted one) WITHOUT caching it — the cache is the permanent record, and fetch()'s
        // first line treats a cache hit as final, so baking a low-res icon in here would block
        // the real art from ever being fetched once connectivity returns.
        // AppState.retryMissingArt (fired on reconnect) retries exactly the games whose art
        // never made it into the cache.
        guard NetworkMonitor.isOnlineNow else {
            return game.metadata.bundledIconPath
        }

        // User-provided override via "Fix Cover": Steam App ID takes priority over search term
        let overrideKey = game.id.uuidString
        let overrideAppId  = UserDefaults.standard.integer(forKey: "coverSteamId_\(overrideKey)")
        let overrideTerm   = UserDefaults.standard.string(forKey: "coverSearch_\(overrideKey)")
        let overrideDirect = UserDefaults.standard.string(forKey: "coverDirectURL_\(overrideKey)")

        if let urlStr = overrideDirect, let url = URL(string: urlStr) {
            return await download(from: url, gameId: game.id)
        }
        if overrideAppId > 0 {
            return await fetchSteamCDN(appId: overrideAppId, gameId: game.id)
        }

        switch game.source {
        case .steam(let appId):
            return await fetchSteamCDN(appId: appId, gameId: game.id)

        case .playCover(let bundleID, _):
            // Apple identifies this exact installed iOS app by bundle ID. Steam art is only a
            // fallback for sideloaded titles absent from Apple's catalog.
            if let artwork = await PlayCoverCatalog.shared.storeInfo(bundleID: bundleID)?.artworkURL,
               let art = await download(from: artwork, gameId: game.id) { return art }
            if await PlayCoverCatalog.shared.storeInfo(bundleID: bundleID) == nil,
               let appId = await PlayCoverCatalog.shared.exactSteamAppID(title: game.title),
               let art = await fetchSteamCDN(appId: appId, gameId: game.id) { return art }
            if let icon = game.metadata.bundledIconPath {
                return await cacheLocalFile(at: icon, gameId: game.id)
            }
            return nil

        // CrossOver/Epic/GOG/Mac games are all frequently ALSO on Steam (with much better cover
        // art than a bundle's own .icns), so all four try the store search first and only fall
        // back to the bundled icon extracted at scan time when there's no Steam match.
        //
        // Bottled-Steam CrossOver games (decisions.md #78 — a real Windows Steam client installed
        // INSIDE the bottle) are a special case: `viaLauncherAppId` is the EXACT app ID read
        // straight from that Steam install's own `.acf` manifest, not a guess — skip the fuzzy
        // title search entirely and go straight to the CDN with it. Titles like "Escape the Game"
        // are too generic for the public store search to resolve reliably (or a "close enough"
        // match doesn't have `library_hero.jpg` even when it exists), which was silently pushing
        // these games all the way down to the bundled-icon fallback despite the real Steam art
        // being one known ID away. See decisions.md #111.
        case .crossOver, .epic, .gog, .applications:
            if let knownAppId = game.metadata.viaLauncherAppId {
                return await fetchSteamCDN(appId: knownAppId, gameId: game.id)
            }
            let searchTitle = overrideTerm ?? game.title
            if let url = await fetchViaSteamSearch(title: searchTitle, gameId: game.id) { return url }
            if let iconPath = game.metadata.bundledIconPath,
               let url = await cacheLocalFile(at: iconPath, gameId: game.id) { return url }
            if pref == "steamGridDB" {
                return await fetchSteamGridDB(title: searchTitle, gameId: game.id)
            }
            return nil
        }
    }

    // MARK: - Horizontal header art (Steam header.jpg) for List view

    // Returns a cached landscape header image (Steam `header.jpg`, 460×215). For Steam games
    // the app ID is known; for others we honour a Fix-Cover Steam ID override, else resolve
    // one via the public store search. Returns nil when no Steam match exists (caller falls
    // back to the portrait cover).
    func fetchHeader(for game: Game) async -> URL? {
        await preparePlayCoverArt(for: game)
        if let cached = await ArtCache.shared.cachedHeaderURL(for: game.id) { return cached }
        guard NetworkMonitor.isOnlineNow else { return nil }   // caller falls back to the cover

        let key = game.id.uuidString
        let ud = UserDefaults.standard

        // "Fix Banner Art" overrides take priority — they're independent of the cover so
        // fixing one never clobbers the other. A direct (DuckDuckGo) banner URL wins outright.
        if let direct = ud.string(forKey: "bannerDirectURL_\(key)"), let url = URL(string: direct) {
            return await downloadHeader(from: url, gameId: game.id)
        }
        let bannerAppId  = ud.integer(forKey: "bannerSteamId_\(key)")
        let bannerSearch = ud.string(forKey: "bannerSearch_\(key)")

        // Cover overrides remain a fallback, so "Fix Cover Art" still updates the list banner
        // when no banner-specific override exists.
        let coverAppId  = ud.integer(forKey: "coverSteamId_\(key)")
        let coverSearch = ud.string(forKey: "coverSearch_\(key)")

        let appId: Int?
        if bannerAppId > 0 {
            appId = bannerAppId
        } else if let term = bannerSearch, !term.isEmpty {
            appId = await resolveSteamAppId(title: term)
        } else if coverAppId > 0 {
            appId = coverAppId
        } else {
            switch game.source {
            case .steam(let id): appId = id
            case .playCover(let bundleID, _):
                if await PlayCoverCatalog.shared.storeInfo(bundleID: bundleID) == nil {
                    appId = await PlayCoverCatalog.shared.exactSteamAppID(title: coverSearch ?? game.title)
                } else { appId = nil }
            default:
                if let knownAppId = game.metadata.viaLauncherAppId {
                    appId = knownAppId
                } else {
                    appId = await resolveSteamAppId(title: coverSearch ?? game.title)
                }
            }
        }
        if let id = appId,
           let url = URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(id)/header.jpg"),
           let art = await downloadHeader(from: url, gameId: game.id) { return art }
        return nil
    }

    // MARK: - Wide hero art (Steam library_hero.jpg) for the carousel backdrop

    // Returns a cached wide hero image (Steam `library_hero.jpg`, ~1920×620) used as a
    // blurred backdrop behind the carousel. Resolves the Steam app ID the same way the
    // portrait cover does (Steam source → Fix-Cover override → store search). Returns nil
    // when no Steam match exists (caller falls back to the theme background).
    func fetchHero(for game: Game) async -> URL? {
        await preparePlayCoverArt(for: game)
        if case .playCover(let bundleID, _) = game.source,
           UserDefaults.standard.integer(forKey: "coverSteamId_\(game.id.uuidString)") == 0,
           await PlayCoverCatalog.shared.storeInfo(bundleID: bundleID) != nil { return nil }
        if let cached = await ArtCache.shared.cachedHeroURL(for: game.id) {
            // Older PlayCover builds could cache a portrait App Store screenshot here.
            // Never stretch an icon or phone screenshot across the whole window.
            if case .playCover = game.source {
                return Self.isWideHero(cached) ? cached : nil
            }
            return cached
        }
        guard NetworkMonitor.isOnlineNow else { return nil }   // caller shows the theme backdrop

        let key = game.id.uuidString
        let ud = UserDefaults.standard
        let coverAppId  = ud.integer(forKey: "coverSteamId_\(key)")
        let coverSearch = ud.string(forKey: "coverSearch_\(key)")

        let appId: Int?
        if coverAppId > 0 {
            appId = coverAppId
        } else {
            switch game.source {
            case .steam(let id): appId = id
            case .playCover:
                appId = await PlayCoverCatalog.shared.exactSteamAppID(title: coverSearch ?? game.title)
            default:
                if let knownAppId = game.metadata.viaLauncherAppId {
                    appId = knownAppId
                } else {
                    appId = await resolveSteamAppId(title: coverSearch ?? game.title)
                }
            }
        }
        if let id = appId,
           let url = URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(id)/library_hero.jpg"),
           let art = await downloadHero(from: url, gameId: game.id) { return art }
        return nil
    }

    private static func isWideHero(_ url: URL) -> Bool {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        return width >= 1200 && Double(width) / Double(height) >= 1.4
    }

    private func preparePlayCoverArt(for game: Game) async {
        guard case .playCover = game.source else { return }
        let key = "playCoverAppleArtV2_\(game.id.uuidString)"
        if let task = playCoverMigration[game.id] { await task.value; return }
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        let task = Task {
            await ArtCache.shared.remove(for: game.id)
            UserDefaults.standard.set(true, forKey: key)
        }
        playCoverMigration[game.id] = task
        await task.value
        playCoverMigration.removeValue(forKey: game.id)
    }

    private func downloadHero(from url: URL, gameId: UUID) async -> URL? {
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.marquee.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else { return nil }
        try? await ArtCache.shared.saveHero(data, for: gameId)
        return await ArtCache.shared.cachedHeroURL(for: gameId)
    }

    // Resolve a Steam app ID from a free-text title via the public store search.
    private func resolveSteamAppId(title: String) async -> Int? {
        let words = searchWords(from: title)
        guard !words.isEmpty else { return nil }
        let attempts = [words, Array(words.prefix(3)), Array(words.prefix(2))]
            .filter { !$0.isEmpty }
            .map { $0.joined(separator: " ") }
        for term in attempts {
            guard let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://store.steampowered.com/api/storesearch/?term=\(encoded)&l=english&cc=US"),
                  let (data, _) = try? await URLSession.marquee.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]] else { continue }
            if let match = bestTitleMatch(searchWords: words, in: items),
               let appId = match["id"] as? Int { return appId }
        }
        return nil
    }

    private func downloadHeader(from url: URL, gameId: UUID) async -> URL? {
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.marquee.data(for: req),
              let http = response as? HTTPURLResponse, http.statusCode == 200, !data.isEmpty else { return nil }
        try? await ArtCache.shared.saveHeader(data, for: gameId)
        return await ArtCache.shared.cachedHeaderURL(for: gameId)
    }

    // MARK: - User-placed art: ~/Library/Application Support/Marquee/Art/{title}.jpg/png

    private func checkUserOwnArt(for game: Game) async -> URL? {
        let slug = game.title
        for ext in ["jpg", "jpeg", "png"] {
            let candidate = userArtDir.appendingPathComponent("\(slug).\(ext)")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return await cacheLocalFile(at: candidate, gameId: game.id)
            }
        }
        return nil
    }

    // MARK: - Steam CDN (no auth, portrait cover art)

    private func fetchSteamCDN(appId: Int, gameId: UUID) async -> URL? {
        let portrait = "https://cdn.akamai.steamstatic.com/steam/apps/\(appId)/library_600x900.jpg"
        if let url = URL(string: portrait), let result = await download(from: url, gameId: gameId) { return result }
        guard let url = URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(appId)/header.jpg") else { return nil }
        return await download(from: url, gameId: gameId)
    }

    // MARK: - Steam store search (public endpoint, no API key)

    private func fetchViaSteamSearch(title: String, gameId: UUID) async -> URL? {
        let words = searchWords(from: title)
        guard !words.isEmpty else { return nil }

        // Try full title, then first 3 words, then first 2 — stops at first good match
        let attempts = [words, Array(words.prefix(3)), Array(words.prefix(2))]
            .filter { !$0.isEmpty }
            .map { $0.joined(separator: " ") }

        for term in attempts {
            guard let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://store.steampowered.com/api/storesearch/?term=\(encoded)&l=english&cc=US"),
                  let (data, _) = try? await URLSession.marquee.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]] else { continue }

            if let match = bestTitleMatch(searchWords: words, in: items),
               let appId = match["id"] as? Int {
                return await fetchSteamCDN(appId: appId, gameId: gameId)
            }
        }
        return nil
    }

    // Tokenise and clean a title into searchable words (strips punctuation, handles CamelCase)
    private func searchWords(from title: String) -> [String] {
        var s = title.lowercased()
        // Insert space before a digit that follows a letter ("Subnautica2" → "subnautica 2")
        var spaced = ""
        for (i, c) in s.enumerated() {
            if i > 0 && c.isNumber && s[s.index(s.startIndex, offsetBy: i - 1)].isLetter { spaced += " " }
            spaced.append(c)
        }
        s = spaced
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: ".", with: "")
            .replacingOccurrences(of: "-", with: " ")
        return s.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
    }

    // Score each search result by word-overlap with the search words; return best if any match
    private func bestTitleMatch(searchWords words: [String], in items: [[String: Any]]) -> [String: Any]? {
        var best: (item: [String: Any], score: Int)? = nil
        for item in items {
            guard let name = item["name"] as? String else { continue }
            let resultWords = searchWords(from: name)
            // Count search words that appear (prefix-match) in result words
            let matched = words.filter { sw in resultWords.contains { $0.hasPrefix(sw) || sw.hasPrefix($0) } }.count
            guard matched > 0 else { continue }
            // Penalise results with many extra words (reduces false positives from sequel games)
            let score = matched * 10 - max(0, resultWords.count - words.count)
            if best == nil || score > best!.score { best = (item, score) }
        }
        return best?.item
    }

    // MARK: - SteamGridDB (opt-in, user provides API key via onboarding)

    private func fetchSteamGridDB(title: String, gameId: UUID) async -> URL? {
        guard let apiKey = UserDefaults.standard.string(forKey: "steamgriddb_api_key"),
              !apiKey.isEmpty else { return nil }

        let encoded = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? title
        guard let searchURL = URL(string: "https://www.steamgriddb.com/api/v2/search/autocomplete/\(encoded)") else { return nil }
        var req = URLRequest(url: searchURL)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        guard let (data, _) = try? await URLSession.marquee.data(for: req),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["data"] as? [[String: Any]],
              let dbId = results.first?["id"] as? Int else { return nil }

        guard let gridURL = URL(string: "https://www.steamgriddb.com/api/v2/grids/game/\(dbId)?dimensions=600x900") else { return nil }
        var gridReq = URLRequest(url: gridURL)
        gridReq.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        guard let (gridData, _) = try? await URLSession.marquee.data(for: gridReq),
              let gridJson = try? JSONSerialization.jsonObject(with: gridData) as? [String: Any],
              let grids = gridJson["data"] as? [[String: Any]],
              let artStr = grids.first?["url"] as? String,
              let artURL = URL(string: artStr) else { return nil }

        return await download(from: artURL, gameId: gameId)
    }

    // MARK: - Helpers

    // Not private: also used directly by AppState.applyCustomCover for user-uploaded files
    // (Fix Cover "Choose File…"), which skip the network-fetch paths entirely.
    func cacheLocalFile(at url: URL, gameId: UUID) async -> URL? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? await ArtCache.shared.save(data, for: gameId)
        return await ArtCache.shared.localPath(for: gameId)
    }

    // Same idea for the landscape header/banner (AppState.applyCustomBanner).
    func cacheLocalHeaderFile(at url: URL, gameId: UUID) async -> URL? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        try? await ArtCache.shared.saveHeader(data, for: gameId)
        return await ArtCache.shared.cachedHeaderURL(for: gameId)
    }

    private func download(from url: URL, gameId: UUID) async -> URL? {
        // Some image CDNs (Amazon, Epic, etc. surfaced by web search) reject the
        // default URLSession agent; present a browser UA so direct URLs resolve.
        var req = URLRequest(url: url)
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
                     forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.marquee.data(for: req),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              !data.isEmpty else { return nil }
        try? await ArtCache.shared.save(data, for: gameId)
        return await ArtCache.shared.localPath(for: gameId)
    }
}
