import Foundation
import Darwin

// Spawns a child process with macOS "TCC responsibility" DISCLAIMED.
//
// Why this exists: when Marquee launches CrossOver's `wine` the normal way (Foundation's
// `Process`), macOS treats Marquee as the *responsible process* for everything wine and its
// descendants do. CrossOver routinely refreshes the .app shortcut bundles it generates for
// bottle programs (in ~/Applications and ~/Applications/CrossOver), and writing inside any
// .app bundle is guarded by the "App Management" privacy permission — so users saw
// "Marquee was prevented from modifying apps on your Mac" notifications for file writes
// Marquee never performs itself.
//
// Disclaiming responsibility makes the spawned wine process responsible for its own actions,
// so macOS attributes CrossOver's shortcut housekeeping to CrossOver's own (CodeWeavers-signed)
// binaries instead of to us. Marquee itself needs no special permissions: it reads game
// libraries, writes only to its own cache/support folders, and launches games.
//
// `responsibility_spawnattrs_setdisclaim` ships in libSystem (used by Chromium/Firefox for the
// same purpose) but isn't in the public headers, so it's looked up at runtime via dlsym — if
// it ever disappears, we just spawn without the disclaim rather than failing the launch.
enum DisclaimedProcess {

    // int responsibility_spawnattrs_setdisclaim(posix_spawnattr_t *attrs, int disclaim)
    private typealias SetDisclaimFn =
        @convention(c) (UnsafeMutablePointer<posix_spawnattr_t?>, Int32) -> Int32

    private static let setDisclaim: SetDisclaimFn? = {
        guard let sym = dlsym(dlopen(nil, RTLD_NOW), "responsibility_spawnattrs_setdisclaim")
        else { return nil }
        return unsafeBitCast(sym, to: SetDisclaimFn.self)
    }()

    // Launches `executable` with `arguments` (argv[0] is filled in automatically) and returns
    // once the child is spawned — the child runs independently, like Process with no wait.
    // Returns false if the spawn itself failed.
    @discardableResult
    static func spawn(executable: URL, arguments: [String], currentDirectory: URL? = nil) -> Bool {
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        _ = Self.setDisclaim?(&attr, 1)

        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        if let cwd = currentDirectory {
            posix_spawn_file_actions_addchdir_np(&fileActions, cwd.path)
        }

        var argv: [UnsafeMutablePointer<CChar>?] = ([executable.path] + arguments).map { strdup($0) }
        argv.append(nil)
        defer { argv.forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable.path, &fileActions, &attr, argv, environ)
        guard rc == 0 else {
            NSLog("[Marquee] posix_spawn failed for \(executable.lastPathComponent): \(String(cString: strerror(rc)))")
            return false
        }

        // Reap the child once it exits so it never lingers as a zombie. (wine's launcher
        // process typically hands off to wineserver and exits quickly; the actual game process
        // is not our child and is tracked separately by GameProcessMonitor.)
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        return true
    }
}
