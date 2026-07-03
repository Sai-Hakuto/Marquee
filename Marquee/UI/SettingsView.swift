import SwiftUI

// Preferences window — opened via the standard macOS "Settings…"/"Preferences…" app-menu
// item + ⌘, (wired for free by wrapping this in a `Settings` scene in MarqueeApp, see there).
// Everything here is "sticky": each control writes straight through to the same AppState/
// MusicPlayerController setters the rest of the app already uses, which are the ones that persist
// to UserDefaults — so there's no separate "save" step, and no separate source of truth to drift
// out of sync with the nav bar / bottom controls / music widget.
//
// EXCEPT Startup View/Filter, which are two-tier on purpose: `AppState.viewMode`/`sourceFilter`
// are live, in-session state that casually browsing the nav bar changes all the time, same as
// always — this panel's "Startup View"/"Startup Filter" rows read/write the SEPARATE
// `startupViewMode`/`startupSourceFilter` (only ever set via `setStartupViewMode`/
// `setStartupSourceFilter`, called from here and nowhere else), so idle curiosity in Grid or List
// mid-session can never silently redefine what Marquee opens into next time.
//
// Every row leads with a small "silhouette" glyph — reusing icons already
// established elsewhere in the app (view-mode icons, the motion/backdrop toggle glyphs, the
// music widget's own iconography) so a setting's *category* reads at a glance before the label
// text does.
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(MusicPlayerController.self) private var musicPlayer
    @Environment(SoundEffects.self) private var soundEffects

    // Which reset row is asking "are you sure?" — drives one shared confirmation dialog.
    @State private var pendingReset: ResetKind? = nil

    private static let accent = Color(red: 0.76, green: 0.46, blue: 1.0)

    // Favorites/Hidden are situational (only meaningful once the user has some), not a genuine
    // "always start here" library-wide default — left off this picker on purpose.
    private static let startupFilterChoices: [AppState.SourceFilter] =
        [.all, .crossOver, .steam, .epic, .gog, .applications]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                libracySection
                appearanceSection
                musicSection
                behaviorSection
                resetSection
            }
            .padding(22)
        }
        .frame(width: 480, height: 660)
        .background(Color(red: 0.07, green: 0.04, blue: 0.14))
        .foregroundStyle(.white)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Self.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Preferences")
                    .font(.system(size: 17, weight: .bold))
                Text("These stick — Marquee remembers them between launches.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer()
        }
        .padding(.bottom, 4)
    }

    // MARK: - Library section (view / filter / sort)

    private var libracySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Library")

            PreferenceRow(icon: appState.startupViewMode.sfSymbol, iconColor: Self.accent,
                          title: "Startup View", subtitle: "Which layout Marquee opens into") {
                HStack(spacing: 6) {
                    ForEach(AppState.ViewMode.allCases, id: \.self) { mode in
                        Button { appState.setStartupViewMode(mode) } label: {
                            VStack(spacing: 3) {
                                Image(systemName: mode.sfSymbol)
                                    .font(.system(size: 14, weight: .semibold))
                                Text(mode.label)
                                    .font(.system(size: 9, weight: .medium))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .foregroundStyle(appState.startupViewMode == mode ? .white : .white.opacity(0.4))
                            .background(appState.startupViewMode == mode ? Self.accent.opacity(0.35) : Color.white.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            PreferenceRow(icon: "line.3.horizontal.decrease.circle.fill", iconColor: .cyan,
                          title: "Startup Filter", subtitle: "Which games are visible when Marquee opens") {
                HStack(spacing: 6) {
                    ForEach(Self.startupFilterChoices, id: \.self) { filter in
                        Button(filter.label) { appState.setStartupSourceFilter(filter) }
                            .buttonStyle(FilterChipStyle(isActive: appState.startupSourceFilter == filter))
                    }
                }
            }

            PreferenceRow(icon: "arrow.up.arrow.down", iconColor: .orange,
                          title: "Default Sort", subtitle: "How the library orders on a fresh launch") {
                Menu {
                    ForEach(AppState.SortOption.allCases, id: \.self) { option in
                        Button {
                            appState.setSortOption(option)
                        } label: {
                            if appState.sortOption == option {
                                Label(option.label, systemImage: "checkmark")
                            } else {
                                Text(option.label)
                            }
                        }
                    }
                } label: {
                    menuLabel(appState.sortOption.label)
                }
                .menuStyle(.borderlessButton)
            }
        }
    }

    // MARK: - Appearance section

    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Appearance")

            PreferenceRow(icon: "paintpalette.fill", iconColor: .pink,
                          title: "Accent Color", subtitle: "The app's background theme") {
                HStack(spacing: 18) {
                    ForEach(AppState.AppTheme.allCases, id: \.self) { theme in
                        Button { appState.setTheme(theme) } label: {
                            VStack(spacing: 6) {
                                Circle()
                                    .fill(theme.swatch)
                                    .frame(width: 22, height: 22)
                                    .overlay(Circle().strokeBorder(Color.white.opacity(0.38), lineWidth: 1))
                                    .overlay(
                                        Circle()
                                            .strokeBorder(appState.currentTheme == theme ? Color.white : .clear, lineWidth: 2)
                                            .padding(-3)
                                    )
                                Text(theme.label)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
            }

            ToggleRow(icon: "photo.fill", iconColor: .yellow,
                      title: "Game Backdrop", subtitle: "Blurred hero art behind the library",
                      isOn: Binding(get: { appState.heroBackgroundEnabled },
                                     set: { appState.setHeroBackground($0) }))

            ToggleRow(icon: "waveform", iconColor: .mint,
                      title: "Background Motion", subtitle: "Drifting waves, wisps, and particles",
                      isOn: Binding(get: { appState.motionEnabled },
                                     set: { appState.setMotion($0) }))
        }
    }

    // MARK: - Music section

    private var musicSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Music")

            PreferenceRow(icon: volumeGlyph, iconColor: .green,
                          title: "Volume", subtitle: "Background music level") {
                HStack(spacing: 10) {
                    Slider(value: Binding(get: { Double(musicPlayer.volume) },
                                           set: { musicPlayer.setVolume(Float($0)) }), in: 0...1)
                    Text("\(Int(musicPlayer.volume * 100))%")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 38, alignment: .trailing)
                }
            }

            PreferenceRow(icon: musicPlayer.startupTrackIndex == nil ? "shuffle" : "music.note",
                          iconColor: .purple,
                          title: "Startup Song", subtitle: "Random uses each track's shuffle weight") {
                Menu {
                    Button {
                        musicPlayer.setStartupTrack(nil)
                    } label: {
                        if musicPlayer.startupTrackIndex == nil {
                            Label("Random", systemImage: "checkmark")
                        } else {
                            Text("Random")
                        }
                    }
                    Divider()
                    ForEach(musicPlayer.trackNames.indices, id: \.self) { i in
                        Button {
                            musicPlayer.setStartupTrack(i)
                        } label: {
                            if musicPlayer.startupTrackIndex == i {
                                Label(musicPlayer.trackNames[i], systemImage: "checkmark")
                            } else {
                                Text(musicPlayer.trackNames[i])
                            }
                        }
                    }
                } label: {
                    menuLabel(musicPlayer.startupTrackIndex.flatMap { musicPlayer.trackNames[safe: $0] } ?? "Random")
                }
                .menuStyle(.borderlessButton)
            }
        }
    }

    // MARK: - Behavior section

    private var behaviorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Behavior")

            ToggleRow(icon: appState.soundEffectsEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill",
                      iconColor: .blue,
                      title: "Sound Effects", subtitle: "Nav ticks, confirm, and back chimes",
                      isOn: Binding(get: { appState.soundEffectsEnabled },
                                     set: {
                                         appState.setSoundEffects($0)
                                         // The synth engine keeps its own flag — sync it here the
                                         // same way the Appearance menu's toggle does, or the
                                         // change wouldn't take effect until the next launch.
                                         soundEffects.enabled = $0
                                     }))
        }
    }

    // MARK: - Reset section

    // What each reset touches (and, just as importantly, what it doesn't) lives in the
    // matching AppState.reset* methods. Play statistics get the scariest wording because
    // playtime only accrues through real play sessions — it can't be recovered.
    private enum ResetKind: String, Identifiable, CaseIterable {
        case firstLaunch, allSettings, artCache, playStats
        var id: String { rawValue }

        var title: String {
            switch self {
            case .firstLaunch: return "Reset First-Launch Setup"
            case .allSettings: return "Reset All Settings"
            case .artCache:    return "Clear Art Cache & Custom Covers"
            case .playStats:   return "Reset Play Statistics"
            }
        }
        var subtitle: String {
            switch self {
            case .firstLaunch: return "Run the welcome flow again (art source choice)"
            case .allSettings: return "Appearance, startup, and behavior back to defaults"
            case .artCache:    return "Deletes downloaded art and Fix Cover overrides, then re-fetches"
            case .playStats:   return "Play counts, last played, and playtime — cannot be undone"
            }
        }
        var icon: String {
            switch self {
            case .firstLaunch: return "sparkles"
            case .allSettings: return "arrow.counterclockwise"
            case .artCache:    return "photo.on.rectangle.angled"
            case .playStats:   return "clock.badge.xmark"
            }
        }
        var confirmMessage: String {
            switch self {
            case .firstLaunch:
                return "The welcome flow will appear again so you can re-pick how cover art is found. Nothing else is touched."
            case .allSettings:
                return "Appearance, startup, behavior, and music settings return to defaults. Your games, favorites, playtime, and custom covers are kept."
            case .artCache:
                return "All downloaded art and Fix Cover/Banner overrides are deleted, then everything re-fetches fresh. Your own image files are not touched."
            case .playStats:
                return "Play counts, last-played dates, and total playtime for every game will be permanently erased. This cannot be undone."
            }
        }
    }

    private var resetSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionLabel("Reset")

            ForEach(ResetKind.allCases) { kind in
                HStack(spacing: 10) {
                    iconBadge(kind.icon, kind == .playStats ? .red : .gray)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(kind.title)
                            .font(.system(size: 13, weight: .semibold))
                        Text(kind.subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    Spacer()
                    Button("Reset…") { pendingReset = kind }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(kind == .playStats ? .red : .white.opacity(0.85))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
            }
        }
        .confirmationDialog(
            pendingReset?.title ?? "",
            isPresented: Binding(get: { pendingReset != nil },
                                 set: { if !$0 { pendingReset = nil } }),
            titleVisibility: .visible
        ) {
            Button(pendingReset == .playStats ? "Erase Play Statistics" : "Reset",
                   role: .destructive) {
                if let kind = pendingReset { perform(kind) }
                pendingReset = nil
            }
            Button("Cancel", role: .cancel) { pendingReset = nil }
        } message: {
            Text(pendingReset?.confirmMessage ?? "")
        }
    }

    private func perform(_ kind: ResetKind) {
        switch kind {
        case .firstLaunch:
            appState.resetFirstLaunchSetup()
            // The welcome flow lives in the main window — bring it forward so the effect
            // is visible immediately instead of hidden behind this Preferences window.
            NSApp.windows.first(where: { !($0 is NSPanel) && $0.isVisible })?
                .makeKeyAndOrderFront(nil)
        case .allSettings:
            appState.resetAllSettings()
            soundEffects.enabled = true
            musicPlayer.setVolume(0.3)
            musicPlayer.setStartupTrack(nil)
        case .artCache:
            appState.clearArtCacheAndOverrides()
        case .playStats:
            appState.resetPlayStatistics()
        }
    }

    // MARK: - Shared bits

    private var volumeGlyph: String {
        switch musicPlayer.volume {
        case ..<0.01:  return "speaker.slash.fill"
        case ..<0.34:  return "speaker.wave.1.fill"
        case ..<0.67:  return "speaker.wave.2.fill"
        default:       return "speaker.wave.3.fill"
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(.white.opacity(0.32))
            .padding(.top, 6)
    }

    private func menuLabel(_ text: String) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.07)))
    }
}

// MARK: - Row templates

// A titled row fronted by a small "silhouette" glyph badge, with a caller-supplied control
// underneath — used for anything with more than a binary choice (view mode, filter, sort,
// theme, volume, startup song).
private struct PreferenceRow<Control: View>: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    @ViewBuilder let control: () -> Control

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                iconBadge(icon, iconColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.4))
                }
                Spacer()
            }
            control()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
    }
}

// Same glyph-badge header as PreferenceRow, but for a plain on/off — the native switch sits
// inline on the header row instead of a control block below, since it needs no extra room.
private struct ToggleRow: View {
    let icon: String
    let iconColor: Color
    let title: String
    let subtitle: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 10) {
            iconBadge(icon, iconColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer()
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .tint(Color(red: 0.76, green: 0.46, blue: 1.0))
                .labelsHidden()
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
    }
}

// Shared by both row templates — a small rounded-square glyph badge that reads as "this
// setting's category" before the label text does.
private func iconBadge(_ icon: String, _ color: Color) -> some View {
    ZStack {
        RoundedRectangle(cornerRadius: 9)
            .fill(color.opacity(0.18))
            .frame(width: 30, height: 30)
        Image(systemName: icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(color)
    }
}
