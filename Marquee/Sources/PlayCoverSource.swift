import Foundation
import AppKit

// PlayCover stores each installed iOS app as a bundle under its own container. Scan only
// that directory, so loose IPA files and unrelated iOS apps never enter the library.
struct PlayCoverSource {
    static let applicationsDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Containers/io.playcover.PlayCover/Applications")

    private static let iconCacheDir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Marquee/PlayCoverIcons")

    static func scan() -> [Game] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: applicationsDir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter { $0.pathExtension.lowercased() == "app" }.compactMap(parseApp)
    }

    private static func parseApp(_ appURL: URL) -> Game? {
        let infoURL = appURL.appendingPathComponent("Info.plist")
        guard let plist = NSDictionary(contentsOf: infoURL),
              let bundleID = plist["CFBundleIdentifier"] as? String,
              !bundleID.isEmpty,
              let executable = plist["CFBundleExecutable"] as? String,
              FileManager.default.fileExists(atPath: appURL.appendingPathComponent(executable).path)
        else { return nil }

        let title = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? appURL.deletingPathExtension().lastPathComponent

        return Game(
            title: title,
            source: .playCover(bundleID: bundleID, bundleURL: appURL),
            metadata: GameMetadata(bundledIconPath: cachedIcon(in: appURL, bundleID: bundleID))
        )
    }

    private static func cachedIcon(in appURL: URL, bundleID: String) -> URL? {
        let dest = iconCacheDir.appendingPathComponent("\(bundleID).png")
        if FileManager.default.fileExists(atPath: dest.path) { return dest }
        guard let entries = try? FileManager.default.contentsOfDirectory(at: appURL, includingPropertiesForKeys: nil),
              let imageURL = entries.first(where: { $0.lastPathComponent.hasPrefix("AppIcon76x76") && $0.pathExtension == "png" })
                ?? entries.first(where: { $0.lastPathComponent.hasPrefix("AppIcon60x60") && $0.pathExtension == "png" }),
              let image = NSImage(contentsOf: imageURL),
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:])
        else { return nil }
        try? FileManager.default.createDirectory(at: iconCacheDir, withIntermediateDirectories: true)
        guard (try? png.write(to: dest)) != nil else { return nil }
        return dest
    }
}
