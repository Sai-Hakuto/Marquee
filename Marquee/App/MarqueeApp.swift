import SwiftUI

struct MarqueeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var musicPlayer = MusicPlayerController()
    @State private var session = GameSessionManager()
    @State private var soundEffects = SoundEffects()

    init() {
        // Delete SwiftUI's persisted WindowGroup frame BEFORE the scene is built. SwiftUI reads and
        // caches the saved "NSWindow Frame …" frame during scene construction (which happens right
        // after this init, and BEFORE applicationDidFinishLaunching), then re-applies it ~0.3s later —
        // clobbering the frame AppDelegate sets and, historically, re-imposing a stale over-wide width
        // or an off-screen origin. Clearing it here (every launch) means there is nothing to restore,
        // so the window always opens exactly where AppDelegate places it: centered on the main display.
        // See AppDelegate.clearSwiftUIFrameState / configureMainWindow.
        AppDelegate.clearSwiftUIFrameState()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(delegate.appState)
                .environment(musicPlayer)
                .environment(session)
                .environment(soundEffects)
                .preferredColorScheme(.dark)
                .onAppear {
                    // Wire the session manager to the live music controller + our AppDelegate
                    // (NSApp.delegate is SwiftUI's wrapper, not our instance).
                    session.music = musicPlayer
                    session.appDelegate = delegate
                    session.sound = soundEffects
                    session.appState = delegate.appState
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1600, height: 1020)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}

            // Refresh Library also lives in the "Library" menu (⌘R) below, but that menu isn't
            // obvious to a first-time user hunting for "how do I make it notice new games" — the
            // app's own menu (right under "About Marquee", first thing visible when the menu bar
            // is opened at all) is the more discoverable spot.
            CommandGroup(after: .appInfo) {
                Button("Refresh Library") {
                    Task { await delegate.appState.loadAllGames() }
                }
                Divider()
            }

            CommandMenu("View") {
                Section("Layout") {
                    Button("Carousel") { delegate.appState.viewMode = .carousel }
                        .keyboardShortcut("1", modifiers: .command)
                    Button("Grid") { delegate.appState.viewMode = .grid }
                        .keyboardShortcut("2", modifiers: .command)
                    Button("Wall") { delegate.appState.viewMode = .wall }
                        .keyboardShortcut("3", modifiers: .command)
                    Button("List") { delegate.appState.viewMode = .list }
                        .keyboardShortcut("4", modifiers: .command)
                }
                Divider()
                Button("Toggle Full Screen") { delegate.toggleFullScreen() }
                    .keyboardShortcut("f", modifiers: [.control, .command])
                Divider()
                Section("Filter") {
                    Button("All Games")  { delegate.appState.sourceFilter = .all }
                        .keyboardShortcut("0", modifiers: .command)
                    Button("CrossOver")  { delegate.appState.sourceFilter = .crossOver }
                    Button("Steam")      { delegate.appState.sourceFilter = .steam }
                    Button("Epic")       { delegate.appState.sourceFilter = .epic }
                    Button("GOG")        { delegate.appState.sourceFilter = .gog }
                    Button("Mac")        { delegate.appState.sourceFilter = .applications }
                    if delegate.appState.hasHiddenGames {
                        Button("Hidden") { delegate.appState.sourceFilter = .hidden }
                    }
                }
                Divider()
                Section("Sort") {
                    ForEach(AppState.SortOption.allCases, id: \.self) { option in
                        Button(option.label) { delegate.appState.setSortOption(option) }
                    }
                }
            }

            CommandMenu("Library") {
                Button("Refresh Library") {
                    Task { await delegate.appState.loadAllGames() }
                }
                .keyboardShortcut("r", modifiers: .command)
            }

            CommandMenu("Game") {
                Button("Fix Cover Art…") {
                    let games = delegate.appState.filteredGames
                    let idx   = delegate.appState.selectedIndex
                    guard idx >= 0, idx < games.count else { return }
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                        delegate.appState.fixCoverTarget = games[idx]
                    }
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])

                Button("Hide Selected Game") {
                    let games = delegate.appState.filteredGames
                    let idx   = delegate.appState.selectedIndex
                    guard idx >= 0, idx < games.count else { return }
                    delegate.appState.hideGame(games[idx])
                }
            }

            CommandMenu("Appearance") {
                Section("Accent Color") {
                    Button("Space (Animated Purple)") { delegate.appState.setTheme(.outerspace) }
                    Button("Jet Black")               { delegate.appState.setTheme(.jetBlack) }
                    Button("Soft Grey")               { delegate.appState.setTheme(.softGrey) }
                }
                Divider()
                Button(delegate.appState.heroBackgroundEnabled
                       ? "Hide Game Backdrop" : "Show Game Backdrop") {
                    delegate.appState.setHeroBackground(!delegate.appState.heroBackgroundEnabled)
                }
                Button(delegate.appState.soundEffectsEnabled
                       ? "Mute Sound Effects" : "Enable Sound Effects") {
                    let on = !delegate.appState.soundEffectsEnabled
                    delegate.appState.setSoundEffects(on)
                    soundEffects.enabled = on
                }
            }
        }

        // A `Settings` scene is SwiftUI's own hook for the standard macOS "Preferences…" / "…
        // Settings" app-menu item + ⌘, — no manual CommandGroup/menu wiring needed, unlike every
        // other menu above.
        Settings {
            SettingsView()
                .environment(delegate.appState)
                .environment(musicPlayer)
                .environment(soundEffects)
                .preferredColorScheme(.dark)
        }
    }
}
