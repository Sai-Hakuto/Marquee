import SwiftUI

// Row geometry — shared between the row view and the hover hit-testing math (see ListView's
// identical pattern, which this mirrors for the same reason: a per-row .onHover misfires as the
// right detail panel rebuilds on every selection change).
private let compactRowHeight: CGFloat = 40
private let compactRowGap: CGFloat = 2

// Row list took half the window (matching List's own 50/50 split) — cut 40% narrower (0.5 * 0.6)
// per live feedback, since a dense single-line table needs far less width than List's banner-art
// rows, and the freed space lets the detail panel lean on full hero art instead.
private let compactListColumnFraction: CGFloat = 0.3

// 6th view mode, Playnite-inspired (Jack supplied a reference screenshot of Playnite's own list
// view): a master/detail split like the existing List mode, but the LEFT column is a dense,
// flat single-line table — small icon, title, source badge, playtime — instead of List's
// full-bleed banner-art rows. The right half is `CompactDetailPanel` (below), its own
// hero-art-backed layout distinct from List's `ListDetailPanel` — the whole point of this mode
// is to read like Playnite's compact list, where the selected game's key art fills the panel as
// a backdrop with title/actions/metadata overlaid on it, not a separate spinning 3D case.
struct CompactListView: View {
    @Environment(AppState.self) private var appState
    @Environment(SoundEffects.self) private var soundEffects
    let games: [Game]
    @Binding var selectedIndex: Int
    var actionsFocused: Bool = false
    var actionFocusIdx: Int = 0
    var searchSortActive: Bool = false
    var searchSortFocusIdx: Int = 0

    private func highlighted(_ idx: Int) -> Bool {
        if let h = appState.hoverIndex { return idx == h }
        return appState.lastInputMethod != .mouse && idx == selectedIndex
    }

    private var selectedGame: Game? { games[safe: selectedIndex] }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                listColumn
                    .frame(width: geo.size.width * compactListColumnFraction)

                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 1)

                CompactDetailPanel(game: selectedGame, actionsFocused: actionsFocused, actionFocusIdx: actionFocusIdx)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Warms every game's hero art into HeroArtPreloader up front, keyed off the actual game
        // set + coverFixVersion so a filter/sort/Fix-Cover change re-warms — see the preloader's
        // own doc comment for why this exists (the per-row flash this fixes).
        .task(id: HeroWarmKey(ids: games.map(\.id), fixVersion: appState.coverFixVersion)) {
            await HeroArtPreloader.shared.warm(games, fixVersion: appState.coverFixVersion)
        }
    }

    private func hoverIndex(at y: CGFloat) -> Int? {
        guard y >= 0 else { return nil }
        let slot = compactRowHeight + compactRowGap
        let idx = Int(y / slot)
        let within = y - CGFloat(idx) * slot
        guard idx >= 0, idx < games.count, within <= compactRowHeight else { return nil }
        return idx
    }

    private var listColumn: some View {
        VStack(spacing: 0) {
            SearchSortBar(isActive: searchSortActive, focusIdx: searchSortFocusIdx, widthFraction: 2.0 / 3.0)
                .padding(.horizontal, 20)
                .padding(.top, 5)

            compactRows
        }
    }

    private var compactRows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: compactRowGap) {
                    ForEach(Array(games.enumerated()), id: \.element.id) { idx, game in
                        CompactListRow(game: game, isHighlighted: highlighted(idx))
                            .onTapGesture {
                                appState.lastInputMethod = .mouse
                                selectedIndex = idx
                            }
                            .contextMenu { GameContextMenu(game: selectedGame ?? game, showFixBanner: true) }
                    }
                }
                .coordinateSpace(name: "compactRows")
                .onContinuousHover(coordinateSpace: .named("compactRows")) { phase in
                    switch phase {
                    case .active(let p):
                        if let idx = hoverIndex(at: p.y) {
                            if appState.hoverIndex != idx { soundEffects.play(.tick) }
                            appState.lastInputMethod = .mouse
                            appState.hoverIndex = idx
                            selectedIndex = idx
                        } else {
                            appState.hoverIndex = nil
                        }
                    case .ended:
                        appState.hoverIndex = nil
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, MusicWidget.collapsedClearance)
            }
            .onChange(of: selectedIndex) { _, newVal in
                if appState.lastInputMethod != .mouse, let id = games[safe: newVal]?.id {
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }
}

// MARK: - Row (Playnite-style flat table line)

private struct CompactListRow: View {
    @Environment(AppState.self) private var appState
    let game: Game
    let isHighlighted: Bool

