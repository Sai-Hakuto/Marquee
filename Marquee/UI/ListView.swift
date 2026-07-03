import SwiftUI

// Row geometry — shared between the row view and the hover hit-testing math below so
// they can never drift out of sync.
private let listBandHeight: CGFloat = 86
private let listBandGap: CGFloat = 10

// List view (4th layout mode) — a master/detail split.
//
// LEFT half  : a scrollable list of games. Each row uses landscape Steam header art
//              (falling back to the portrait cover) with the title + source overlaid.
// RIGHT half : an inline detail panel for the highlighted game — a large portrait poster,
//              the Play/Favorite/Hide actions (the same options the modal Detail page offers),
//              and a block of metadata + description beneath.
//
// Clicking a row selects it (updating the right panel) — it does NOT open the modal Detail
// page. Enter launches the selected game.
struct ListView: View {
    @Environment(AppState.self) private var appState
    @Environment(SoundEffects.self) private var soundEffects
    let games: [Game]
    @Binding var selectedIndex: Int
    // Keyboard/controller focus on the right panel's Play/Favorite/Hide row — driven by
    // ContentView's unified nav router (UIFocusZone.listActions), mirroring how the Detail
    // page's action bar drives its own focusedButton.
    var actionsFocused: Bool = false
    var actionFocusIdx: Int = 0
    // Search/sort bar focus (UIFocusZone.searchSort) — same values ContentView passes to the
    // global SearchSortBar in every other view mode; List renders its own copy, constrained to
    // just this column, instead of the global one (see ContentView.mainContent's .list case).
    var searchSortActive: Bool = false
    var searchSortFocusIdx: Int = 0

    private func highlighted(_ idx: Int) -> Bool {
        if let h = appState.hoverIndex { return idx == h }
        return appState.lastInputMethod != .mouse && idx == selectedIndex
    }

    private var selectedGame: Game? { games[safe: selectedIndex] }

    var body: some View {
        HStack(spacing: 0) {
            listColumn
                .frame(maxWidth: .infinity)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1)

            ListDetailPanel(game: selectedGame, actionsFocused: actionsFocused, actionFocusIdx: actionFocusIdx)
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: Left — the scrollable row list

    // Bulletproof hover: instead of a flaky per-row `.onHover` (which misfires inside a
    // ScrollView as rows re-layout and the right detail panel rebuilds), a single
    // `.onContinuousHover` over the whole row stack maps the pointer's y-position to a row
    // index using the fixed row geometry. Pixel-accurate, immune to re-renders, and the
    // gaps between rows correctly register as "no row".
    private func hoverIndex(at y: CGFloat) -> Int? {
        guard y >= 0 else { return nil }
        let slot = listBandHeight + listBandGap
        let idx = Int(y / slot)
        let within = y - CGFloat(idx) * slot
        guard idx >= 0, idx < games.count, within <= listBandHeight else { return nil }
        return idx
    }

    private var listColumn: some View {
        VStack(spacing: 0) {
            // widthFraction 2/3 (double the 1/3 default carousel/grid/wall use): List's instance
            // is constrained to just this column, roughly half the window, so 1/3 of THAT came
            // out visibly smaller than the global bar. Top padding 5 (was 12) centers the bar in
            // its slot — measured via pixel-sampled screenshots: the gap above it (nav bar down
            // to here) was ~30pt against only ~4pt below it (down to the first row), i.e. the bar
            // sat low in its own space; `listRows`' own top padding picks up the rest (see below).
            SearchSortBar(isActive: searchSortActive, focusIdx: searchSortFocusIdx, widthFraction: 2.0 / 3.0)
                .padding(.horizontal, 20)
                .padding(.top, 5)

            listRows
        }
    }

    private var listRows: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: listBandGap) {
                    ForEach(Array(games.enumerated()), id: \.element.id) { idx, game in
                        ListRow(game: game, isHighlighted: highlighted(idx))
                            .onTapGesture {
                                appState.lastInputMethod = .mouse
                                selectedIndex = idx
                            }
                            // Target the SELECTED game — the SAME source that drives the highlight
                            // and the right detail panel — not the per-row capture. Under
                            // LazyVStack recycling the per-row `game`/`.id(idx)` drifted from the
                            // visible selection, so the menu pre-filled a different game than the
                            // one shown. selectedIndex is kept current by hover + keyboard nav.
                            .contextMenu { GameContextMenu(game: selectedGame ?? game, showFixBanner: true) }
                    }
                }
                .coordinateSpace(name: "listRows")
                .onContinuousHover(coordinateSpace: .named("listRows")) { phase in
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
                .padding(.horizontal, 20)
                // 23, was 16 — paired with listColumn's search bar padding (12 → 5) above so the
                // bar sits centered in its slot instead of low (see comment there).
                .padding(.top, 23)
                .padding(.bottom, MusicWidget.collapsedClearance)
            }
            .onChange(of: selectedIndex) { _, newVal in
                // Scroll by the game's stable id (rows are identified by game.id, not index).
                if appState.lastInputMethod != .mouse, let id = games[safe: newVal]?.id {
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }
}

// MARK: - Row (landscape header art band)

private struct ListRow: View {
    @Environment(AppState.self) private var appState
    let game: Game
    let isHighlighted: Bool

