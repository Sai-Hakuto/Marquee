import SwiftUI
import AppKit

// Pause-menu behavior: opening/closing, the key/controller handler, and the shared action
// dispatch. Mouse clicks inside PauseMenuView call the same pauseMenuActivate/pauseMenuAdjust
// functions the key router uses, so every input method fires identical code paths.

extension ContentView {

    func togglePauseMenu() {
        appState.pauseMenuVisible ? closePauseMenu() : openPauseMenu()
    }

    func openPauseMenu() {
        guard !appState.pauseMenuVisible,
              appState.fixCoverTarget == nil, appState.fixBannerTarget == nil,
              appState.artSourcePreference != .notConfigured else { return }
        appState.searchEditing = false
        pauseMenuCategoryIdx = 0
        pauseMenuRowIdx = nil
        pauseMenuRowArmed = false
        appState.refreshLaunchAtLogin()   // System Settings may have changed it behind our back
        soundEffects.play(.confirm)
        withAnimation(.easeOut(duration: 0.18)) { appState.pauseMenuVisible = true }
    }

    func closePauseMenu() {
        guard appState.pauseMenuVisible else { return }
        soundEffects.play(.back)
        withAnimation(.easeOut(duration: 0.15)) { appState.pauseMenuVisible = false }
        uiFocus = .carousel
    }

    // MARK: - Key routing (called first from handleNavKey while the menu is up)
    //
    // Two-level XMB nav: `pauseMenuRowIdx == nil` means focus sits on the horizontal category
    // strip (Left/Right changes CATEGORY); once Down/Enter drills into a row, Left/Right instead
    // adjusts THAT row's value (if it's a cycler) and no longer changes category — matching
    // "vertically to deep dive, horizontally to enter new categories" (decisions.md #90). Esc
    // backs out one level at a time (row focus → category strip → close), the same convention
    // used everywhere else a sub-zone exists (Detail's media rail, trailer overlay, etc).

    func handlePauseMenuKey(_ kc: UInt16) -> Bool {
        let categories = PauseMenuCategory.allCases
        if pauseMenuCategoryIdx >= categories.count { pauseMenuCategoryIdx = 0 }
        let category = categories[pauseMenuCategoryIdx]
        let items = category.items(appState: appState)
        // The row list is context-dependent (game selection, display count) — clamp in case
        // it shrank since the menu opened or since the category last changed.
        if let row = pauseMenuRowIdx, row >= items.count {
            pauseMenuRowIdx = items.isEmpty ? nil : items.count - 1
        }

        switch kc {
        case 53:   // Esc — backs out exactly one level: armed -> row focus -> category strip -> close
            if pauseMenuRowArmed {
                soundEffects.play(.back)
                pauseMenuRowArmed = false
            } else if pauseMenuRowIdx != nil {
                soundEffects.play(.back)
                pauseMenuRowIdx = nil
            } else {
                closePauseMenu()
            }
        case 123:  // Left
            if pauseMenuRowArmed, let row = pauseMenuRowIdx, let item = items[safe: row], item.isAdjustable {
                pauseMenuAdjust(item, delta: -1)
            } else {
                // Left/Right ALWAYS shifts category — even with a row focused — unless a value
                // is explicitly armed for adjustment first (decisions.md #94). `pauseMenuRowIdx`
                // is deliberately left as-is: the same row index carries over into the new
                // category (clamped above), matching the "coordinate grid" framing rather than
                // resetting focus back to the icon strip on every category change.
                soundEffects.play(.tick)
                pauseMenuCategoryIdx = (pauseMenuCategoryIdx - 1 + categories.count) % categories.count
            }
        case 124:  // Right
            if pauseMenuRowArmed, let row = pauseMenuRowIdx, let item = items[safe: row], item.isAdjustable {
                pauseMenuAdjust(item, delta: 1)
            } else {
                soundEffects.play(.tick)
                pauseMenuCategoryIdx = (pauseMenuCategoryIdx + 1) % categories.count
            }
        case 126:  // Up
            if let row = pauseMenuRowIdx {
                soundEffects.play(.tick)
                pauseMenuRowArmed = false   // can't be mid-adjustment on a row you're leaving
                pauseMenuRowIdx = row == 0 ? nil : row - 1
            }
        case 125:  // Down
            soundEffects.play(.tick)
            pauseMenuRowArmed = false
            if let row = pauseMenuRowIdx {
                pauseMenuRowIdx = min(items.count - 1, row + 1)
            } else if !items.isEmpty {
                pauseMenuRowIdx = 0
            }
        case 36, 49:  // Enter/Space
            if let row = pauseMenuRowIdx, let item = items[safe: row] {
                pauseMenuActivate(item)
            } else if category == .resume {
                // Resume is a one-row category with nothing else to see — Enter on its icon
                // acts immediately instead of making the user drill in just to press Enter again.
                pauseMenuActivate(.resume)
            } else if !items.isEmpty {
                pauseMenuRowIdx = 0
            }
        default:
            break
        }
        return true
    }

