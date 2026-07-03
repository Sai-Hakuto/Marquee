import Foundation

struct SteamSource {
    private static let steamAppsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Steam/steamapps")

    static func scan() -> [Game] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: steamAppsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "acf" }
            .compactMap { parseACF(at: $0) }
    }

    private static func parseACF(at url: URL) -> Game? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        var appId: Int?
        var name: String?

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if appId == nil, trimmed.hasPrefix("\"appid\"") {
                appId = Int(extractValue(from: trimmed))
            } else if name == nil, trimmed.hasPrefix("\"name\"") {
                name = extractValue(from: trimmed)
            }
            if appId != nil && name != nil { break }
        }

        guard let id = appId, let title = name, !title.isEmpty else { return nil }
        return Game(title: title, source: .steam(appId: id))
    }

    // Extract value from VDF line: "key"\t\t"value"
    private static func extractValue(from line: String) -> String {
        let parts = line.components(separatedBy: "\"")
        // ["", key, whitespace, value, ""]
        return parts.count >= 4 ? parts[3] : ""
    }
}