    private let rowHeight: CGFloat = listBandHeight

    var body: some View {
        ZStack(alignment: .leading) {
            // Split banner: prominent color (left) blended via comic-book halftone into the
            // zoomed landscape art (right). See ListBannerArt.
            ListBannerArt(game: game, highlighted: isHighlighted)
                .frame(maxWidth: .infinity)
                .frame(height: rowHeight)
                .clipped()

            content
        }
        .frame(height: rowHeight)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(
                    isHighlighted ? Color.white.opacity(0.9) : Color.white.opacity(0.07),
                    lineWidth: isHighlighted ? 2 : 0.5
                )
        )
        .shadow(
            color: isHighlighted ? Color(red: 0.65, green: 0.38, blue: 1.0).opacity(0.5)
                                 : .black.opacity(0.35),
            radius: isHighlighted ? 16 : 3, y: 2
        )
        .searchMatchGlow(active: appState.matchScore(for: game) != nil, selected: isHighlighted)
        .searchGreyscale(active: !appState.searchQuery.isEmpty && appState.matchScore(for: game) == nil)
        .scaleEffect(isHighlighted ? 1.012 : 1.0)
        .animation(.spring(response: 0.2, dampingFraction: 0.75), value: isHighlighted)
    }

    private var content: some View {
        HStack(spacing: 12) {
            Rectangle()
                .fill(Color.white)
                .frame(width: 3, height: 46)
                .opacity(isHighlighted ? 1 : 0)

            VStack(alignment: .leading, spacing: 5) {
                Text(game.title)
                    .font(.system(size: 21, weight: .bold))
                    .foregroundStyle(.white.opacity(isHighlighted ? 1 : 0.9))
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.85), radius: 4, x: 0, y: 1)
                SourceBadge(game: game, size: .compact)
            }

            Spacer(minLength: 8)

            if appState.isFavorite(game) {
                FavoriteStar(size: 22)
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 16)
    }
}

// MARK: - Right — inline detail panel for the highlighted game

private struct ListDetailPanel: View {
    @Environment(AppState.self) private var appState
    @Environment(GameSessionManager.self) private var session
    let game: Game?
    var actionsFocused: Bool = false
    var actionFocusIdx: Int = 0    // 0=Play, 1=Favorite, 2=Hide