    // The shared `AppState.formattedPlaytime` spells this out as "Not played yet" — reads fine
    // in the roomier Detail/List panels, but this column is only 84pt wide, so that phrase wraps
    // into a stacked two-line mess (Jack: "looks stupid"). A bare dash reads as "N/A" at a glance
    // without needing the room.
    private var compactPlaytimeText: String {
        let seconds = appState.playtime(for: game)
        return seconds > 0 ? AppState.formattedPlaytime(seconds) : "–"
    }

    var body: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(Color.white)
                .frame(width: 3, height: 22)
                .opacity(isHighlighted ? 1 : 0)

            GameArtImage(game: game)
                .id("\(appState.coverFixVersion)#\(appState.artVersion)")
                .aspectRatio(1, contentMode: .fill)
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            Text(game.title)
                .font(.system(size: 14, weight: isHighlighted ? .semibold : .regular))
                .foregroundStyle(.white.opacity(isHighlighted ? 1 : 0.82))
                .lineLimit(1)

            if appState.isFavorite(game) {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color(red: 1.0, green: 0.80, blue: 0.25))
            }

            Spacer(minLength: 8)

            Text(compactPlaytimeText)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 84, alignment: .trailing)
                .lineLimit(1)

            SourceBadge(game: game, size: .mini)
                .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .frame(height: compactRowHeight)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHighlighted ? Color.white.opacity(0.12) : Color.white.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(isHighlighted ? Color.white.opacity(0.5) : .clear, lineWidth: 1.5)
        )
        .searchMatchGlow(active: appState.matchScore(for: game) != nil, selected: isHighlighted, radius: 8)
        .searchGreyscale(active: !appState.searchQuery.isEmpty && appState.matchScore(for: game) == nil)
    }
}

// MARK: - Hero art in-memory preloader

// Identifies one "warm the whole list" pass — re-triggered whenever the game set changes (a
// filter/search/sort reorder) or a Fix Cover override could have changed which hero resolves.
private struct HeroWarmKey: Equatable {
    let ids: [UUID]
    let fixVersion: Int
}

// Fixes the "cover art flashes for a split second before hero art loads in" complaint: the
// previous per-selection `.task(id: game.id)` re-did the actor-hop + disk check + NSImage decode
// on every single hover step, so scrolling through the row list at any real speed never won the
// race — nearly every row showed the loading fallback, never the hero, until the user stopped
// moving. This keeps a resolved NSImage (or a confirmed `nil` — no hero exists) in memory per
// game id, warmed for the WHOLE visible list as soon as Compact List is on screen, so any
// already-warmed selection is a synchronous cache read with no flash at all. Keyed by
// `coverFixVersion` (same invalidation signal every other art view in this file already uses) so
// a Fix Cover override can't leave a stale hero cached forever.
@MainActor
private final class HeroArtPreloader {
    static let shared = HeroArtPreloader()
    private var cache: [UUID: NSImage?] = [:]
    private var cachedFixVersion: Int = -1

    // Synchronous peek — returns nil (no answer yet) if this game hasn't been resolved under the
    // current fixVersion, `.some(nil)` if it's resolved to "no hero exists", `.some(.some(image))`
    // if it's ready to show. Lets the detail panel skip straight to the cached result instead of
    // clearing to nil-then-refetching whenever the preloader already has the answer.
    func peek(_ id: UUID, fixVersion: Int) -> NSImage?? {
        guard fixVersion == cachedFixVersion else { return nil }
        return cache[id]
    }

    func hero(for game: Game, fixVersion: Int) async -> NSImage? {
        if fixVersion != cachedFixVersion { cache.removeAll(); cachedFixVersion = fixVersion }
        if let cached = cache[game.id] { return cached }
        let url = await ArtFetcher.shared.fetchHero(for: game)
        let image = url.flatMap { NSImage(contentsOf: $0) }
        cache[game.id] = image
        return image
    }

    func warm(_ games: [Game], fixVersion: Int) async {
        for game in games {
            _ = await hero(for: game, fixVersion: fixVersion)
        }
    }
}

// MARK: - Right — hero-art detail panel (Playnite-style)

// Unlike List's `ListDetailPanel` (a spinning 3D case over a plain panel), Compact List leans
// entirely on the selected game's own wide hero art as the panel's backdrop — title, actions,
// and metadata are overlaid directly on it behind a bottom scrim, matching the reference
// screenshot Jack supplied of Playnite's own compact list + detail layout.
private struct CompactDetailPanel: View {
    @Environment(AppState.self) private var appState
    @Environment(GameSessionManager.self) private var session
    let game: Game?
    var actionsFocused: Bool = false
    var actionFocusIdx: Int = 0    // 0=Play, 1=Favorite, 2=Hide

