import Foundation
import AppKit

struct EpicSource {
    private static let manifestsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Epic/EpicGamesLauncher/Data/Manifests")

    private static let iconCacheDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Marquee/EpicIcons")

    static func scan() -> [Game] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: manifestsDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return files
            .filter { $0.pathExtension == "item" }
            .compactMap { parseManifest(at: $0) }
    }

    private static func parseManifest(at url: URL) -> Game? {
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let displayName = json["DisplayName"] as? String, !displayName.isEmpty,
              let appName = json["AppName"] as? String, !appName.isEmpty,
              let catalogItemId = json["CatalogItemId"] as? String, !catalogItemId.isEmpty
        else { return nil }

        var iconPath: URL?
        if let installLocation = json["InstallLocation"] as? String,
           let launchExecutable = json["LaunchExecutable"] as? String,
           let appBundleURL = resolveAppBundle(installLocation: installLocation, launchExecutable: launchExecutable) {
            iconPath = extractAndCacheIcon(appURL: appBundleURL, catalogItemId: catalogItemId)
        }

        return Game(
            title: displayName,
            source: .epic(appName: appName, catalogItemId: catalogItemId),
            metadata: GameMetadata(bundledIconPath: iconPath)
        )
    }

    // LaunchExecutable is rooted at the FIRST ".app" bundle it names, relative to
    // InstallLocation — e.g. InstallLocation "/Users/Shared/Epic Games/Foo" +
    // LaunchExecutable "Foo.app/Contents/MacOS/Foo" (sometimes with a leading "/", both
    // observed live across two real manifests) → ".../Foo/Foo.app".
    private static func resolveAppBundle(installLocation: String, launchExecutable: String) -> URL? {
        guard let appRange = launchExecutable.range(of: ".app") else { return nil }
        let relative = String(launchExecutable[..<appRange.upperBound])
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let appURL = URL(fileURLWithPath: installLocation).appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: appURL.path) else { return nil }
        return appURL
    }

    // Epic doesn't ship a flat icon image file the way CrossOver's cxmenu icons do, but its
    // games ARE real macOS .app bundles with a proper .icns — pull that via NSWorkspace and
    // cache it as a PNG once, so `bundledIconPath`'s existing "read a local image file" fallback
    // (ArtFetcher.fetch, shared with CrossOver) works unchanged.
    private static func extractAndCacheIcon(appURL: URL, catalogItemId: String) -> URL? {
        let dest = iconCacheDir.appendingPathComponent("\(catalogItemId).png")
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
