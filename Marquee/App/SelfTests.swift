import AppKit

// Debug-only self-test harnesses, gated behind environment variables so they never run for
// normal users:
//
//   MARQUEE_SELFTEST=1  — audits Game.id stability/uniqueness and Fix Cover targeting,
//                         prints PASS/FAIL lines, then exits 0 (all good) or 1 (broken).
//   MARQUEE_SIZECHECK=1 — prints each game's resolved install folder, measured size, and
//                         what PLAY would launch, then exits.
//
// Both are invoked from ContentView.revealApp() once the library is loaded, so they audit
// the exact game list a real session would show.
@MainActor
enum SelfTests {

    // MARK: - Game.id uniqueness + Fix Cover targeting audit (MARQUEE_SELFTEST)
    // Every game's stable UUID must resolve back to itself — a collision means Fix Cover
    // overrides and cached art would bleed between games.

    static func runUUIDAudit(appState: AppState) {
        let games = appState.filteredGames
        guard !games.isEmpty else { print("[SELFTEST] no games"); return }

        func log(_ s: String) { print(s); fflush(stdout) }

        Task { @MainActor in
            log("[SELFTEST] ===== Game.id uniqueness audit (\(games.count) games) =====")

            // 1) Dump every game's id + source key; detect collisions.
            var idToTitles: [String: [String]] = [:]
            for g in games {
                let key: String
                switch g.source {
                case .crossOver(let b, let p): key = "cx:\(b):\(p.isEmpty ? "<EMPTY>" : p)"
                case .steam(let a):            key = "st:\(a)"
                case .epic(let app, let c):    key = "ep:\(c):\(app)"
                case .applications(let u):     key = "app:\(u.path)"
                case .playCover(let id, _):    key = "pc:\(id)"
                case .gog(let id, _):          key = "gog:\(id)"
                }
                let id8 = String(g.id.uuidString.prefix(8))
                idToTitles[g.id.uuidString, default: []].append(g.title)
                log("[SELFTEST]   '\(g.title)' id=\(id8) key=\(key)")
            }
            let collisions = idToTitles.filter { $0.value.count > 1 }
            log("[SELFTEST] collisions: \(collisions.count) UUID(s) shared by multiple games")
            for (_, titles) in collisions { log("[SELFTEST]   ⚠️ SHARED id → \(titles.joined(separator: ", "))") }

            // 2) The bug mechanism: refetchCover finds the game via firstIndex(id==).
            //    For each game, that must resolve back to ITSELF, not a collider.
            var pass = 0, total = 0
            for g in games {
                total += 1
                let resolved = games.firstIndex(where: { $0.id == g.id })
                let resolvedTitle = resolved.flatMap { games[safe: $0]?.title } ?? "nil"
                let ok = (resolvedTitle == g.title)
                if ok { pass += 1 }
                if !ok {
                    log("[SELFTEST]   FAIL: fixing '\(g.title)' would write to '\(resolvedTitle)'")
                }
            }
            log("[SELFTEST] firstIndex(id==) self-resolution: \(pass)/\(total) PASS")

            // 3) Simulate the REAL Fix Cover assignment: write each game a distinct coverSearch
            //    override (as refetchCover does), then read every one back and confirm no bleed.
            //    Only test games that actually exist — the library changes over time, so a stale
            //    hardcoded list must not fail the whole audit.
            let wantedTargets = ["Hi-Fi-RUSH", "PRAGMATA", "Rune Factory 5", "SOLARPUNK", "MOUSE"]
            let targets = wantedTargets.filter { name in games.contains { $0.title == name } }
            let ud = UserDefaults.standard
            var writtenKeys: [String] = []
            for t in targets {
                guard let g = games.first(where: { $0.title == t }) else { continue }
                let key = "coverSearch_\(g.id.uuidString)"
                ud.set("FIXED::\(t)", forKey: key)          // what FixCover writes
                writtenKeys.append(key)
            }
            var isoPass = 0
            for t in targets {
                guard let g = games.first(where: { $0.title == t }) else { continue }
                let readBack = ud.string(forKey: "coverSearch_\(g.id.uuidString)") ?? "nil"
                // The game refetchCover would update, and what its panel would autofill:
                let resolvesTo = games.first(where: { $0.id == g.id })?.title ?? "nil"
                let ok = (readBack == "FIXED::\(t)") && (resolvesTo == t)
                if ok { isoPass += 1 }
                log("[SELFTEST]   fix '\(t)' → writes/reads '\(readBack)', applies to '\(resolvesTo)' \(ok ? "PASS" : "FAIL")")
            }
            // Confirm a non-target (a game that isn't in the fix list) was untouched.
            let harv = games.first(where: { $0.title == "Harvestella" })
            let harvOverride = harv.flatMap { ud.string(forKey: "coverSearch_\($0.id.uuidString)") }
            let harvClean = (harvOverride == nil)
            log("[SELFTEST]   Harvestella override after fixing others: \(harvOverride ?? "nil") \(harvClean ? "PASS (untouched)" : "FAIL (bled!)")")
            for key in writtenKeys { ud.removeObject(forKey: key) }   // cleanup test state

            let allOK = collisions.isEmpty && pass == total && isoPass == targets.count && harvClean
            log("[SELFTEST] RESULT: \(allOK ? "ALL UNIQUE + ISOLATED — OK" : "BROKEN")")
            log("[SELFTEST] ===== done =====")
            exit(allOK ? 0 : 1)
        }
    }

    // MARK: - File-size / launch-target spot check (MARQUEE_SIZECHECK)

    static func runSizeCheck(appState: AppState) {
        let games = appState.games
        Task { @MainActor in
            func log(_ s: String) { print(s); fflush(stdout) }
            log("[SIZECHECK] ===== \(games.count) games =====")
            for g in games {
                let (loc, size) = GameDetailsFetcher.debugLocationSize(for: g)
                log("[SIZECHECK] \(g.title)  [\(g.sourceBadgeTitle)]")
                log("[SIZECHECK]     size   = \(size)")
                log("[SIZECHECK]     loc    = \(loc)")
                log("[SIZECHECK]     launch = \(GameLauncher.debugLaunchTarget(g))")
            }
            log("[SIZECHECK] ===== done =====")
            exit(0)
        }
    }
}
