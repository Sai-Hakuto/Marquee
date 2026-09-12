import Foundation

/// Optional App Store metadata, matched by exact bundle identifier. The source
/// catalogs remain usable if a title is no longer listed in the App Store.
enum IPAAppleGenres {
    struct Metadata: Codable {
        let primaryGenre: String?
        let gameGenres: [String]
    }

    private struct Lookup: Decodable { let results: [App] }
    private struct App: Decodable {
        let bundleId: String
        let primaryGenreName: String?
        let genres: [String]?
        let genreIds: [String]?
    }
    private struct Cache: Codable {
        let fetchedAt: Date
        let values: [String: Metadata]
    }

    private static var cacheURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Marquee", isDirectory: true)
            .appendingPathComponent("apple-genres.json")
    }

    static func cached() -> [String: Metadata] {
        guard let cacheURL,
              let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(Cache.self, from: data),
              Date().timeIntervalSince(cache.fetchedAt) < 30 * 24 * 60 * 60 else { return [:] }
        return cache.values
    }

    static func apply(_ metadata: [String: Metadata], to entries: [IPAEntry]) -> [IPAEntry] {
        entries.map { original in
            var entry = original
            guard let match = metadata[entry.bundleID.lowercased()] else { return entry }
            if entry.category == "Games" { entry.gameGenres = match.gameGenres }
            if entry.source == "CyPwn", let genre = match.primaryGenre {
                entry.category = genre == "Games" ? "Games" : "Apps"
                entry.genre = genre
                entry.gameGenres = genre == "Games" ? match.gameGenres : []
            }
            return entry
        }
    }

    static func resolve(for entries: [IPAEntry], startingWith cachedValues: [String: Metadata]) async -> [String: Metadata] {
        let bundleIDs = Array(Set(entries.filter { $0.category == "Games" || $0.source == "CyPwn" }
            .map { $0.bundleID.lowercased() })).sorted()
        var values = cachedValues
        let missing = bundleIDs.filter { values[$0] == nil }
        guard !missing.isEmpty else { return values }

        // The lookup endpoint accepts many bundle IDs. The present catalog fits
        // into fewer than twenty batched requests, Apple's approximate minute limit.
        for start in stride(from: 0, to: missing.count, by: 100) {
            let batch = Array(missing[start..<min(start + 100, missing.count)])
            guard var components = URLComponents(string: "https://itunes.apple.com/lookup") else { continue }
            components.queryItems = [
                URLQueryItem(name: "bundleId", value: batch.joined(separator: ",")),
                URLQueryItem(name: "country", value: "us")
            ]
            guard let url = components.url else { continue }
            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 20
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { continue }
                let apps = try JSONDecoder().decode(Lookup.self, from: data).results
                let requested = Set(batch)
                for id in batch { values[id] = Metadata(primaryGenre: nil, gameGenres: []) }
                for app in apps {
                    let id = app.bundleId.lowercased()
                    guard requested.contains(id) else { continue }
                    let gameGenres = Array(Set(zip(app.genres ?? [], app.genreIds ?? [])
                        .compactMap { name, genreID -> String? in
                            guard let number = Int(genreID), (7000..<8000).contains(number) else { return nil }
                            return name
                        })).sorted()
                    values[id] = Metadata(primaryGenre: app.primaryGenreName, gameGenres: gameGenres)
                }
            } catch {
                // A failed batch remains unresolved and can be retried later.
                continue
            }
        }
        save(values)
        return values
    }

    private static func save(_ values: [String: Metadata]) {
        guard let cacheURL else { return }
        do {
            try FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(Cache(fetchedAt: Date(), values: values))
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            // The current session still benefits from the fetched metadata.
        }
    }
}
