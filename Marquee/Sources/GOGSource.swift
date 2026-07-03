import Foundation
import AppKit

// GOG for Mac ships games as plain .app bundles dropped directly into /Applications (via GOG
// Galaxy's installer, or a manual offline installer) — there's no separate "GOG library" folder
// to enumerate the way Epic has Manifests/*.item. What DOES uniquely mark a GOG install is a
// `goggame-{id}.info` JSON file GOG's own installer drops inside the bundle's Contents/Resources
// alongside a matching `.id`/`.hashdb` — verified against a real GOG install
// ("Röki.app" ships goggame-1656650384.{info,id,hashdb}). That file is also the cleanest source
// of the game's true display name (handles diacritics CFBundleName sometimes mangles — "Röki"
// vs "Roki") and its GOG catalog gameId, which becomes the stable UUID key so a reinstall (or
// the user renaming/moving the .app) still resolves to the same game, same as Steam's appId.
struct GOGSource {
    private static let applicationsDir = URL(fileURLWithPath: "/Applications")

    private static let iconCacheDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Marquee/GOGIcons")

    static func scan() -> [Game] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: applicationsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries
            .filter { $0.pathExtension == "app" }
            .compactMap(parseApp)
    }

    // Exposed so ApplicationsSource's category-based scan can skip GOG bundles — this scanner
    // claims them instead, giving GOG games their own distinct badge rather than a generic "Mac"
    // one.
    static func hasGOGMarker(in appURL: URL) -> Bool {
        goggameInfoURL(in: appURL) != nil
    }

    private static func goggameInfoURL(in appURL: URL) -> URL? {
        let resources = appURL.appendingPathComponent("Contents/Resources")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: resources, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return nil }
        return files.first {
            $0.lastPathComponent.hasPrefix("goggame-") && $0.pathExtension == "info"
        }
    }

    private static func parseApp(_ appURL: URL) -> Game? {
        guard let infoURL = goggameInfoURL(in: appURL),
              let data = try? Data(contentsOf: infoURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gameId = json["gameId"] as? String, !gameId.isEmpty,
              let name = json["name"] as? String, !name.isEmpty
        else { return nil }

        let iconPath = extractAndCacheIcon(appURL: appURL, gameId: gameId)
        return Game(
            title: name,
            source: .gog(gameId: gameId, bundleURL: appURL),
            metadata: GameMetadata(bundledIconPath: iconPath)
        )
    }

    // GOG doesn't ship a flat cover-art file the way CrossOver's cxmenu icons do, but its games
    // ARE real macOS .app bundles with a proper .icns — same fallback approach as EpicSource.
    private static func extractAndCacheIcon(appURL: URL, gameId: String) -> URL? {
        let dest = iconCacheDir.appendingPathComponent("\(gameId).png")
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
