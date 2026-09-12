import SwiftUI
import AppKit
import AVKit

struct DetailView: View {
    let game: Game
    let boxController: DetailBoxController
    @Binding var focusedButton: Int    // 0=Play 1=Favorite 2=Hide 3=Back
    let onBack: () -> Void
    let onPrev: () -> Void
    let onNext: () -> Void

    @Environment(AppState.self) private var appState
    @Environment(GameSessionManager.self) private var session
    @Environment(MusicPlayerController.self) private var musicPlayer
    @State private var details: GameDetails
    @State private var appeared = false
    // Mouse-wheel step accumulator for the media rail (mirrors MarqueeSCNView.scrollWheel).
    @State private var railScrollMonitor: Any?
    @State private var railScrollAccumulator: CGFloat = 0

    // A tappable item in the media rail.
    private enum MediaItem: Identifiable {
        case screenshot(URL)
        case trailer(URL)
        var id: String {
            switch self {
            case .screenshot(let u): return "s:\(u.absoluteString)"
            case .trailer(let u):    return "t:\(u.absoluteString)"
            }
        }
    }

    // Trailer first (if present), then screenshots — the same order the rail renders in.
    // Both the mouse-wheel step and the keyboard/controller nav (routed through
    // AppState.detailMediaFocusIndex / detailMediaItemCount by ContentView's unified nav
    // router) index into this list.
    private var mediaItems: [MediaItem] {
        var items: [MediaItem] = []
        if let trailer = details.trailerURL { items.append(.trailer(trailer)) }
        items.append(contentsOf: details.screenshots.map { .screenshot($0) })
        return items
    }

    init(game: Game, boxController: DetailBoxController,
         focusedButton: Binding<Int>, onBack: @escaping () -> Void,
         onPrev: @escaping () -> Void, onNext: @escaping () -> Void) {
        self.game = game
        self.boxController = boxController
        self._focusedButton = focusedButton
        self.onBack = onBack
        self.onPrev = onPrev
        self.onNext = onNext
        _details = State(initialValue: .placeholder(for: game))
    }

    var body: some View {
        ZStack {
            // Opaque themed backdrop — hides the carousel behind the Detail page.
            appState.currentTheme.backgroundColor.ignoresSafeArea()
            if appState.currentTheme == .outerspace {
                OuterspaceBackground().opacity(0.9)
            }
            // This game's own blurred hero art — the same component every other view mode
            // already shows behind its content (rootStack's HeroBackground). Detail never got
            // it: its opaque theme fill sits in front of/hides rootStack's copy entirely, so
            // under a non-outerspace theme (no nebula pulse either) the page read as flat dead
            // black instead of "that game's backdrop." Rendering the SAME HeroBackground here,
            // keyed to this page's own `game` (not the shared selectedIndex), restores it while
            // still fully covering the carousel underneath (the blur+black overlay is opaque
            // enough on its own).
            if appState.heroBackgroundEnabled {
                HeroBackground(game: game)
            }
            // Particles only (no sine waves) so the detail art stays readable
            if appState.motionEnabled && appState.windowVisible {
                MotionOverlay(showWaves: false)
                    .opacity(0.5)
            }

            HStack(alignment: .top, spacing: 24) {
                leftColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 64)

                DetailBoxView(controller: boxController)
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: .infinity)
            }
            .padding(.top, 76)
            .padding(.bottom, (!details.screenshots.isEmpty || details.trailerURL != nil) ? 230 : 130)

            VStack(spacing: 0) {
                Spacer()
                if !details.screenshots.isEmpty || details.trailerURL != nil {
                    mediaRail
                        .padding(.bottom, 18)
                        .opacity(appeared ? 1 : 0)
                }
                actionBar
                    .padding(.horizontal, 40)
                    .padding(.bottom, 26)
            }

            // Prev/next game — tall translucent edge arrows following the same order + filter
            // the carousel/grid/wall/list were already showing, so the user can browse the whole
            // library from the Detail page without backing out each time. Mouse click, Cmd+Left/
            // Right, and controller L1/R1 (see ContentView.navigateDetail) all drive the same path.
            if appState.filteredGames.count > 1 {
                HStack(spacing: 0) {
                    detailNavArrow(systemName: "chevron.left", action: onPrev)
                    Spacer(minLength: 0)
                    detailNavArrow(systemName: "chevron.right", action: onNext)
                }
                .opacity(appeared ? 1 : 0)
            }

