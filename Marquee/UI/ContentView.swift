import SwiftUI
import AppKit
import SceneKit

// The root view: owns the view-mode switch (carousel / grid / wall / list), the startup +
// reveal sequence, and the glue between AppState and the SceneKit carousel. The pieces live in
// sibling files to keep each concern readable:
//   ContentView+Chrome.swift — top nav bar, bottom-right controls, logo overlay, info bar
//   ContentView+Input.swift  — the unified keyboard/controller navigation router
//   Backgrounds.swift        — the decorative background layers
struct ContentView: View {
    @Environment(AppState.self) var appState
    @Environment(MusicPlayerController.self) var musicPlayer
    @Environment(GameSessionManager.self) var session
    @Environment(SoundEffects.self) var soundEffects
    @State var carousel = CarouselController()
    @State private var showLogo = true
    @State var logoOpacity: Double = 0
    @State var logoScale: CGFloat = 0.85
    @State var logoBlur: CGFloat = 12
    @State private var carouselReady = false
    @State private var keyMonitor: Any?
    @State private var mouseMonitor: Any?
    @State private var didBecomeKeyObserver: NSObjectProtocol?
    @State private var fixCoverPanel = FixCoverPanel()
    @State var musicSettingsPanel = MusicSettingsPanel()
    @State private var detailBoxController = DetailBoxController()
    @State private var controllerInput = ControllerInput()
    @State var carouselHovered: Bool = true   // default true so keyboard users always see ring
    @State private var startupTime: Date = Date()
    // Buy Me A Coffee badge — same "give it 15s, then get out of the way" idiom as the music
    // widget's auto-minimize (MusicPlayerController.scheduleAutoMinimize), but simpler: a one-way
    // dim (not a collapse) since the badge has no expanded/collapsed state of its own. Hovering
    // brings it back to full opacity so it's never actually hard to find/click, it's just not an
    // eyesore sitting at full brightness the whole time.
    @State var coffeeButtonDimmed = false
    @State var coffeeButtonHovered = false

    // Focus zone state — determines where keyboard/controller input is routed
    @State var uiFocus: UIFocusZone = .carousel
    @State var topBarFocusIdx: Int = 0    // which filter chip is highlighted
    @State var bottomFocusIdx: Int = 0    // 0=motion toggle, 1-3=theme swatches
    @State var detailFocusIdx: Int = 0    // 0=Play, 1=Favorite, 2=Hide, 3=Back
    @State var musicPlayerFocusIdx: Int = 1  // 0=prev, 1=play/pause, 2=next
    @State var listActionFocusIdx: Int = 0   // 0=Play, 1=Favorite, 2=Hide (List view only)
    @State var searchSortFocusIdx: Int = 0   // 0=search pill, 1=sort pill

    // Height reserved above content for the floating search/sort bar (grid/wall's top padding;
    // List pushes only its own row list down by the same amount — see ListView).
    static let searchSortBarHeight: CGFloat = 64

    // The search/sort bar's default position (right under the nav bar) read as "too high" —
    // measured via pixel-sampled screenshots, the gap from the nav bar down to the bar was ~10pt
    // while the gap from the bar down to the carousel's centered poster was ~94pt. Nudging the
    // bar (and grid/wall content, by the same amount, to preserve the gap that was already fine
    // between the bar and the tiles below it) down by this much lands the bar at ~52pt below the
    // nav bar — roughly equidistant between the nav bar and the poster, since the poster's own
    // on-screen position is fixed by the carousel's camera/box math and doesn't move with
    // SwiftUI padding.
    static let searchBarVerticalNudge: CGFloat = 42

    // eShop-style trailer scrubbing — tracks a continuous run of same-direction skips so the
    // step size can accelerate the longer the user keeps skipping (see scrubTrailer).
    @State var trailerScrubDirection: Int = 0
    @State var trailerScrubStreakStart: TimeInterval = 0
    @State var lastTrailerScrub: TimeInterval = 0

