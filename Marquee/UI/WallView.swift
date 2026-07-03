import SwiftUI

struct WallView: View {
    @Environment(AppState.self) private var appState
    @Environment(SoundEffects.self) private var soundEffects
    let games: [Game]
    @Binding var selectedIndex: Int

    private let columns = [GridItem(.adaptive(minimum: 110, maximum: 150), spacing: 10)]

    private func highlighted(_ idx: Int) -> Bool {
        if let h = appState.hoverIndex { return idx == h }
        return appState.lastInputMethod != .mouse && idx == selectedIndex
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(Array(games.enumerated()), id: \.element.id) { idx, game in
                        WallTile(game: game, isSelected: highlighted(idx))
                            // Identity is the game's own id (via ForEach's id:), not `idx` — an
                            // `.id(idx)` here would tie each tile's view identity to its POSITION,
                            // so a live-search reorder reads as tiles being destroyed/recreated
                            // instead of the same tile sliding (see GridView, matching fix).
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
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, MusicWidget.collapsedClearance)
            }
            .onChange(of: selectedIndex) { _, newVal in
                // Scroll by the game's stable id, not index (tiles are identified by game.id —
                // see the ForEach above), matching GridView/ListView's approach.
                if appState.lastInputMethod != .mouse, let id = games[safe: newVal]?.id {
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }
}

private struct WallTile: View {
    @Environment(AppState.self) private var appState
    let game: Game
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Cover art with clipped portrait crop
            ZStack(alignment: .topTrailing) {
                GameArtImage(game: game)
                    // See GridView's GridTile for why both versions are needed, not just
                    // coverFixVersion — LazyVGrid doesn't reliably re-render an already-
                    // materialized cell just because `game` changed in place.
                    .id("\(appState.coverFixVersion)#\(appState.artVersion)")
                    .aspectRatio(2.0/3.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        SourceBadge(game: game, size: .mini).padding(4)
                    }

                if appState.isFavorite(game) {
                    FavoriteStar(size: 14).padding(4)
                }
            }

            // Title label — always visible
            Text(game.title)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(isSelected ? 0.92 : 0.55))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 5)
                .padding(.top, 5)
                .padding(.bottom, 5)
                .frame(maxWidth: .infinity)
        }
        .padding(5)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(isSelected ? 0.10 : 0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.white.opacity(0.85) : Color.white.opacity(0.07),
                    lineWidth: isSelected ? 2 : 0.5
                )
        )
        .shadow(
            color: isSelected
                ? Color(red: 0.65, green: 0.38, blue: 1.0).opacity(0.50)
                : .black.opacity(0.35),
            radius: isSelected ? 12 : 3,
            y: isSelected ? 4 : 2
        )
        .searchMatchGlow(active: appState.matchScore(for: game) != nil, selected: isSelected, radius: 12)
        .searchGreyscale(active: !appState.searchQuery.isEmpty && appState.matchScore(for: game) == nil)
        .scaleEffect(isSelected ? 1.04 : 1.0)
        .animation(.spring(response: 0.18, dampingFraction: 0.72), value: isSelected)
        .contextMenu { GameContextMenu(game: game) }
    }
}