    @State private var details: GameDetails?
    // The same spinning 3D box the full Detail page uses — its own scene/controller, separate
    // from DetailView's (List and the modal Detail page are never visible at the same time, but
    // each needs its own SCNScene instance regardless). Scaled up so it reads at a glance in
    // this tighter inline panel (v0.16.0: 1.8×, was 2.0× — dialed back 10%, still overflows the
    // frame) — see `content(for:)` for how the overflow is handled.
    @State private var boxController = DetailBoxController(sizeMultiplier: 1.8)

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
            guard let game else { return }
            details = .placeholder(for: game)
            let art = game.localArtPath.flatMap { NSImage(contentsOf: $0) }
            boxController.load(game: game, art: art)
            boxController.playEntrance()
            details = await GameDetailsFetcher.shared.details(for: game)
        }
    }

    // Cover art gets the top of the panel (as large as the space allows); title/actions/
    // metadata/about are anchored to the bottom so they never crowd the box down to a sliver.
    @ViewBuilder
    private func content(for game: Game) -> some View {
        VStack(spacing: 0) {
            DetailBoxView(controller: boxController)
                .id(appState.coverFixVersion)   // re-load art after a Fix Cover override
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // At 2× scale the box can run taller than the space above bottomBlock. Rather
                // than let it hard-clip against the frame edge or crowd bottomBlock, dissolve
                // the last third into transparency with the same comic-book halftone dot
                // treatment used elsewhere in List (see ListBannerArt/HalftoneSeam) — reads as
                // an intentional fade, not a cutoff.
                .mask(HalftoneSeam(color: .white, axis: .vertical, fadeStart: 0.66))
                .padding(.top, 10)
                // Bleed the art's own bottom edge down into the title/play row below (negative
                // padding: VStack lays out bottomBlock at the same position as before, but this
                // view's content still paints past that boundary, so it's drawn UNDER bottomBlock
                // — declared later, so it z-stacks on top). That extra height means the SAME box
                // scale now renders slightly larger within a taller frame, moving its already-
                // top-pinned art down relative to the panel — more of the top shows without
                // costing anything at the bottom, since the halftone fade already dissolves it
                // to nothing well before it reaches bottomBlock's opaque text/buttons.
                .padding(.bottom, -listBoxOverlap)

            bottomBlock(for: game)
        }
    }

    // How far the box's art is allowed to bleed down into the title/play row above it.
    private let listBoxOverlap: CGFloat = 56

    private func bottomBlock(for game: Game) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // Title + source badge
            VStack(alignment: .leading, spacing: 8) {
                Text(game.title)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
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

            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)

            // Metadata + About — capped and independently scrollable so a long description can
            // never push the cover art above it into a sliver.
            if let d = details {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        metaRow("photo.on.rectangle", "Publisher", d.publisher)
                        metaRow("calendar", "Release Date", d.releaseDate)
                        metaRow("person.2.fill", "Players", d.players)
                        metaRow("paintpalette.fill", "Genre", d.genre)
                        metaRow("internaldrive.fill", "File Size", d.fileSize)
                        metaRow("mappin.and.ellipse", "Location", d.location, multiline: true)
                        metaRow("clock.fill", "Playtime", AppState.formattedPlaytime(appState.playtime(for: game)))

                        VStack(alignment: .leading, spacing: 8) {
                            Text("ABOUT THE GAME")
                                .font(.system(size: 13, weight: .heavy))
                                .tracking(1.1)
                                .foregroundStyle(.white.opacity(0.9))
                            Text(d.about)
                                .font(.system(size: 14))
                                .foregroundStyle(.white.opacity(0.8))
                                .lineSpacing(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 2)
                    }
                }
                .frame(maxHeight: 210)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 30)
        .padding(.top, 6)
        .padding(.bottom, MusicWidget.collapsedClearance)
    }

    // The Detail-page actions, surfaced inline on the list row's panel.
    private func actions(for game: Game) -> some View {
        HStack(spacing: 12) {
            Button { session.launch(game) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "play.fill").font(.system(size: 16, weight: .bold))
                    Text("PLAY").font(.system(size: 17, weight: .heavy)).tracking(1)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
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
            .buttonStyle(.plain)
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
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(active ? tint : .white)
                .frame(width: 52, height: 52)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(focused ? Color.white.opacity(0.9) : (active ? tint : Color.white.opacity(0.12)),
                                      lineWidth: focused ? 2.5 : (active ? 2 : 1))
                )
                .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .hoverHighlight(scale: 1.08, brighten: 0.1)
        .inputHint(focused ? .confirm : nil, method: appState.lastInputMethod)
    }

    private func metaRow(_ icon: String, _ label: String, _ value: String,
                         multiline: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(accent)
                .frame(width: 18, alignment: .center)
            Text(label)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.82))
                .lineLimit(multiline ? 3 : 1)
                .truncationMode(multiline ? .tail : .middle)
                .fixedSize(horizontal: false, vertical: multiline)
            Spacer(minLength: 0)
        }
    }
}