            // Enlarged screenshot / muted trailer — mouse click or keyboard/controller Enter to
            // open (via appState.detailMediaOverlayIndex), Esc/click-anywhere to dismiss.
            if let idx = appState.detailMediaOverlayIndex, let item = mediaItems[safe: idx] {
                mediaOverlayView(item)
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        // Pin explicitly to the known-good windowed size, same as ContentView.body does for
        // rootStack. Left unpinned, the HStack below (two `.frame(maxWidth: .infinity)` siblings,
        // one of them an SCNView-backed NSViewRepresentable) picks up an oversized ideal-size
        // proposal from SwiftUI's `.transition`-insertion layout pass and balloons past the real
        // window width, pushing the box art and action bar off-screen.
        .frame(width:  appState.isWindowFullScreen ? nil : appState.windowedContentSize.width,
               height: appState.isWindowFullScreen ? nil : appState.windowedContentSize.height)
        .onAppear {
            boxController.load(game: game, art: artImage())
            boxController.playEntrance()
            withAnimation(.easeOut(duration: 0.45)) { appeared = true }
            appState.detailMediaItemCount = mediaItems.count
            installRailScrollMonitor()
            Task {
                let fetched = await GameDetailsFetcher.shared.details(for: game)
                withAnimation(.easeOut(duration: 0.35)) { details = fetched }
            }
        }
        .onDisappear {
            if let monitor = railScrollMonitor { NSEvent.removeMonitor(monitor) }
            railScrollMonitor = nil
        }
        .onChange(of: details) { _, _ in
            appState.detailMediaItemCount = mediaItems.count
        }
        .onChange(of: appState.detailMediaFocusIndex) { _, new in
            guard let new, let proxy = railScrollProxy else { return }
            withAnimation { proxy.scrollTo(new, anchor: .center) }
        }
        // The one place that actually knows each media item's type — tells ContentView's nav
        // router (via appState.detailTrailerActive) whether Left/Right/Confirm should scrub/
        // pause the trailer or navigate rail tiles. Covers every way the overlay can close
        // (Esc, tap-to-dismiss, closing the whole Detail page) since they all route through
        // detailMediaOverlayIndex becoming nil.
        .onChange(of: appState.detailMediaOverlayIndex) { _, new in
            if let new, let item = mediaItems[safe: new], case .trailer = item {
                appState.detailTrailerActive = true
            } else {
                appState.detailTrailerActive = false
            }
        }
    }

    // Set by mediaRail's ScrollViewReader so both mouse-wheel stepping and keyboard/controller
    // focus changes (driven by ContentView's unified nav router) can scroll the focused tile
    // into view — the rail is a plain fixed-size ScrollView, so it can never scroll a tile
    // past its own bounds ("trapped in the viewport" rather than running off-screen).
    @State private var railScrollProxy: ScrollViewProxy?

