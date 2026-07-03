import SwiftUI

// Translucent search + sort pill row, floating above the carousel/grid/wall content and, in
// List view, embedded above just the row list (see ListView). One shared component so both
// placements always reflect identical live state (appState.searchQuery/sortOption).
//
// Focus: the search pill's real text-edit focus is owned entirely by this view's own
// @FocusState, synced BOTH ways with appState.searchEditing (a plain Bool AppState can share
// with ContentView's global key monitor and its zone-key router) — so neither side needs to
// pass a FocusState<Bool>.Binding across the view boundary. ContentView's handleSearchSortKey
// just flips appState.searchEditing to request focus; this view's onChange picks that up and
// actually focuses the field.
struct SearchSortBar: View {
    @Environment(AppState.self) private var appState
    // Focus-zone wiring — same white-ring convention as FilterChipStyle/bottomControls.
    var isActive: Bool     // uiFocus == .searchSort
    var focusIdx: Int      // 0 = search pill, 1 = sort pill
    // List's own instance is constrained to just the (much narrower) row-list column, not the
    // full window — at the same 1/3 fraction that read fine in carousel/grid/wall, it came out
    // tiny. Doubled for List's call site (2/3 of its column ≈ the same absolute width as 1/3 of
    // the full window).
    var widthFraction: CGFloat = 1.0 / 3.0

    @FocusState private var fieldFocused: Bool

    // Centered at ~1/3 of whatever width it's given — full window width in carousel/grid/wall,
    // the narrower row-list column in List — instead of stretching edge-to-edge, which read as
    // way too large a pill for a search box.
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    searchPill
                    sortPill
                }
                .frame(width: geo.size.width * widthFraction)
                Spacer(minLength: 0)
            }
        }
        .frame(height: 44)
        // onChange only fires on a TRANSITION — it's silent for a value that's already true the
        // moment this view is created (e.g. Cmd+F closing the Detail page and requesting search
        // focus in the same call: this bar didn't exist a moment earlier to observe the "before"
        // state, so there's no change event to catch). onAppear covers exactly that case.
        .onAppear {
            // Setting @FocusState synchronously in onAppear is unreliable — the field's
            // underlying NSView isn't always installed in the window yet, so the claim silently
            // no-ops. Deferring one runloop turn (same fix as ContentView's key-window reclaim)
            // gives it something real to focus.
            DispatchQueue.main.async {
                if appState.searchEditing != fieldFocused { fieldFocused = appState.searchEditing }
            }
        }
        .onChange(of: appState.searchEditing) { _, editing in
            if editing != fieldFocused { fieldFocused = editing }
        }
        .onChange(of: fieldFocused) { _, focused in
            if focused != appState.searchEditing { appState.searchEditing = focused }
        }
    }

    // Wraps every keystroke's mutation in withAnimation so grid/wall/list's ForEach(id:)
    // re-ranking animates smoothly instead of jumping (the carousel's own re-centering is a
    // separate SceneKit spring, driven by ContentView's onChange(of: searchQuery)).
    private var searchQueryBinding: Binding<String> {
        Binding(
            get: { appState.searchQuery },
            set: { newValue in
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    appState.searchQuery = newValue
                }
            }
        )
    }

    private var searchPill: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
            TextField("Search your games…", text: searchQueryBinding)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .focused($fieldFocused)
                .onSubmit { appState.searchEditing = false }
                // Forces a fresh NSTextView/FocusState when a same-click key-window reclaim
                // (ContentView's mouseMonitor/didBecomeKeyObserver) needs to retry the focus
                // request after the window actually finishes becoming key.
                .id(appState.searchFieldResetToken)
            if !appState.searchQuery.isEmpty {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        appState.searchQuery = ""
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            } else if !fieldFocused {
                // ⌘F hint — only when there's nothing else to show in its place (an empty,
                // unfocused field); the clear button above already claims this spot once there's
                // a query, and once focused the hint would just be noise while typing.
                Text("⌘F")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.32))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.08)))
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Capsule().fill(Color.white.opacity(0.10)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1).allowsHitTesting(false))
        .overlay(
            Capsule()
                .strokeBorder(isActive && focusIdx == 0 ? Color.white.opacity(0.9) : .clear, lineWidth: 2)
                .allowsHitTesting(false)
        )
        .contentShape(Capsule())
        .onTapGesture { fieldFocused = true }
        .animation(.easeInOut(duration: 0.15), value: appState.searchQuery.isEmpty)
    }

    // "Date Installed" has no separate ascending/descending entries in the menu the way A–Z/Z–A
    // do — clicking it again while already selected toggles appState.dateInstalledAscending
    // instead (see AppState.setSortOption), so its own label carries a direction arrow as the
    // only visible sign that re-clicking it does something.
    private func sortOptionLabel(_ option: AppState.SortOption) -> String {
        guard option == .dateInstalled else { return option.label }
        return option.label + (appState.dateInstalledAscending ? " ↑" : " ↓")
    }

    private var sortPill: some View {
        Menu {
            ForEach(AppState.SortOption.allCases, id: \.self) { option in
                Button {
                    appState.setSortOption(option)
                } label: {
                    if appState.sortOption == option {
                        Label(sortOptionLabel(option), systemImage: "checkmark")
                    } else {
                        Text(sortOptionLabel(option))
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 11, weight: .semibold))
                Text(sortOptionLabel(appState.sortOption))
                    .font(.system(size: 13, weight: .semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.white.opacity(0.10)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
            .fixedSize()
        }
        .menuStyle(.borderlessButton)
        // Applied to the Menu control itself, not inside its label closure — .menuStyle's own
        // chrome painted over an overlay declared inside the label, hiding the focus ring.
        .overlay(
            Capsule().strokeBorder(isActive && focusIdx == 1 ? Color.white.opacity(0.9) : .clear, lineWidth: 2)
        )
        .hoverHighlight(scale: 1.03, brighten: 0.08)
    }
}