    @State private var heroImage: NSImage?
    @State private var details: GameDetails?

    private let accent = Color(red: 0.62, green: 0.5, blue: 0.95)

    var body: some View {
        Group {
            if let game {
                content(for: game)
            } else {
                VStack {
                    Spacer()
                    Text("No game selected")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                    Spacer()
                }
            }
        }
        .task(id: game?.id) {
            guard let game else { heroImage = nil; details = nil; return }
            details = .placeholder(for: game)
            // A cache hit (the common case once CompactListView's own warm pass has run) reads
            // synchronously — no nil frame, no flash. Only a genuinely not-yet-warmed game (the
            // very first row shown before warming completes) falls through to a real fetch.
            if let cached = HeroArtPreloader.shared.peek(game.id, fixVersion: appState.coverFixVersion) {
                heroImage = cached
            } else {
                heroImage = nil
                let image = await HeroArtPreloader.shared.hero(for: game, fixVersion: appState.coverFixVersion)
                withAnimation(.easeInOut(duration: 0.4)) { heroImage = image }
            }
            details = await GameDetailsFetcher.shared.details(for: game)
        }
    }

    private func content(for game: Game) -> some View {
        ZStack(alignment: .bottomLeading) {
            backdrop(for: game)
            bottomBlock(for: game)
        }
        .id(appState.coverFixVersion)   // re-load art after a Fix Cover override
    }