    // Horizontal trackpad gestures step through the media rail. Vertical scrolling belongs to
    // the metadata/about column, including when it comes from a traditional mouse wheel.
    // NSEvent.addLocalMonitorForEvents' handler is treated as @Sendable/nonisolated by the
    // compiler even when declared lexically inside a @MainActor method (same class of issue as
    // decision #34's GCController callbacks) — the event's own scalar fields are read directly
    // (Sendable, no isolation needed), and the actual AppState/@State mutation is hopped onto
    // the main actor via a Task, mirroring that established pattern.
    @MainActor
    private func installRailScrollMonitor() {
        guard railScrollMonitor == nil else { return }
        railScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            let precise = event.hasPreciseScrollingDeltas
            let dx = event.scrollingDeltaX, dy = event.scrollingDeltaY
            let consumes = precise && abs(dx) > max(abs(dy), 1.0)
            guard consumes else { return event }
            Task { @MainActor in self.stepRail(precise: precise, dx: dx, dy: dy) }
            return nil
        }
    }

    @MainActor
    private func stepRail(precise: Bool, dx: CGFloat, dy: CGFloat) {
        let items = mediaItems
        guard !items.isEmpty else { return }
        func move(_ delta: Int) {
            let cur = appState.detailMediaFocusIndex ?? 0
            appState.detailMediaFocusIndex = max(0, min(items.count - 1, cur + delta))
        }
        if precise {
            railScrollAccumulator += dx
            while railScrollAccumulator >=  60 { railScrollAccumulator -= 60; move(-1) }
            while railScrollAccumulator <= -60 { railScrollAccumulator += 60; move(1) }
        } else {
            move(dy > 0 ? -1 : 1)
        }
    }

    // MARK: - Left column (logo + metadata + about)

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 22) {
            logo
                .frame(height: 120, alignment: .topLeading)
                .frame(maxWidth: 420, alignment: .leading)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 13) {
                        row("photo.on.rectangle", "Publisher", details.publisher)
                        row("calendar", "Release Date", details.releaseDate)
                        row("person.2.fill", "Players", details.players)
                        row("number", "Game ID", details.gameID)
                        row("internaldrive.fill", "File Size", details.fileSize)
                        row("mappin.and.ellipse", "Location", details.location, multiline: true)
                        row("paintpalette.fill", "Genre", details.genre)
                        row("clock.fill", "Playtime", AppState.formattedPlaytime(appState.playtime(for: game)))
                    }

                    Rectangle()
                        .fill(Color.white.opacity(0.14))
                        .frame(height: 1)

                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 12) {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(Color(red: 0.62, green: 0.5, blue: 0.95))
                                .frame(width: 22)
                            Text("ABOUT THE GAME")
                                .font(.system(size: 14, weight: .heavy))
                                .tracking(1.2)
                                .foregroundStyle(.white.opacity(0.95))
                        }
                        Text(details.about)
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(.white.opacity(0.82))
                            .lineSpacing(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: 470, maxHeight: .infinity)
        }
        .opacity(appeared ? 1 : 0)
        .offset(x: appeared ? 0 : -18)
    }

    @ViewBuilder
    private var logo: some View {
        if let url = details.logoURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let image):
                    image.resizable().scaledToFit()
                default:
                    titleFallback
                }
            }
        } else {
            titleFallback
        }
    }

    private var titleFallback: some View {
        Text(game.title)
            .font(.system(size: 44, weight: .black, design: .rounded))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 8, y: 3)
            .lineLimit(3)
            .minimumScaleFactor(0.5)
    }

    private func row(_ icon: String, _ label: String, _ value: String,
                     multiline: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Color(red: 0.62, green: 0.5, blue: 0.95))
                .frame(width: 22, alignment: .center)
            Text(label)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 124, alignment: .leading)
            Text(value)
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(multiline ? nil : 1)
                .truncationMode(multiline ? .tail : .middle)
                .fixedSize(horizontal: false, vertical: multiline)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: 470, alignment: .leading)
    }

    // MARK: - Bottom action bar
    // All buttons right-aligned as a group. White stroke highlights the keyboard-focused button.

    // The action bar's own focus ring only applies while focus is actually ON the action bar —
    // once Up moves focus into the media rail (appState.detailMediaFocusIndex != nil), the
    // selection outline belongs to the focused thumbnail there, not both places at once.
    private var actionBarActive: Bool { appState.detailMediaFocusIndex == nil }

    private var actionBar: some View {
        HStack(spacing: 14) {
            Spacer(minLength: 0)

            // PLAY — primary (focusedButton == 0). Hold-to-confirm (decisions.md #96): a plain
            // click no longer launches instantly, it has to hold for AppState.playHoldDuration.
            PlayHoldButton(game: game, cornerRadius: 16, onComplete: { session.launch(game) }) {
                HStack(spacing: 12) {
                    Image(systemName: "play.fill").font(.system(size: 22, weight: .bold))
                    Text("PLAY").font(.system(size: 24, weight: .heavy)).tracking(1)
                }
                .foregroundStyle(.white)
                .frame(width: 220, height: 70)
                .background(
                    LinearGradient(colors: [Color(red: 0.30, green: 0.62, blue: 1.0),
                                            Color(red: 0.16, green: 0.40, blue: 0.95)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: Color(red: 0.2, green: 0.45, blue: 1).opacity(0.5), radius: 14, y: 4)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(actionBarActive && focusedButton == 0 ? Color.white.opacity(0.9) : .clear, lineWidth: 2.5)
                )
            }
            .hoverHighlight(scale: 1.03, brighten: 0.08)
            .inputHint(actionBarActive && focusedButton == 0 ? .confirm : nil, method: appState.lastInputMethod)

            iconButton("star.fill", "Favorite", buttonIndex: 1,
                       active: appState.isFavorite(game), accent: .gold) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    appState.toggleFavorite(game)
                }
            }

            iconButton("eye.slash.fill", "Hide", buttonIndex: 2, active: false) {
                appState.hideGame(game)
                onBack()
            }

            // BACK — right-adjacent, no spacer before it
            Button { onBack() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "arrow.left").font(.system(size: 22, weight: .bold))
                    Text("BACK").font(.system(size: 24, weight: .heavy)).tracking(1)
                }
                .foregroundStyle(.white)
                .frame(width: 170, height: 70)
                .background(Color.white.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(actionBarActive && focusedButton == 3
                                      ? Color.white.opacity(0.9) : Color.white.opacity(0.18),
                                      lineWidth: actionBarActive && focusedButton == 3 ? 2.5 : 1)
                )
            }
            .buttonStyle(.plain)
            .inputHint(actionBarActive && focusedButton == 3 ? .confirm : nil, method: appState.lastInputMethod)
        }
    }

    private enum Accent { case neutral, gold }

    private func iconButton(_ icon: String, _ label: String, buttonIndex: Int,
                            active: Bool, accent: Accent = .neutral,
                            action: @escaping () -> Void) -> some View {
        let gold = Color(red: 1.0, green: 0.78, blue: 0.25)
        let tint: Color = (accent == .gold && active) ? gold : .white
        let isFocused = actionBarActive && focusedButton == buttonIndex
        let borderColor: Color = isFocused
            ? .white.opacity(0.9)
            : (accent == .gold && active) ? gold : .white.opacity(0.12)
        let borderWidth: CGFloat = isFocused ? 2.5 : (accent == .gold && active) ? 2 : 1
        return Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 21, weight: .semibold))
                Text(label).font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(tint)
            .frame(width: 78, height: 70)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: borderWidth)
            )
        }
        .buttonStyle(.plain)
        .inputHint(isFocused ? .confirm : nil, method: appState.lastInputMethod)
    }

    // MARK: - Prev/Next edge arrows

    private func detailNavArrow(systemName: String, action: @escaping () -> Void) -> some View {
        // The tappable column spans the whole page height (click anywhere in it to page), but
        // the hint badge needs to sit right next to the chevron GLYPH, which is vertically
        // centered — attaching `.inputHint` to the full-height column (the old approach) put the
        // badge at the column's bottom-trailing corner, i.e. the bottom of the screen, nowhere
        // near the arrow a user is actually looking at. Scoping the hint to just the (small,
        // centered) Image fixes that: the ZStack still fills/clips the full column for hit-
        // testing via the Color.clear layer, independent of where the badge lands.
        Button(action: action) {
            ZStack {
                Color.clear.contentShape(Rectangle())
                Image(systemName: systemName)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.32))
                    // Static hint (not focus-gated — these arrows aren't part of the action-bar
                    // tab order, they're always reachable via ⌘←/⌘→ or a controller shoulder button).
                    .inputHint(systemName == "chevron.left"
                               ? .directional(keyboard: "⌘←", controller: "L1")
                               : .directional(keyboard: "⌘→", controller: "R1"),
                               method: appState.lastInputMethod)
            }
            .frame(width: 72)
            .frame(maxHeight: .infinity)
        }
        .buttonStyle(.plain)
        .hoverHighlight(scale: 1.0, brighten: 0.35)
        .help(systemName == "chevron.left" ? "Previous Game (⌘←)" : "Next Game (⌘→)")
    }

    private func artImage() -> NSImage? {
        guard let path = game.localArtPath else { return nil }
        return NSImage(contentsOf: path)
    }

    // MARK: - Media rail (screenshots + trailer)
    // A plain fixed-height ScrollView — content can never escape its own bounds ("trapped in
    // the viewport"), scrollable by trackpad natively, by mouse wheel via installRailScrollMonitor,
    // and by keyboard/controller via appState.detailMediaFocusIndex (set by ContentView's nav
    // router), which this view scrolls into view via railScrollProxy.

    private var mediaRail: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(Array(mediaItems.enumerated()), id: \.element.id) { idx, item in
                        mediaTile(for: item, idx: idx)
                            .id(idx)
                            .onTapGesture {
                                appState.detailMediaFocusIndex = idx
                                appState.detailMediaOverlayIndex = idx
                            }
                    }
                }
                .padding(.horizontal, 40)
            }
            .frame(height: 118)
            .onAppear { railScrollProxy = proxy }
        }
    }

    @ViewBuilder
    private func mediaTile(for item: MediaItem, idx: Int) -> some View {
        let isFocused = appState.detailMediaFocusIndex == idx
        Group {
            switch item {
            case .trailer:
                // Trailer thumbnail = the first screenshot if we have one, else a dark card.
                if let thumb = details.screenshots.first {
                    AsyncImage(url: thumb) { $0.resizable().scaledToFill() }
                    placeholder: { Color.black.opacity(0.35) }
                } else {
                    Color.black.opacity(0.35)
                }
            case .screenshot(let url):
                AsyncImage(url: url) { $0.resizable().scaledToFill() }
                placeholder: { Color.white.opacity(0.06) }
            }
        }
        .frame(width: 200, height: 112)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isFocused ? Color.white.opacity(0.9) : Color.white.opacity(0.15),
                              lineWidth: isFocused ? 2.5 : 1)
        )
        .overlay {
            if case .trailer = item {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.6), radius: 6)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .hoverHighlight()
    }

    @ViewBuilder
    private func mediaOverlayView(_ item: MediaItem) -> some View {
        ZStack {
            Color.black.opacity(0.82).ignoresSafeArea()
            switch item {
            case .screenshot(let url):
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    ProgressView().controlSize(.large)
                }
                .padding(60)
            case .trailer(let url):
                TrailerPlayer(url: url)
                    .environment(musicPlayer)
                    .padding(60)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { appState.detailMediaOverlayIndex = nil }
    }
}

