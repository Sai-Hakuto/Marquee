import Foundation

struct PlayCoverStoreInfo: Sendable {
    let publisher: String
    let releaseDate: String
    let genre: String
    let about: String
    let artworkURL: URL?
    let screenshots: [URL]
}

// Apple lookup uses the installed bundle ID, avoiding a similarly named but unrelated title.
// Games absent from Apple's catalog may still have a Steam edition; only an exact title match
// is accepted there. Negative results are cached for this process to avoid repeated queries.
actor PlayCoverCatalog {
    static let shared = PlayCoverCatalog()
    private var storeCache: [String: PlayCoverStoreInfo] = [:]
    private var storeMisses: Set<String> = []
    private var steamCache: [String: Int] = [:]
    private var steamMisses: Set<String> = []

    func storeInfo(bundleID: String) async -> PlayCoverStoreInfo? {
        if let cached = storeCache[bundleID] { return cached }
        if storeMisses.contains(bundleID) { return nil }

        var components = URLComponents(string: "https://itunes.apple.com/lookup")!
        components.queryItems = [
            URLQueryItem(name: "bundleId", value: bundleID),
            URLQueryItem(name: "country", value: "us"),
            URLQueryItem(name: "entity", value: "software")
        ]
        guard let url = components.url,
              let (data, response) = try? await URLSession.marquee.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = root["results"] as? [[String: Any]],
              let entry = results.first(where: {
                  ($0["bundleId"] as? String)?.caseInsensitiveCompare(bundleID) == .orderedSame
              }) else {
            storeMisses.insert(bundleID)
            return nil
        }

        let date: String
        if let raw = entry["releaseDate"] as? String,
           let parsed = ISO8601DateFormatter().date(from: raw) {
            date = DateFormatter.localizedString(from: parsed, dateStyle: .medium, timeStyle: .none)
        } else { date = "—" }
        let genres = (entry["genres"] as? [String] ?? []).filter { $0 != "Games" }
        let imageStrings = (entry["screenshotUrls"] as? [String] ?? [])
            + (entry["ipadScreenshotUrls"] as? [String] ?? [])
        let info = PlayCoverStoreInfo(
            publisher: entry["artistName"] as? String ?? "PlayCover",
            releaseDate: date,
            genre: genres.prefix(3).joined(separator: ", "),
            about: (entry["description"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            artworkURL: (entry["artworkUrl512"] as? String).flatMap(URL.init(string:)),
            screenshots: Array(imageStrings.prefix(10).compactMap {
                URL(string: Self.fullSizeScreenshot($0))
            })
        )
        storeCache[bundleID] = info
        return info
    }

    func exactSteamAppID(title: String) async -> Int? {
        let key = Self.normalizedTitle(title)
        guard !key.isEmpty else { return nil }
        if let cached = steamCache[key] { return cached }
        if steamMisses.contains(key) { return nil }

        var components = URLComponents(string: "https://store.steampowered.com/api/storesearch/")!
        components.queryItems = [
            URLQueryItem(name: "term", value: title),
            URLQueryItem(name: "l", value: "english"),
            URLQueryItem(name: "cc", value: "US")
        ]
        guard let url = components.url,
              let (data, response) = try? await URLSession.marquee.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["items"] as? [[String: Any]],
              let match = items.first(where: { Self.normalizedTitle($0["name"] as? String ?? "") == key }),
              let id = match["id"] as? Int else {
            steamMisses.insert(key)
            return nil
        }
        steamCache[key] = id
        return id
    }

    private static func normalizedTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    // Apple's lookup response uses small thumbnail URLs. Request the same image at a
    // higher resolution while keeping its aspect ratio for Marquee's enlarged media view.
    private static func fullSizeScreenshot(_ path: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"/([0-9]+)x([0-9]+)bb\.(png|jpe?g)$"#),
              let match = regex.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
              let widthRange = Range(match.range(at: 1), in: path),
              let heightRange = Range(match.range(at: 2), in: path),
              let extensionRange = Range(match.range(at: 3), in: path),
              let width = Double(path[widthRange]),
              let height = Double(path[heightRange]), width > 0 else { return path }
        let enlargedHeight = Int((height * 1200 / width).rounded())
        let replacement = "/1200x\(enlargedHeight)bb.\(path[extensionRange])"
        return regex.stringByReplacingMatches(in: path,
            range: NSRange(path.startIndex..., in: path), withTemplate: replacement)
    }
}
