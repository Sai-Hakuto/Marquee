import SwiftUI

// A density tier between Grid and the full 3D Carousel — large posters, about two rows tall in
// the viewport (Jack's ask: Wall reads as ~4 rows, Grid ~3, this should read as ~2). Structurally
// an exact copy of GridView's LazyVGrid/ScrollViewReader plumbing with a much larger tile size —
// see GridView.swift for the identity/hover/scroll-by-id notes, which all apply unchanged here.
struct BigView: View {
    @Environment(AppState.self) private var appState
    @Environment(SoundEffects.self) private var soundEffects
    let games: [Game]
    @Binding var selectedIndex: Int

    private let columns = [GridItem(.adaptive(minimum: 320, maximum: 400), spacing: 22)]

    private func highlighted(_ idx: Int) -> Bool {
        if let h = appState.hoverIndex { return idx == h }
        return appState.lastInputMethod != .mouse && idx == selectedIndex
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 22) {
                    ForEach(Array(games.enumerated()), id: \.element.id) { idx, game in
                        BigTile(game: game, isSelected: highlighted(idx))
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
                            .onTapGesture {
                                appState.lastInputMethod = .mouse
                                selectedIndex = idx
                                soundEffects.play(.confirm)
                                withAnimation(.easeIn(duration: 0.2)) { appState.detailTarget = game }
                            }
                    }
                }
                .padding(.horizontal, 24)
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

private struct BigTile: View {
    @Environment(AppState.self) private var appState
    let game: Game
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            GameArtImage(game: game)
                // See GridView.GridTile for why both versions are needed in the id.
                .id("\(appState.coverFixVersion)#\(appState.artVersion)")
            if appState.isFavorite(game) {
                FavoriteStar(size: 30).padding(10)
            }
        }
        .aspectRatio(2.0/3.0, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(alignment: .bottomTrailing) {
            SourceBadge(game: game, size: .regular).padding(10)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(isSelected ? Color.white : .clear, lineWidth: 4)
        )
        .contextMenu { GameContextMenu(game: game) }
        .shadow(
            color: isSelected
                ? Color(red: 0.65, green: 0.38, blue: 1.0).opacity(0.60)
                : .black.opacity(0.50),
            radius: isSelected ? 26 : 8,
            y: isSelected ? 8 : 4
        )
        .searchMatchGlow(active: appState.matchScore(for: game) != nil, selected: isSelected, radius: 20)
        .searchGreyscale(active: !appState.searchQuery.isEmpty && appState.matchScore(for: game) == nil)
        .scaleEffect(isSelected ? 1.03 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: isSelected)
    }
}
