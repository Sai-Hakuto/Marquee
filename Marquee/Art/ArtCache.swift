import Foundation

actor ArtCache {
    static let shared = ArtCache()

    private let cacheDir: URL

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDir = base.appendingPathComponent("Marquee/art", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    func localPath(for gameId: UUID) -> URL {
        cacheDir.appendingPathComponent("\(gameId.uuidString).png")
    }

    func cachedURL(for gameId: UUID) -> URL? {
        let url = localPath(for: gameId)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func save(_ data: Data, for gameId: UUID) throws {
        try data.write(to: localPath(for: gameId))
    }

    func remove(for gameId: UUID) {
        try? FileManager.default.removeItem(at: localPath(for: gameId))
        try? FileManager.default.removeItem(at: localHeaderPath(for: gameId))
        try? FileManager.default.removeItem(at: localHeroPath(for: gameId))
    }

    // MARK: - Horizontal "header" art (Steam header.jpg — landscape, used by List view)

    func localHeaderPath(for gameId: UUID) -> URL {
        cacheDir.appendingPathComponent("\(gameId.uuidString)_header.png")
    }

    func cachedHeaderURL(for gameId: UUID) -> URL? {
        let url = localHeaderPath(for: gameId)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func saveHeader(_ data: Data, for gameId: UUID) throws {
        try data.write(to: localHeaderPath(for: gameId))
    }

    // Remove ONLY the landscape header (used by "Fix Banner Art" so a banner re-fetch
    // doesn't disturb the cached portrait cover).
    func removeHeader(for gameId: UUID) {
        try? FileManager.default.removeItem(at: localHeaderPath(for: gameId))
    }

    // MARK: - Wide "hero" art (Steam library_hero.jpg — ~1920×620, blurred backdrop)

    func localHeroPath(for gameId: UUID) -> URL {
        cacheDir.appendingPathComponent("\(gameId.uuidString)_hero.png")
    }

    func cachedHeroURL(for gameId: UUID) -> URL? {
        let url = localHeroPath(for: gameId)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func saveHero(_ data: Data, for gameId: UUID) throws {
        try data.write(to: localHeroPath(for: gameId))
    }

    // Wipes the whole cache directory (covers + headers + heroes for every game) and
    // recreates it empty — used by Settings ▸ Reset ▸ Clear Art Cache.
    func removeAll() {
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }
}
