import Foundation
import AppKit
import CryptoKit

enum IPADownloadError: LocalizedError {
    case invalidResponse
    case invalidArchive
    case playCoverMissing

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "The source did not return an IPA file."
        case .invalidArchive: return "The download is not a valid IPA archive."
        case .playCoverMissing: return "PlayCover is not installed on this Mac. The IPA was saved for you."
        }
    }
}

enum IPADownload {
    private static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Marquee/IPA Downloads")
    }

    static func savedURL(_ entry: IPAEntry, version: IPAVersion, allowLegacy: Bool = false) -> URL? {
        let current = destination(for: entry, version: version)
        if FileManager.default.fileExists(atPath: current.path) { return current }
        if allowLegacy {
            let old = legacyDestination(for: entry, version: version)
            if FileManager.default.fileExists(atPath: old.path) { return old }
        }
        return nil
    }

    private static func safe(_ text: String) -> String {
        text.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression)
    }

    private static func destination(for entry: IPAEntry, version: IPAVersion) -> URL {
        let digest = SHA256.hash(data: Data(version.url.absoluteString.utf8))
            .prefix(6).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(safe(entry.bundleID))_\(safe(version.version))_\(safe(entry.source))_\(digest).ipa")
    }

    private static func legacyDestination(for entry: IPAEntry, version: IPAVersion) -> URL {
        directory.appendingPathComponent("\(safe(entry.bundleID))_\(safe(version.version)).ipa")
    }

    static func save(_ entry: IPAEntry, version: IPAVersion) async throws -> URL {
        let destination = destination(for: entry, version: version)
        if FileManager.default.fileExists(atPath: destination.path), try await isValidIPA(destination) {
            return destination
        }
        var request = URLRequest(url: version.url)
        request.setValue("Mozilla/5.0 Marquee", forHTTPHeaderField: "User-Agent")
        let (temporary, response) = try await URLSession.shared.download(for: request)
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200,
              response.url?.pathExtension.lowercased() == "ipa" else {
            throw IPADownloadError.invalidResponse
        }

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let candidate = directory.appendingPathComponent(UUID().uuidString + ".ipa")
        try FileManager.default.moveItem(at: temporary, to: candidate)
        do {
            guard try await isValidIPA(candidate) else { throw IPADownloadError.invalidArchive }
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: candidate, to: destination)
            return destination
        } catch {
            try? FileManager.default.removeItem(at: candidate)
            throw error
        }
    }

    static func moveToTrash(_ url: URL) throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    @MainActor
    static func openPlayCover() throws {
        guard let app = playCoverURL() else { throw IPADownloadError.playCoverMissing }
        guard NSWorkspace.shared.open(app) else { throw IPADownloadError.playCoverMissing }
    }

    @MainActor
    private static func playCoverURL() -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.playcover.PlayCover")
            ?? (FileManager.default.fileExists(atPath: "/Applications/PlayCover.app")
                ? URL(fileURLWithPath: "/Applications/PlayCover.app") : nil)
    }

    private static func isValidIPA(_ url: URL) async throws -> Bool {
        try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-tqq", url.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
    }

    @MainActor
    static func installInPlayCover(_ url: URL) async throws {
        guard let app = playCoverURL() else {
            throw IPADownloadError.playCoverMissing
        }
        // Launch Services delivers the IPA to PlayCover's registered document handler. PlayCover
        // performs the import itself; Marquee never modifies or re-signs the archive.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: .init()) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }
}
