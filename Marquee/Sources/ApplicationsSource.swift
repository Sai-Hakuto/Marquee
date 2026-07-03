import Foundation
import AppKit

// Scans /Applications for native Mac games. Apple requires every App Store app to declare an
// `LSApplicationCategoryType`, and a dedicated "Games" category (plus per-genre variants like
// "arcade-games"/"action-games"/…, all suffixed "-games") exists for exactly this — reading it
// straight from Info.plist is a free, self-maintaining allowlist that keeps the pile of ordinary
// Mac software (browsers, utilities, creative tools) out without hand-maintaining a denylist.
// Verified live: "public.app-category.games" (Thronefall) and
// "public.app-category.arcade-games" (Standard Snake) both correctly read as games, while
// non-game apps (Safari, Xcode, Discord, GarageBand, …) carry unrelated categories or none at
// all — a blank/missing category is NOT treated as a game (opt-in, not opt-out).
struct ApplicationsSource {
    private static let applicationsDir = URL(fileURLWithPath: "/Applications")

    // Real launcher/store apps that mistag themselves under a Games category but aren't
    // playable games themselves — confirmed live: Epic Games Launcher.app ships
    // LSApplicationCategoryType = public.app-category.games. (Its actual games are already
    // covered by EpicSource's own Manifests scan.) Not a hypothetical guard — this exact app
    // showed up as a false positive during development.
    private static let excludedBundleIDs: Set<String> = [
        "com.epicgames.EpicGamesLauncher",
    ]

    private static let iconCacheDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Marquee/AppIcons")

    static func scan() -> [Game] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: applicationsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries
            .filter { $0.pathExtension == "app" }
            // GOGSource claims goggame-marked bundles instead, so they show under the GOG
            // badge rather than a generic Mac one — even though most GOG games are ALSO
            // correctly tagged "public.app-category.games" and would otherwise match here too.
            .filter { !GOGSource.hasGOGMarker(in: $0) }
            .compactMap(parseApp)
    }

    private static func parseApp(_ appURL: URL) -> Game? {
        let infoPlistURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let plist = NSDictionary(contentsOf: infoPlistURL),
              let category = plist["LSApplicationCategoryType"] as? String,
              category.hasSuffix("games")
        else { return nil }

        let bundleId = plist["CFBundleIdentifier"] as? String
        if let bundleId, excludedBundleIDs.contains(bundleId) { return nil }

        let title = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? appURL.deletingPathExtension().lastPathComponent

        let iconPath = extractAndCacheIcon(appURL: appURL, bundleId: bundleId)
        return Game(
            title: title,
            source: .applications(bundleURL: appURL),
            metadata: GameMetadata(bundledIconPath: iconPath)
        )
    }

    // Same fallback approach as EpicSource/GOGSource: pull the bundle's own .icns via
    // NSWorkspace and cache it as a PNG once. Keyed by bundle identifier (stable across the app
    // being moved/updated in place); falls back to the bundle path for the rare app with none.
    private static func extractAndCacheIcon(appURL: URL, bundleId: String?) -> URL? {
        let key = bundleId ?? appURL.path.replacingOccurrences(of: "/", with: "_")
        let dest = iconCacheDir.appendingPathComponent("\(key).png")
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
