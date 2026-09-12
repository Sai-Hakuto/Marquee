import Foundation

struct IPAEntry: Identifiable, Hashable {
    let id: String
    let name: String
    let bundleID: String
    let developer: String
    let summary: String
    let iconURL: URL?
    let screenshots: [URL]
    let source: String
    var category: String
    var genre: String
    var gameGenres: [String]
    let versions: [IPAVersion]

    var latest: IPAVersion? { versions.first }
}

struct IPAVersion: Hashable, Identifiable {
    let version: String
    let date: String
    let size: Int64?
    let url: URL
    var id: String { url.absoluteString }
}

enum IPACatalog {
    private struct Feed: Decodable { let apps: [App] }
    private struct App: Decodable {
        let name: String?
        let bundleIdentifier: String?
        let identifier: String?
        let developerName: String?
        let developer: String?
        let localizedDescription: String?
        let description: String?
        let iconURL: String?
        let screenshots: [String]?
        let subtitle: String?
        let versions: [Version]?
    }
    private struct Version: Decodable {
        let version: String?
        let date: String?
        let timestamp: String?
        let downloadURL: String?
        let url: String?
        let size: Int64?
    }

    // Public catalog files used by the two library websites. Keeping the endpoints explicit
    // makes a failed or changed source visible instead of silently displaying stale results.
    private static let sources: [(name: String, category: String, url: String)] = [
        ("iPASTORE", "Games", "https://repo.ipastore.me/games.json"),
        ("iPASTORE", "Apps", "https://repo.ipastore.me/apps.json"),
        ("iPASTORE", "Mods", "https://repo.ipastore.me/mods.json"),
        ("CyPwn", "Unsorted", "https://ipa.cypwn.xyz/cypwn_altstore.json")
    ]

    static func load() async -> (entries: [IPAEntry], failures: [String]) {
        var entries: [IPAEntry] = []
        var failures: [String] = []
        for source in sources {
            do {
                entries += try await fetch(source)
            } catch {
                failures.append("\(source.name) \(source.category): \(error.localizedDescription)")
            }
        }
        return (entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, failures)
    }

    private static func fetch(_ source: (name: String, category: String, url: String)) async throws -> [IPAEntry] {
        var request = URLRequest(url: URL(string: source.url)!)
        request.setValue("Mozilla/5.0 Marquee", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 25
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Feed.self, from: data).apps.compactMap { app in
            guard let name = app.name, !name.isEmpty,
                  let bundleID = app.bundleIdentifier ?? app.identifier, !bundleID.isEmpty else { return nil }
            let versions = (app.versions ?? []).compactMap { version -> IPAVersion? in
                guard let rawURL = version.downloadURL ?? version.url,
                      let url = URL(string: rawURL), url.scheme == "https",
                      url.pathExtension.lowercased() == "ipa" else { return nil }
                return IPAVersion(version: version.version ?? "Unknown",
                                  date: version.timestamp ?? version.date ?? "",
                                  size: version.size, url: url)
            }.sorted { $0.date > $1.date }
            guard !versions.isEmpty else { return nil }
            let genre = app.subtitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let category: String
            if source.category == "Mods" || source.category == "Unsorted" {
                category = source.category
            } else {
                // The repo's games.json includes non-games, while apps.json also includes
                // games. The App Store genre attached to each entry is the better signal.
                category = genre.localizedCaseInsensitiveCompare("Games") == .orderedSame ? "Games" : "Apps"
            }
            return IPAEntry(
                id: "\(source.name)|\(source.category)|\(bundleID)|\(name)|\(versions[0].url.absoluteString)", name: name,
                bundleID: bundleID, developer: app.developer ?? app.developerName ?? "Unknown developer",
                summary: app.localizedDescription ?? app.description ?? "",
                iconURL: app.iconURL.flatMap(URL.init(string:)),
                screenshots: (app.screenshots ?? []).compactMap(URL.init(string:)),
                source: source.name,
                category: category,
                genre: genre.isEmpty ? category : genre,
                gameGenres: [],
                versions: versions
            )
        }
    }
}