    // MARK: - Actions (shared by keyboard/controller Enter and mouse clicks)

    func pauseMenuActivate(_ item: PauseMenuItem) {
        switch item {
        case .resume:
            closePauseMenu()
        case .fullScreen:
            soundEffects.play(.confirm)
            session.appDelegate?.toggleFullScreen()
        case .moveDisplay:
            soundEffects.play(.confirm)
            session.appDelegate?.moveToNextDisplay()
        case .refreshLibrary:
            soundEffects.play(.confirm)
            Task { await appState.loadAllGames() }
        case .fixCover:
            guard let game = appState.filteredGames[safe: appState.selectedIndex] else { return }
            closePauseMenu()
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                appState.fixCoverTarget = game
            }
        case .hideGame:
            guard let game = appState.filteredGames[safe: appState.selectedIndex] else { return }
            soundEffects.play(.confirm)
            appState.hideGame(game)
        case .backdrop:
            appState.setHeroBackground(!appState.heroBackgroundEnabled)
        case .motion:
            appState.setMotion(!appState.motionEnabled)
        case .soundEffects:
            let on = !appState.soundEffectsEnabled
            appState.setSoundEffects(on)
            soundEffects.enabled = on
        case .launchAtLogin:
            appState.setLaunchAtLogin(!appState.launchAtLogin)
        case .startInFullScreen:
            appState.setStartInFullScreen(!appState.startInFullScreen)
        case .allSettings:
            // The Settings window can't claim key status underneath the overlay's key routing —
            // close the menu first so the window opens into a normal focus situation.
            closePauseMenu()
            openSettings()
        case .checkForUpdates:
            soundEffects.play(.confirm)
            Task { await AppUpdater.shared.checkForUpdates(userInitiated: true, appState: appState) }
        case .about:
            NSApp.orderFrontStandardAboutPanel(nil)
        case .quit:
            NSApp.terminate(nil)
        case .viewMode, .sourceFilter, .sortOption, .theme, .musicVolume, .controllerLayout:
            // Enter/confirm ARMS the row for adjustment rather than stepping the value directly
            // — Left/Right always shifts category otherwise, so a cycler needs an explicit
            // "now editing this" gesture before Left/Right means something else here. Pressing
            // confirm again on the same (still-focused) row un-arms it (decisions.md #94).
            pauseMenuRowArmed.toggle()
            soundEffects.play(pauseMenuRowArmed ? .confirm : .back)
        }
    }

    func pauseMenuAdjust(_ item: PauseMenuItem, delta: Int) {
        soundEffects.play(.tick)
        switch item {
        case .viewMode:
            let modes = AppState.ViewMode.allCases
            let idx = modes.firstIndex(of: appState.viewMode) ?? 0
            let newMode = modes[(idx + delta + modes.count) % modes.count]
            appState.viewMode = newMode
            if newMode == .carousel {
                carousel.loadGames(appState.filteredGames, animated: false,
                                   selectedIndex: appState.selectedIndex)
                applyArtToCarousel()
            }
            if newMode == .rainbowSlide {
                rainbowSlide.loadGames(appState.filteredGames, selectedIndex: appState.selectedIndex)
                applyArtToRainbowSlide()
            }
        case .sourceFilter:
            let filters = visibleFilters
            let idx = filters.firstIndex(of: appState.sourceFilter) ?? 0
            appState.sourceFilter = filters[(idx + delta + filters.count) % filters.count]
            appState.selectedIndex = 0
            if appState.viewMode == .carousel {
                carousel.loadGames(appState.filteredGames, animated: false)
                applyArtToCarousel()
            }
            if appState.viewMode == .rainbowSlide {
                rainbowSlide.loadGames(appState.filteredGames)
                applyArtToRainbowSlide()
            }
        case .sortOption:
            let all = AppState.SortOption.allCases
            let idx = all.firstIndex(of: appState.sortOption) ?? 0
            appState.setSortOption(all[(idx + delta + all.count) % all.count])
        case .theme:
            let themes = AppState.AppTheme.allCases
            let idx = themes.firstIndex(of: appState.currentTheme) ?? 0
            appState.setTheme(themes[(idx + delta + themes.count) % themes.count])
        case .musicVolume:
            musicPlayer.setVolume(max(0, min(1, musicPlayer.volume + Float(delta) * 0.05)))
        case .controllerLayout:
            // Two presets, so either direction flips to the other; a hand-customized layout
            // ("Custom", made in Settings ▸ Controller) snaps onto Standard first. Fine-grained
            // per-button rebinding stays in Settings — this row is the couch-reachable half.
            let store = ControllerMappingStore.shared
            store.applyPreset(store.activePreset == .standard ? .nintendo : .standard)
        default:
            break   // non-adjustable rows have no left/right behavior
        }
    }
}