// An autoplaying, looping trailer for the Detail media overlay. Crossfades with the
// background music: the music fades out while the trailer's own audio fades in, starting
// at (and only ever fading back to) the level the background music was playing at — never
// the background music's *slider* value directly, so if the user rides the trailer's own
// volume during playback that never touches `musicPlayer.volume` (they're two fully
// independent AVAudioEngine/AVPlayer graphs; nothing wires one's output to the other). On
// close, the music resumes fading back in to the level it was left at.
private struct TrailerPlayer: View {
    let url: URL
    @Environment(AppState.self) private var appState
    @Environment(MusicPlayerController.self) private var musicPlayer
    @State private var player: AVPlayer?
    @State private var looper: Any?
    @State private var fadeTask: Task<Void, Never>?

    // eShop-style HUD flashes — a center play/pause glyph on toggle, a corner "»» +20s" readout
    // while scrubbing. Each carries its own token so a fresh flash restarts the auto-hide timer
    // instead of racing a stale one to clear it early.
    @State private var flashSymbol: String?
    @State private var flashToken = UUID()
    @State private var scrubLabel: String?
    @State private var scrubToken = UUID()

    var body: some View {
        Group {
            if let player {
                // AVKit's SwiftUI `VideoPlayer` crashes on first instantiation on this build
                // (a Swift-runtime generic-metadata fatal error inside _AVKit_SwiftUI's view
                // machinery, verified via a live crash report — nothing to do with our own
                // AVPlayerLooper setup below). The plain AppKit `AVPlayerView` is the same
                // underlying player UI without that SwiftUI wrapper, so it sidesteps the bug.
                AVPlayerViewRepresentable(player: player)
                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        if let flashSymbol {
                            Image(systemName: flashSymbol)
                                .font(.system(size: 46, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(26)
                                .background(Circle().fill(Color.black.opacity(0.45)))
                                .transition(.opacity.combined(with: .scale(scale: 0.7)))
                                .id(flashToken)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if let scrubLabel {
                            Text(scrubLabel)
                                .font(.system(size: 15, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(Capsule().fill(Color.black.opacity(0.55)))
                                .padding(.bottom, 16)
                                .transition(.opacity)
                                .id(scrubToken)
                        }
                    }
                    .animation(.easeOut(duration: 0.15), value: flashSymbol)
                    .animation(.easeOut(duration: 0.15), value: scrubLabel)
            } else {
                ProgressView().controlSize(.large)
            }
        }
        .onChange(of: appState.trailerCommand) { _, cmd in
            guard let player else { return }
            switch cmd {
            case .togglePlayPause:
                if player.timeControlStatus == .playing {
                    player.pause()
                    flashPlayPause(playing: false)
                } else {
                    player.play()
                    flashPlayPause(playing: true)
                }
            case .scrub(let seconds):
                let current = CMTimeGetSeconds(player.currentTime())
                var target = current + seconds
                if let duration = player.currentItem?.duration.seconds, duration.isFinite {
                    target = min(max(0, target), duration)
                } else {
                    target = max(0, target)
                }
                player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                             toleranceBefore: .zero, toleranceAfter: .zero)
                flashScrub(seconds: seconds)
            case .none:
                break
            }
            appState.trailerCommand = .none
        }
        .onAppear {
            // AVPlayerLooper requires the AVQueuePlayer it's handed to be empty at init time —
            // constructing the queue with the item already enqueued (the old code) throws an
            // uncaught NSInvalidArgumentException that takes the whole app down. Create the
            // queue empty and let the looper own inserting/repeating the item instead.
            let item = AVPlayerItem(url: url)
            let queue = AVQueuePlayer()
            queue.volume = 0   // ramped up below, in lockstep with the music fading out
            // The floating AirPlay/cast icon AVPlayerView shows top-left is driven by the
            // player's own external-playback capability, not a view-level toggle — there's no
            // `showsAirPlayButton` on AVPlayerView. We don't implement casting, so turn off the
            // capability itself and the button disappears with it.
            queue.allowsExternalPlayback = false
            looper = AVPlayerLooper(player: queue, templateItem: item)
            player = queue
            queue.play()

            // Crossfade: background music fades to silence (and pauses, so it resumes from
            // the exact same spot) while the trailer's audio fades UP TO the level the music
            // was playing at — that's the target, not 100%, so the trailer doesn't suddenly
            // feel louder than what it's replacing.
            let target = musicPlayer.volume
            fadeTask?.cancel()
            fadeTask = Task {
                async let bg: () = musicPlayer.fadeOutAndPause()
                async let vid: () = Self.fadeVolume(queue, to: target)
                _ = await (bg, vid)
            }
        }
        .onDisappear {
            fadeTask?.cancel()
            player?.pause()
            player = nil
            looper = nil
            // Resume the background music from where it was paused, fading back up to
            // musicPlayer.volume (the user's persisted slider level) regardless of whatever
            // volume the trailer itself ended up at.
            fadeTask = Task { await musicPlayer.resumeFadingIn() }
        }
    }

    // Center play/pause glyph — the eShop "you just pressed a button" acknowledgment.
    private func flashPlayPause(playing: Bool) {
        flashSymbol = playing ? "play.fill" : "pause.fill"
        let token = UUID(); flashToken = token
        Task {
            try? await Task.sleep(nanoseconds: 550_000_000)
            if flashToken == token { flashSymbol = nil }
        }
    }

    // Bottom-center skip readout — direction glyph + magnitude, so a fast accelerating skip
    // reads clearly even without watching the scrub bar.
    private func flashScrub(seconds: Double) {
        let arrows = seconds >= 0 ? "»»" : "««"
        scrubLabel = "\(arrows) \(Int(abs(seconds)))s"
        let token = UUID(); scrubToken = token
        Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if scrubToken == token { scrubLabel = nil }
        }
    }

    private static func fadeVolume(_ player: AVPlayer, to target: Float, over duration: TimeInterval = 2.0) async {
        let steps = 40
        let interval = duration / Double(steps)
        for i in 1...steps {
            if Task.isCancelled { break }
            player.volume = target * Float(i) / Float(steps)
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }
        player.volume = target
    }
}

// Plain AppKit AVPlayerView (AVKit, NOT the crashing _AVKit_SwiftUI `VideoPlayer`) — shows
// playback controls on hover like VideoPlayer did, without the SwiftUI wrapper's metadata bug.
private struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.showsSharingServiceButton = false   // top-left share/AirPlay icon — unimplemented, hide it
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}