    // Visible filter chips in top bar order (used for keyboard navigation)
    var visibleFilters: [AppState.SourceFilter] {
        AppState.SourceFilter.allCases.filter {
            ($0 != .hidden    || appState.hasHiddenGames) &&
            ($0 != .favorites || appState.hasFavorites)
        }
    }

    private var selectedIndexBinding: Binding<Int> {
        Binding(get: { appState.selectedIndex }, set: { appState.selectedIndex = $0 })
    }

    // Main layout content for the current view mode (extracted to keep `body` type-checkable).
    @ViewBuilder
    private var mainContent: some View {
        switch appState.viewMode {
        case .carousel:
            SceneKitView(
                scene: carousel.scene,
                onRightClick:  { node, event in handleCarouselRightClick(node: node, event: event) },
                onLeftClick:   { node in handleCarouselLeftClick(node: node) },
                onScroll:      { delta in navigateDelta(delta) },
                onMouseInside: { inside in
                    carouselHovered = inside
                    if inside { appState.lastInputMethod = .mouse }
                    updateCarouselRing()
                },
                isVisible: appState.windowVisible
            )
            .ignoresSafeArea()
        case .grid:
            GridView(games: appState.filteredGames, selectedIndex: selectedIndexBinding)
                // 52pt nav bar + 18pt breathing room below logo overhang + the floating search/sort bar
                .padding(.top, 70 + Self.searchSortBarHeight + Self.searchBarVerticalNudge)
        case .wall:
            WallView(games: appState.filteredGames, selectedIndex: selectedIndexBinding)
                .padding(.top, 70 + Self.searchSortBarHeight + Self.searchBarVerticalNudge)
        case .list:
            // List renders its own SearchSortBar internally, constrained to the row-list column
            // only (not the right-hand detail panel) — so no extra top padding here, and the
            // global bar below is suppressed for .list.
            ListView(games: appState.filteredGames, selectedIndex: selectedIndexBinding,
                     actionsFocused: uiFocus == .listActions, actionFocusIdx: listActionFocusIdx,
                     searchSortActive: uiFocus == .searchSort, searchSortFocusIdx: searchSortFocusIdx)
                .padding(.top, 70)
        }
    }

