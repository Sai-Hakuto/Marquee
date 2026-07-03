import SwiftUI

struct GridView: View {
    @Environment(AppState.self) private var appState
    @Environment(SoundEffects.self) private var soundEffects
    let games: [Game]
    @Binding var selectedIndex: Int

    private let columns = [GridItem(.adaptive(minimum: 160, maximum: 210), spacing: 16)]

    // Highlight follows the mouse when hovering; otherwise the keyboard/controller selection
    // (and nothing at all when the mouse is the active input but isn't over a tile).
    private func highlighted(_ idx: Int) -> Bool {
        if let h = appState.hoverIndex { return idx == h }
        return appState.lastInputMethod != .mouse && idx == selectedIndex
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(Array(games.enumerated()), id: \.element.id) { idx, game in
                        GridTile(game: game, isSelected: highlighted(idx))
                            // Identity is the game's own id (via ForEach's id:), not `idx` — an
                            // `.id(idx)` here would tie each tile's view identity to its POSITION,
                            // so a live-search reorder reads as tiles being destroyed/recreated
                            // instead of the same tile sliding, killing the move animation
                            // (see ListView, which never had this and already slides correctly).
                            .onHover { inside in
                                if inside {
                                    if appState.hoverIndex != idx { soundEffects.play(.tick) }
                                    appState.lastInputMethod = .mouse
                                    appState.hoverIndex = idx
                                    selectedIndex = idx
                                } else if appState.hoverIndex == idx {
                                    appState.hoverIndex = nil
                                }
                            }
                            // Mouse click opens the Detail page (keyboard/controller use Enter).
                            .onTapGesture {
                                appState.lastInputMethod = .mouse
                                selectedIndex = idx
                                soundEffects.play(.confirm)   // same affirmation Enter/carousel-click gives
                                withAnimation(.easeIn(duration: 0.2)) { appState.detailTarget = game }
                            }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, MusicWidget.collapsedClearance)
            }
            .onChange(of: selectedIndex) { _, newVal in
                // Scroll by the game's stable id, not index (tiles are identified by game.id —
                // see the ForEach above), matching ListView's approach.
                if appState.lastInputMethod != .mouse, let id = games[safe: newVal]?.id {
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }
}

private struct GridTile: View {
    @Environment(AppState.self) private var appState
    let game: Game
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            GameArtImage(game: game)
                // Forces a remount whenever ANY game's art changes — not just this tile's own.
                // Needed because LazyVGrid doesn't reliably re-invoke an already-materialized
                // cell's body just because the underlying `game` value changed in place (proven
                // live: art landed correctly on disk + in the model during the initial art-fetch
                // loop, but a grid/wall launched directly as the startup view never painted it
                // until switching away and back forced a fresh mount). artVersion bumps once per
                // fetched game during that loop, coverFixVersion once per Fix Cover override —
                // together they cover both "art just arrived" cases this tile needs to react to.
                .id("\(appState.coverFixVersion)#\(appState.artVersion)")
            if appState.isFavorite(game) {
                FavoriteStar(size: 22).padding(7)
            }
        }
        .aspectRatio(2.0/3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 11))
        .overlay(alignment: .bottomTrailing) {
            SourceBadge(game: game, size: .compact).padding(7)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(isSelected ? Color.white : .clear, lineWidth: 3)
        )
        .contextMenu { GameContextMenu(game: game) }
        // Purple glow shadow when selected, dark lift shadow at rest
        .shadow(
            color: isSelected
                ? Color(red: 0.65, green: 0.38, blue: 1.0).opacity(0.60)
                : .black.opacity(0.50),
            radius: isSelected ? 20 : 6,
            y: isSelected ? 6 : 3
        )
        .searchMatchGlow(active: appState.matchScore(for: game) != nil, selected: isSelected)
        .searchGreyscale(active: !appState.searchQuery.isEmpty && appState.matchScore(for: game) == nil)
        .scaleEffect(isSelected ? 1.04 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isSelected)
    }
}