    // The selected game's hero art, centered and fully visible (never cropped/cover art, see the
    // v0.34.0 note below) over a blurred atmosphere layer, with a bottom scrim so the overlaid
    // text/buttons stay legible regardless of what the art looks like there.
    //
    // Deliberately NOT a `GeometryReader { geo in ... .frame(width: geo.size.width, ...) }` —
    // this panel already sits inside a GeometryReader-sized HStack cell (CompactListView.body),
    // and nesting a second GeometryReader here corrupted hit-testing for its SIBLING: the panel
    // still painted/clipped correctly to its own ~70% column, but mouse clicks/hover meant for
    // the row list to its left silently stopped reaching it (decisions.md — Compact List mouse
    // click/scroll bug). A plain `.frame(maxWidth: .infinity, maxHeight: .infinity).clipped()`
    // fills the same cell without a second GeometryReader and doesn't have the bug.
    // Hosted as an .overlay on a proposal-sized Color.clear, NOT as a free-standing
    // `.frame(maxWidth: .infinity, maxHeight: .infinity)` — that frame is a floor, not a
    // ceiling: with no explicit min bound, an oversized child (scaledToFill art whose aspect
    // doesn't match the panel's) becomes the frame's own reported size, inflating the whole
    // HStack. The visible fallout was the entire view mode's layout being vertically centered
    // around an off-window backdrop: the row list shoved hundreds of points down on hover
    // (every selection change swapped in differently-sized art) and its ScrollView proposed
    // enough height to "fit" every row, leaving the wheel nothing to scroll. Overlay content
    // can never influence the host's layout, so this contains any art aspect by construction
    // (same scaledToFill trap as the v0.21.2 grid-tile fix, reintroduced when the nested
    // GeometryReader was removed here for its sibling hit-testing corruption).
    //
    // Still NOT .ignoresSafeArea() (expanded the hit-test region over the whole window) and
    // still no GeometryReader (corrupted sibling hit-testing) — see decisions.md #106.
    //
    // **v0.34.0 (Round 10 live feedback):** replaced the v0.33.0 full-bleed/trailing-anchored
    // crop entirely. A ~3:1 Steam `library_hero.jpg` scaledToFill against this much-taller panel
    // still needed a huge crop no matter which edge it anchored to — the visible slice ended up
    // so zoomed in it read as an abstract color blob, not recognizable art. Fixed by backing off
    // the zoom instead of choosing a different crop: the full hero image now fits (never crops)
    // centered in the panel, on top of a blurred, darkened scaledToFill copy of the SAME image for
    // atmosphere (the same blurred-backdrop + crisp-inset language the old cover fallback used,
    // now applied to the hero itself). Jack's explicit ask this round was also to never show
    // cover/box art in this panel at all — the fallback for "no hero resolved" is now just the
    // flat gradient; a missing/loading hero shows atmosphere only, never a game's cover.
    @ViewBuilder
    private func backdrop(for game: Game) -> some View {
        Color.clear
            .overlay {
                ZStack {
                    if let heroImage {
                        Image(nsImage: heroImage)
                            .resizable()
                            .scaledToFill()
                            .blur(radius: 12.8)
                            .brightness(-0.15)
                        Image(nsImage: heroImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
                            .padding(56)
                            .transition(.opacity)
                    } else {
                        LinearGradient(colors: [Color(red: 0.16, green: 0.06, blue: 0.26), .black],
                                       startPoint: .top, endPoint: .bottom)
                    }
                    LinearGradient(
                        colors: [.clear, .clear, .black.opacity(0.55), .black.opacity(0.93)],
                        startPoint: .top, endPoint: .bottom
                    )
                }
            }
            .clipped()
            .allowsHitTesting(false)   // pure backdrop — never intercept row-list/scroll input
    }

    private func bottomBlock(for game: Game) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                Text(game.title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 8, y: 2)
                    .lineLimit(2)
                    .minimumScaleFactor(0.6)
                HStack(spacing: 8) {
                    SourceBadge(game: game)
                    if !game.isInstalled {
                        Text("NOT INSTALLED")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.15)))
                    }
                }
            }

            actions(for: game)

            if let d = details {
                HStack(alignment: .top, spacing: 32) {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionLabel("DETAILS")
                        metaRow("Time Played", AppState.formattedPlaytime(appState.playtime(for: game)))
                        metaRow("Last Played", lastPlayedText(for: game))
                        metaRow("Publisher", d.publisher)
                        metaRow("Release Date", d.releaseDate)
                        metaRow("Genre", d.genre)
                        metaRow("Players", d.players)
                    }
                    .frame(width: 230, alignment: .leading)

                    VStack(alignment: .leading, spacing: 8) {
                        sectionLabel("DESCRIPTION")
                        ScrollView {
                            Text(d.about)
                                .font(.system(size: 13))
                                .foregroundStyle(.white.opacity(0.85))
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 150)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.horizontal, 30)
        .padding(.top, 20)
        .padding(.bottom, MusicWidget.collapsedClearance + 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .heavy))
            .tracking(1.2)
            .foregroundStyle(accent)
    }

    private func metaRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(2)
                .truncationMode(.tail)
        }
    }

    private func lastPlayedText(for game: Game) -> String {
        guard let date = appState.lastPlayed(for: game) else { return "Never" }
        if Calendar.current.isDateInToday(date) { return "Today" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }

    // The Detail-page actions, surfaced inline on Compact List's panel — same PLAY hold-to-
    // confirm gate + Favorite/Hide icons as List's own panel (ListView.swift's `ListDetailPanel`),
    // just laid out here since the two panels no longer share a container.
    private func actions(for game: Game) -> some View {
        HStack(spacing: 12) {
            PlayHoldButton(game: game, cornerRadius: 13, onComplete: { session.launch(game) }) {
                HStack(spacing: 10) {
                    Image(systemName: "play.fill").font(.system(size: 16, weight: .bold))
                    Text("PLAY").font(.system(size: 17, weight: .heavy)).tracking(1)
                }
                .foregroundStyle(.white)
                .frame(width: 160, height: 48)
                .background(
                    LinearGradient(colors: [Color(red: 0.30, green: 0.62, blue: 1.0),
                                            Color(red: 0.16, green: 0.40, blue: 0.95)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .shadow(color: Color(red: 0.2, green: 0.45, blue: 1).opacity(0.45), radius: 10, y: 3)
                .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(actionsFocused && actionFocusIdx == 0 ? Color.white.opacity(0.9) : .clear, lineWidth: 2.5)
                )
            }
            .hoverHighlight(scale: 1.03, brighten: 0.08)
            .inputHint(actionsFocused && actionFocusIdx == 0 ? .confirm : nil, method: appState.lastInputMethod)

            iconAction("star.fill", active: appState.isFavorite(game),
                       tint: Color(red: 1.0, green: 0.78, blue: 0.25),
                       focused: actionsFocused && actionFocusIdx == 1) {
                withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                    appState.toggleFavorite(game)
                }
            }

            iconAction("eye.slash.fill", active: false, tint: .white,
                       focused: actionsFocused && actionFocusIdx == 2) {
                appState.hideGame(game)
            }
        }
    }

    private func iconAction(_ icon: String, active: Bool, tint: Color, focused: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(active ? tint : .white)
                .frame(width: 48, height: 48)
                .background(Color.white.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(focused ? Color.white.opacity(0.9) : (active ? tint : Color.white.opacity(0.18)),
                                      lineWidth: focused ? 2.5 : (active ? 2 : 1))
                )
                .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverHighlight(scale: 1.08, brighten: 0.1)
        .inputHint(focused ? .confirm : nil, method: appState.lastInputMethod)
    }
}