    private var rootStack: some View {
        ZStack {
            if appState.currentTheme == .outerspace {
                OuterspaceBackground()
            } else {
                appState.currentTheme.backgroundColor.ignoresSafeArea()
            }

            // Selected game's blurred hero art — between the theme and the motion overlay so
            // both still read. Shared across all four view modes (one component, driven by the
            // same selectedIndex each already binds to) — grid/wall/list show it through their
            // tile gaps exactly like the carousel does. The Detail page still owns its own
            // opaque backdrop and sits above this in zIndex, so it's hidden there.
            if appState.heroBackgroundEnabled {
                HeroBackground(game: appState.filteredGames[safe: appState.selectedIndex])
            }

            // Animated wave overlay — 50% opacity so it stays subtle. Also gated on
            // windowVisible: the Canvas repaints 30x/sec via TimelineView, real continuous
            // CPU cost, so unmounting it the instant the window is miniaturized/covered (e.g.
            // while a game is running full-screen in front of it) is a straightforward, exact
            // win with zero visible tradeoff — nobody can see the particles anyway.
            if appState.motionEnabled && appState.windowVisible {
                MotionOverlay()
                    .opacity(0.5)
            }

            // Main content — switches between layout modes
            mainContent

            // Loading screen — covers all content until art is ready
            if showLogo {
                logoOverlay
                    .zIndex(20)
            }

            // First-launch onboarding — shown once until completed
            if appState.artSourcePreference == .notConfigured {
                OnboardingView()
                    .environment(appState)
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                    .zIndex(10)
            }

            // Full-screen Detail page — opens on Return from the carousel
            if let target = appState.detailTarget {
                DetailView(game: target, boxController: detailBoxController,
                           focusedButton: $detailFocusIdx,
                           onBack: { closeDetail() },
                           onPrev: { navigateDetail(-1) },
                           onNext: { navigateDetail(1) })
                    .environment(appState)
                    .id(target.id)   // recreate on game switch so it re-fetches details + replays the box entrance
                    .transition(.opacity)
                    .zIndex(4)
            }

            // Dim overlay — visual only; actual Fix Cover/Banner UI is in an NSPanel
            if appState.fixCoverTarget != nil || appState.fixBannerTarget != nil {
                Color.black.opacity(0.45).ignoresSafeArea()
                    .onTapGesture {
                        appState.fixCoverTarget = nil
                        appState.fixBannerTarget = nil
                    }
                    .transition(.opacity)
                    .zIndex(8)
            }

            VStack(spacing: 0) {
                topBar
                // List renders its own copy, constrained to just the row-list column — see
                // ListView/mainContent's .list case.
                if appState.viewMode != .list && appState.detailTarget == nil {
                    // The carousel reads ~20pt low relative to Grid/Wall even though all three
                    // share the same nudge — Grid/Wall's own content top padding
                    // (searchSortBarHeight + searchBarVerticalNudge, mainContent above)
                    // is untouched by this, so only the bar's own on-screen position for
                    // Carousel moves; Grid/Wall keep their existing bar-to-content gap intact.
                    let carouselLift: CGFloat = appState.viewMode == .carousel ? 20 : 0
                    SearchSortBar(isActive: uiFocus == .searchSort, focusIdx: searchSortFocusIdx)
                        .padding(.horizontal, 18)
                        .padding(.top, 10 + Self.searchBarVerticalNudge - carouselLift)
                }
                Spacer()
                if carouselReady && appState.viewMode == .carousel && appState.detailTarget == nil {
                    gameInfoBar
                }
            }
            .zIndex(6)

            // Buy Me A Coffee badge + motion toggle/theme swatches/version badge — bottom-right,
            // stacked (coffee badge sits above the existing control row).
            VStack(alignment: .trailing, spacing: 8) {
                coffeeButton
                bottomControls
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .padding(.trailing, 14)
            .padding(.bottom, 10)

            // Music player — bottom-left, above game info bar
            MusicPlayerView(
                zoneFocused: uiFocus == .musicPlayer,
                focusedControlIdx: musicPlayerFocusIdx,
                onSettingsOpen: { musicSettingsPanel.open(player: musicPlayer) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.leading, 16)
            .padding(.bottom, 16)
            .zIndex(5)

            // Input method indicator — tucked just below the top bar, right-aligned with the view mode buttons
            inputMethodBadge
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.trailing, 18)
                .padding(.top, 58)
                .allowsHitTesting(false)
                .zIndex(7)
        }
    }

    private var bodyCore: some View {
        rootStack
        // Pin the content to the fixed windowed size so SwiftUI's .windowResizability(.contentSize)
        // keeps the window that size instead of growing it to the content's greedy full-width ideal
        // (which ran off the edge of an ultrawide). nil in faux full screen = fill the display frame.
        .frame(width:  appState.isWindowFullScreen ? nil : appState.windowedContentSize.width,
               height: appState.isWindowFullScreen ? nil : appState.windowedContentSize.height)
        .onAppear { onContentAppear() }
        .onDisappear {
            if let monitor = keyMonitor   { NSEvent.removeMonitor(monitor) }
            if let monitor = mouseMonitor { NSEvent.removeMonitor(monitor) }
            if let obs = didBecomeKeyObserver { NotificationCenter.default.removeObserver(obs) }
        }
        .onChange(of: appState.fixCoverTarget) { _, new in
            if let game = new {
                fixCoverPanel.open(game: game, appState: appState, mode: .cover)
            } else {
                fixCoverPanel.close()
                appState.searchFieldResetToken += 1
            }
        }
        .onChange(of: appState.fixBannerTarget) { _, new in
            if let game = new {
                fixCoverPanel.open(game: game, appState: appState, mode: .banner)
            } else {
                fixCoverPanel.close()
                appState.searchFieldResetToken += 1
            }
        }
        .onChange(of: appState.gamesVersion) { _, _ in
            appState.selectedIndex = 0
            carousel.loadGames(appState.filteredGames, animated: false)
            applyArtToCarousel()
        }
        .onChange(of: appState.sortOption) { _, _ in
            appState.selectedIndex = 0
            if appState.viewMode == .carousel {
                carousel.loadGames(appState.filteredGames, animated: false, selectedIndex: 0)
                applyArtToCarousel()
            }
        }
        .onChange(of: appState.dateInstalledAscending) { _, _ in
            appState.selectedIndex = 0
            if appState.viewMode == .carousel {
                carousel.loadGames(appState.filteredGames, animated: false, selectedIndex: 0)
                applyArtToCarousel()
            }
        }
        .onChange(of: appState.searchQuery) { _, _ in
            // Best match always sorts to the front of filteredGames — snapping selection to 0
            // is all it takes to auto-center the carousel on it (2nd/3rd place naturally land
            // in the adjacent boxes) and to scroll grid/wall/list's top match into view, reusing
            // their existing onChange(of: selectedIndex) machinery.
            appState.selectedIndex = 0
            if appState.viewMode == .carousel {
                carousel.loadGames(appState.filteredGames, animated: false, selectedIndex: 0)
                applyArtToCarousel()
            }
        }
    }

    // Split out of `body` — SwiftUI modifier chains are one continuous expression, and this one
    // had grown long enough (~15 modifiers) that adding 2 more onChange handlers blew the type-
    // checker's time budget. Splitting into two `some View`-erased halves (each independently
    // type-checked) fixes it regardless of how large either half grows later.
    var body: some View {
        bodyCore
        .onChange(of: appState.hiddenVersion) { _, _ in
            if appState.sourceFilter == .hidden && !appState.hasHiddenGames {
                appState.sourceFilter = .all
            }
            appState.selectedIndex = 0
            carousel.loadGames(appState.filteredGames, animated: false)
            applyArtToCarousel()
        }
        .onChange(of: appState.favoritesVersion) { _, _ in
            if appState.sourceFilter == .favorites && !appState.hasFavorites {
                appState.sourceFilter = .all
            }
            // Rebuild so favorite-star badges on the carousel boxes refresh.
            carousel.loadGames(appState.filteredGames, animated: false,
                               selectedIndex: appState.selectedIndex)
            applyArtToCarousel()
        }
        .onChange(of: appState.isReady) { _, ready in
            if ready { revealApp() }
        }
        .onChange(of: appState.artVersion) { _, _ in
            applyArtToCarousel()
        }
        .onChange(of: appState.selectedIndex) { _, newIdx in
            // Handles programmatic navigation (e.g., after Fix Cover).
            // Arrow-key nav already calls carousel.navigate directly, but a second
            // call with the same index is a no-op (guarded inside navigate).
            if appState.viewMode == .carousel {
                carousel.navigate(to: newIdx)
            }
        }
        .onChange(of: appState.currentTheme) { _, theme in
            carousel.updateBackground(theme.sceneBackground)
        }
        // Keeps the audio tap's visualizer-update guard in sync — see MusicPlayerController
        // .isWindowVisible / the onBarsUpdated guard for why this matters for idle CPU.
        .onChange(of: appState.windowVisible) { _, visible in
            musicPlayer.isWindowVisible = visible
        }
        .onChange(of: appState.controllerAction) { _, action in
            guard action != .none else { return }
            appState.controllerAction = .none
            appState.hoverIndex = nil
            // Route through the same handler as the keyboard by mapping to key codes.
            switch action {
            case .confirm:  _ = handleNavKey(36)    // enter
            case .back:     _ = handleNavKey(53)    // esc
            case .navLeft:  _ = handleNavKey(123)
            case .navRight: _ = handleNavKey(124)
            case .navUp:    _ = handleNavKey(126)
            case .navDown:  _ = handleNavKey(125)
            case .pageLeft:  if appState.detailTarget != nil { navigateDetail(-1) }
            case .pageRight: if appState.detailTarget != nil { navigateDetail(1) }
            case .toggleFullScreen: session.appDelegate?.toggleFullScreen()
            case .none:     break
            }
            updateCarouselRing()
        }
        .onChange(of: appState.detailTarget) { _, new in
            detailFocusIdx = 0          // always start on PLAY
            appState.detailMediaFocusIndex = nil
            appState.detailMediaOverlayIndex = nil
            if new == nil { uiFocus = .carousel }
        }
        .onChange(of: appState.viewMode) { _, _ in
            // Every page view starts search-focused — matches the same uiFocus/searchEditing
            // pair Cmd+F and the startup reveal (below) set, so switching Carousel/Grid/Wall/
            // List always lands you ready to type instead of mid-browse.
            // Deferred a tick: the view-mode button's tap wraps `appState.viewMode = mode` in
            // `withAnimation`, and this onChange fires as part of that same animated transaction
            // — setting @FocusState synchronously inside it silently no-ops (verified via
            // CGEvent-driven clicks: the zone-level focus ring lit up, but typed keys never
            // reached the field). Letting the current transaction finish first, same idiom as
            // the Cmd+F-from-Detail-close case, is what actually claims focus.
            DispatchQueue.main.async {
                uiFocus = .searchSort
                searchSortFocusIdx = 0
                appState.searchEditing = true
            }
        }
        .onChange(of: uiFocus) { old, new in
            updateCarouselRing()
            // Navigating onto the widget expands it and holds it open; leaving restarts the
            // auto-minimize countdown.
            if new == .musicPlayer {
                musicPlayer.autoMinimizeSuspended = true
                musicPlayer.expand()
            } else if old == .musicPlayer {
                musicPlayer.autoMinimizeSuspended = false
                musicPlayer.scheduleAutoMinimize()
            }
        }
    }

    // MARK: - Startup Sequence

    // Pulled out of the `.onAppear { }` trailing closure — with the keyMonitor assignment
    // inlined there, the compiler bundled the whole thing into body's already-long modifier
    // chain and blew its type-check time budget. A plain method sidesteps that regardless of
    // how much either piece grows.
    private func onContentAppear() {
        startup()
        // NSEvent monitor routes key input based on the active UI focus zone — see
        // ContentView+Input.swift for the full routing table.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            routeKeyDown(event)
        }
        // The click that reclaims key-window status (mouseMonitor, below) and the click that
        // asks the search field to focus can land in the SAME mouse event — makeKeyAndOrderFront
        // isn't guaranteed to finish before that same event's dispatch reaches the TextField's
        // gesture recognizer, so the focus request can silently fail even though we "fixed" key
        // status a few lines earlier. didBecomeKeyNotification fires once the window genuinely
        // IS key; if the search field's Bool-level focus is already set at that point (the tap
        // gesture ran, it just landed too early), bump searchFieldResetToken to force the
        // TextField to retry now that the window can actually host a field editor.
        didBecomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
        ) { note in
            guard let win = note.object as? NSWindow, !(win is NSPanel) else { return }
            Task { @MainActor in
                if appState.searchEditing {
                    appState.searchFieldResetToken += 1
                }
            }
        }
    }

    private func startup() {
        startupTime = Date()
        controllerInput.bind(to: appState)
        // Debug hook: launch straight into a view mode (e.g. MARQUEE_VIEW=list) for testing.
        if let v = ProcessInfo.processInfo.environment["MARQUEE_VIEW"] {
            switch v {
            case "list": appState.viewMode = .list
            case "grid": appState.viewMode = .grid
            case "wall": appState.viewMode = .wall
            case "carousel": appState.viewMode = .carousel
            default: break
            }
        }
        // sourceFilter is persisted — a prior session's Hidden/Favorites filter could be stale
        // if that set emptied out since (e.g. defaults edited by hand), and the existing
        // hiddenVersion/favoritesVersion onChange guards only fire on a live change, not on
        // this cold read.
        if appState.sourceFilter == .hidden && !appState.hasHiddenGames { appState.sourceFilter = .all }
        if appState.sourceFilter == .favorites && !appState.hasFavorites { appState.sourceFilter = .all }

        appState.loadPlaceholders()
        carousel.loadGames(appState.filteredGames, animated: false)
        carousel.updateBackground(appState.currentTheme.sceneBackground)

        // Mouse click → switch input indicator to mouse.
        // .mouseMoved requires window.acceptsMouseMovedEvents; clicks are sufficient for detection.
        // otherMouseDown buttonNumber 3 is the mouse "back" side button (the controller/keyboard
        // equivalent is B / Esc) — controllers already have a dedicated back button and keyboard
        // users have Esc, so this is purely to give mouse-only users the same escape/back gesture.
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            appState.lastInputMethod = .mouse
            // Reclaim real key-window status on every click. Once this borderless window loses
            // key status (switching to another app and back, a Fix Cover/Banner panel or system
            // alert closing, ...) a plain click never restores it on its own — AppKit silently
            // leaves the window "frontmost" but not key, which breaks the search TextField's
            // ability to install a real field editor (buttons/gestures still work since those
            // don't require key-window status, only real text editing does). Reasserting it here,
            // ahead of the click reaching any SwiftUI gesture recognizer, means the TextField's
            // own focus request always lands on an already-key window.
            if let win = event.window, !win.isKeyWindow {
                // Calling activate/makeKeyAndOrderFront SYNCHRONOUSLY from inside a local event
                // monitor — still mid-dispatch of the very mouseDown that triggered it — silently
                // fails to actually claim key status. Deferring to the next run-loop turn, exactly
                // like the working reclaim in FixCoverPanel.close(), lets it land outside event
                // dispatch, where it reliably succeeds. didBecomeKeyObserver's searchFieldResetToken
                // bump is what makes the SwiftUI TextField retry its focus claim once this
                // actually lands.
                DispatchQueue.main.async {
                    NSApp.activate(ignoringOtherApps: true)
                    win.makeKeyAndOrderFront(nil)
                }
            }
            if event.type == .otherMouseDown && event.buttonNumber == 3 {
                appState.hoverIndex = nil
                if appState.fixCoverTarget != nil || appState.fixBannerTarget != nil {
                    appState.fixCoverTarget = nil
                    appState.fixBannerTarget = nil
                } else {
                    _ = handleNavKey(53)   // same path as the Esc key
                }
                updateCarouselRing()
                return nil
            }
            return event
        }

        // Logo fades in immediately
        withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) {
            logoOpacity = 1.0
            logoScale   = 1.0
            logoBlur    = 0
        }

        // Music widget starts expanded; collapse it after the inactivity window.
        musicPlayer.scheduleAutoMinimize()

        // Buy Me A Coffee badge dims 15s after launch — same beat as the music widget's own
        // auto-minimize, so the two "give the user a few seconds, then get out of the way" timers
        // feel consistent even though this one is a plain dim, not a collapse.
        Task {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            withAnimation(.easeInOut(duration: 1.0)) { coffeeButtonDimmed = true }
        }

        // Start loading — isReady fires when all art is fetched
        Task { await appState.loadAllGames() }

        // Safety valve: never block the user for more than 6 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 6.0) { revealApp() }
    }

    // The user's whole app (nav bar, carousel, etc.) is already opaque-covered by `logoOverlay`
    // while loading, but on a warm cache art fetch can finish in well under a second — too fast
    // to register as "a logo screen, then the app." Holding for a minimum beat makes the reveal
    // read as an intentional splash instead of the app just flickering into existence.
    private static let minSplashDuration: TimeInterval = 0.9

    private func revealApp() {
        guard !carouselReady else { return }  // idempotent — isReady and timeout can both fire

        let elapsed = Date().timeIntervalSince(startupTime)
        let remaining = Self.minSplashDuration - elapsed
        if remaining > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { revealApp() }
            return
        }

        // Reload carousel with real games + fully fetched art
        carousel.loadGames(appState.filteredGames, animated: false)
        applyArtToCarousel()

        // Entrance animation starts just as the logo begins to peel away
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            carousel.animateEntrance()
        }

        withAnimation(.easeOut(duration: 0.5)) {
            logoOpacity = 0
            logoBlur    = 20
            logoScale   = 1.08
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            showLogo = false
            withAnimation(.easeIn(duration: 0.2)) { carouselReady = true }
            NSApp.activate(ignoringOtherApps: true)
            // The search bar is the first thing focused on launch too, same as every subsequent
            // view-mode switch — skipped when onboarding hasn't run yet (no main content/search
            // bar exists to focus). No manual deferral needed here: the window may not be truly
            // key the instant this runs, but ContentView's didBecomeKeyObserver already bumps
            // searchFieldResetToken once it genuinely is, since searchEditing is already true
            // by then.
            if appState.artSourcePreference != .notConfigured {
                uiFocus = .searchSort
                searchSortFocusIdx = 0
                appState.searchEditing = true
            }
            if ProcessInfo.processInfo.environment["MARQUEE_SELFTEST"] != nil {
                SelfTests.runUUIDAudit(appState: appState)
            }
            if ProcessInfo.processInfo.environment["MARQUEE_SIZECHECK"] != nil {
                SelfTests.runSizeCheck(appState: appState)
            }
            // Debug hook: MARQUEE_AUTOPLAY=<title substring> fires the real PLAY path (fade +
            // minimize + process-watch + restore) for the matching game, to exercise the
            // game-session behaviour without hand-driving the GUI.
            if let q = ProcessInfo.processInfo.environment["MARQUEE_AUTOPLAY"]?.lowercased(),
               let g = appState.games.first(where: { $0.title.lowercased().contains(q) }) {
                print("[Marquee] AUTOPLAY → \(g.title)")
                session.launch(g)
            }
        }
    }

    // MARK: - Actions

    func applyArtToCarousel() {
        for (i, game) in appState.filteredGames.enumerated() {
            guard let path = game.localArtPath,
                  let image = NSImage(contentsOf: path) else { continue }
            carousel.applyArt(image: image, toGameAt: i)
        }
        carousel.applyFavorites(appState.favoriteGameIDs)
        // Grid/Wall/List's searchGreyscale equivalent — every call site that reloads the
        // carousel already calls this right after loadGames(), so it's the one choke point that
        // needs the dimming reapplied (loadGames rebuilds gameNodes from scratch each time).
        carousel.applySearchDimming { !appState.searchQuery.isEmpty && appState.matchScore(for: $0) == nil }
    }

    func navigateDelta(_ delta: Int) {
        let count = appState.filteredGames.count
        guard count > 0 else { return }
        let newIndex = ((appState.selectedIndex + delta) % count + count) % count
        guard newIndex != appState.selectedIndex else { return }
        soundEffects.play(.tick)   // every nav step — keyboard, controller, and scroll funnel here
        appState.selectedIndex = newIndex
        if appState.viewMode == .carousel {
            carousel.navigate(to: newIndex)
        }
    }

    func openDetail() {
        guard let game = appState.filteredGames[safe: appState.selectedIndex] else { return }
        openDetailFor(game)
    }

    // List view: Enter launches the selected game (no modal Detail page).
    func launchSelected() {
        guard let game = appState.filteredGames[safe: appState.selectedIndex] else { return }
        session.launch(game)
    }

    func closeDetail() {
        soundEffects.play(.back)
        withAnimation(.easeOut(duration: 0.25)) { appState.detailTarget = nil }
    }

    private func handleCarouselLeftClick(node: SCNNode) {
        var n: SCNNode? = node
        while let current = n {
            if let box = current as? GameBoxNode {
                let game = box.game
                if let idx = appState.filteredGames.firstIndex(where: { $0.id == game.id }) {
                    carousel.navigate(to: idx)
                    appState.selectedIndex = idx
                }
                openDetailFor(game)
                return
            }
            n = current.parent
        }
    }

    private func openDetailFor(_ game: Game) {
        soundEffects.play(.confirm)
        withAnimation(.easeIn(duration: 0.2)) { appState.detailTarget = game }
    }

    // Step to the previous/next game while the Detail page is open — same order + filter the
    // carousel/grid/wall/list were already showing (appState.filteredGames is the one shared
    // order every view mode indexes into), so switching views before/after Detail always lines
    // up. Keeps selectedIndex + the carousel's own position in sync so BACK lands correctly.
    func navigateDetail(_ delta: Int) {
        let games = appState.filteredGames
        guard games.count > 1 else { return }
        let curIdx = games.firstIndex(where: { $0.id == appState.detailTarget?.id }) ?? appState.selectedIndex
        let newIndex = ((curIdx + delta) % games.count + games.count) % games.count
        guard let newGame = games[safe: newIndex] else { return }
        soundEffects.play(.tick)
        appState.selectedIndex = newIndex
        if appState.viewMode == .carousel { carousel.navigate(to: newIndex) }
        appState.detailTarget = newGame
    }

    // Builds the AppKit right-click menu for one game. Shared by the carousel right-click and
    // the keyboard context-menu key. `includeBanner` adds "Fix Banner Art…" (List view only).
    // The MenuAction bridges are retained by each item's representedObject for the menu's life.
    private func makeGameMenu(for game: Game, includeBanner: Bool) -> NSMenu {
        let menu = NSMenu(title: "")
        let isHidden = appState.hiddenGameIDs.contains(game.id)

        func add(_ title: String, _ action: @escaping () -> Void) {
            let bridge = MenuAction(action)
            let item = NSMenuItem(title: title, action: #selector(MenuAction.run), keyEquivalent: "")
            item.target = bridge
            item.representedObject = bridge
            menu.addItem(item)
        }

        add("Fix Cover Art…") { [appState] in
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { appState.fixCoverTarget = game }
        }
        if includeBanner {
            add("Fix Banner Art…") { [appState] in
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { appState.fixBannerTarget = game }
            }
        }
        add(appState.isFavorite(game) ? "Remove Favorite" : "Add to Favorites") { [appState] in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { appState.toggleFavorite(game) }
        }
        menu.addItem(.separator())
        add(isHidden ? "Unhide Game" : "Hide Game") { [appState] in
            isHidden ? appState.unhideGame(game) : appState.hideGame(game)
        }
        return menu
    }

    // Opens the context menu for the currently-selected game via keyboard (menu/Shift-F10 key).
    // Banner option only in List view. Pops up near the window centre since there's no cursor.
    func presentSelectionContextMenu() {
        guard appState.detailTarget == nil,
              appState.fixCoverTarget == nil, appState.fixBannerTarget == nil,
              appState.artSourcePreference != .notConfigured,
              let game = appState.filteredGames[safe: appState.selectedIndex],
              let win = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }),
              let view = win.contentView else { return }
        let menu = makeGameMenu(for: game, includeBanner: appState.viewMode == .list)
        let p = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        menu.popUp(positioning: nil, at: p, in: view)
    }

    private func handleCarouselRightClick(node: SCNNode, event: NSEvent) {
        // Right-click acts on the SELECTED (front-and-center) game — the one the
        // user navigated to — NOT on whatever box the cursor happened to land on.
        // `carousel.selectedIndex` is the single source of truth for what's centered
        // (the box at offset 0), so it can't drift from what the user sees. We also
        // heal appState.selectedIndex to match, keeping the info bar consistent.
        let index = carousel.selectedIndex
        guard let game = appState.filteredGames[safe: index] else { return }
        if appState.selectedIndex != index { appState.selectedIndex = index }

        let menu = makeGameMenu(for: game, includeBanner: false)
        guard let view = event.window?.contentView else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    // Executes the focused action button on the Detail page (index: 0=Play, 1=Favorite, 2=Hide, 3=Back)
    func executeDetailAction(_ index: Int, game: Game) {
        switch index {
        case 0: session.launch(game)
        case 1:
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                appState.toggleFavorite(game)
            }
        case 2: appState.hideGame(game); closeDetail()
        case 3: closeDetail()
        default: break
        }
    }
}
