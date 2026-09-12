import Foundation
import CryptoKit

struct Game: Identifiable, Equatable, Sendable {
    static func == (lhs: Game, rhs: Game) -> Bool { lhs.id == rhs.id }
    let id: UUID
    var title: String
    var source: GameSource
    var coverArtURL: URL?
    var localArtPath: URL?
    var isInstalled: Bool
    var metadata: GameMetadata

    // UUID is derived from the source identity so it's stable across relaunches,
    // keeping the art cache and Fix Cover overrides reachable on subsequent opens.
    init(
        title: String,
        source: GameSource,
        isInstalled: Bool = true,
        metadata: GameMetadata = GameMetadata()
    ) {
        self.id = source.stableUUID(title: title)
        self.title = title
        self.source = source
        self.isInstalled = isInstalled
        self.metadata = metadata
    }
}

enum GameSource: Sendable {
    case crossOver(bottleName: String, exePath: String)
    case steam(appId: Int)
    case applications(bundleURL: URL)
    case playCover(bundleID: String, bundleURL: URL)
    case epic(appName: String, catalogItemId: String)
    case gog(gameId: String, bundleURL: URL)
}

struct GameMetadata: Sendable {
    var genre: String?
    var releaseYear: Int?
    var developer: String?
    var steamGridDBId: Int?
    var bundledIconPath: URL?  // local icon shipped by CrossOver or app bundle
    // The storefront a .crossOver game was actually installed through, when it's not CrossOver's
    // own shortcut mechanism — e.g. "steam" for a game discovered via
    // CrossOverSource.scanBottledSteamLibrary (a real Windows Steam running INSIDE the bottle).
    // `viaLauncher` itself is cosmetic-only (peeks a secondary brand badge behind the CrossOver
    // pill, see SourceBadge in GameArtImage.swift) — but `viaLauncherAppId` is load-bearing for
    // LAUNCHING: most Steam games check for a live Steam client / initialize steam_api on
    // startup (DRM, overlay, cloud saves) and fail or hang when their exe is run directly under
    // wine — verified against real installs, this is not optional. When set, GameLauncher routes the
    // launch through the bottled Steam client itself (`steam.exe -applaunch {id}`) instead of
    // the resolved exe directly; the resolved exe path is still kept in
    // `GameSource.crossOver`'s exePath for size/location lookups and process-exit detection,
    // since the real game process is what those need to find, not steam.exe.
    var viaLauncher: String?
    var viaLauncherAppId: Int?

    init(genre: String? = nil, releaseYear: Int? = nil, developer: String? = nil,
         steamGridDBId: Int? = nil, bundledIconPath: URL? = nil, viaLauncher: String? = nil,
         viaLauncherAppId: Int? = nil) {
        self.genre = genre
        self.releaseYear = releaseYear
        self.developer = developer
        self.steamGridDBId = steamGridDBId
        self.bundledIconPath = bundledIconPath
        self.viaLauncher = viaLauncher
        self.viaLauncherAppId = viaLauncherAppId
    }
}

extension GameSource {
    // `title` disambiguates CrossOver games whose exePath is empty (no .lnk target
    // or no "Path" in cxmenu.conf). Without it, every empty-path game in a bottle
    // hashes to ONE id — sharing art-cache files and Fix Cover overrides, and making
    // refetchCover land on the wrong game. Titles are globally deduplicated in
    // CrossOverSource.scan() and stable across relaunches, so they're a safe key.
    func stableUUID(title: String) -> UUID {
        let key: String
        switch self {
        case .crossOver(let bottle, let path):
            key = path.isEmpty ? "cx:\(bottle):title=\(title)" : "cx:\(bottle):\(path)"
        case .steam(let appId):               key = "st:\(appId)"
        case .epic(let appName, let catId):   key = "ep:\(catId):\(appName)"
        case .applications(let url):          key = "app:\(url.path)"
        case .playCover(let bundleID, _):      key = "pc:\(bundleID)"
        // Keyed by GOG's own catalog gameId, not the bundle path — a reinstall (or the user
        // moving the .app) still resolves to the same game, same as Steam's appId.
        case .gog(let gameId, _):             key = "gog:\(gameId)"
        }
        let b = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

extension Game {
    var sourceBadgeTitle: String {
        switch source {
        case .crossOver: return "CrossOver"
        case .steam:     return "Steam"
        case .applications: return "Mac"
        case .playCover: return "PlayCover"
        case .epic:      return "Epic"
        case .gog:       return "GOG"
        }
    }

    // Per-source brand-evocative colors, reused everywhere a source is shown
    // (pill badges, placeholder art, carousel box placeholder) for a consistent
    // visual language across the whole app.
    var sourceBadgeColor: (r: Double, g: Double, b: Double) {
        switch source {
        case .crossOver:    return (0.85, 0.27, 0.16)   // CrossOver / CodeWeavers crimson-orange
        case .steam:        return (0.11, 0.49, 0.82)   // Steam blue
        case .applications: return (0.40, 0.43, 0.49)   // Apple graphite / silver
        case .playCover:    return (0.19, 0.66, 0.67)   // PlayCover teal
        case .epic:         return (0.17, 0.18, 0.22)   // Epic Games near-black charcoal
        case .gog:          return (0.56, 0.22, 0.66)   // GOG.com violet
        }
    }
}
