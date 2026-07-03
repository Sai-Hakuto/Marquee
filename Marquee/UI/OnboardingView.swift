import SwiftUI

// First-launch welcome flow, shown (over the main window) until an art source is chosen:
//   1. Welcome — what Marquee is, at a glance.
//   2. Privacy — exactly what the app reads, writes, and talks to. Shown up front, before
//      any choice is asked of the user, so there's never a "why does it want that?" moment.
//   3. Art source — the one real decision (cover-art provider), which completes setup.
// Settings ▸ Reset ▸ "Reset First-Launch Setup" re-runs the whole flow.
struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @State private var page = 0            // 0=welcome, 1=privacy, 2=art source
    @State private var selectedOption = 1  // SteamGridDB is default center
    @State private var steamGridKey = ""
    @State private var keyError = false
    // Claimed on appear so Return/arrows work immediately — .focusable() alone only makes
    // focus possible, it doesn't grant it.
    @FocusState private var keyboardFocused: Bool

    private struct Option {
        let choice: ArtChoice
        let icon: String
        let iconColor: Color
        let title: String
        let badge: String?
        let subtitle: String   // shown on side cards
        let description: String
    }

    enum ArtChoice { case own, automatic, steamGridDB }

    private let options: [Option] = [
        Option(
            choice: .own,
            icon: "photo.fill.on.rectangle.fill",
            iconColor: Color(red: 0.3, green: 0.72, blue: 0.45),
            title: "My Own Files",
            badge: nil,
            subtitle: "You supply the art.",
            description: "Name image files after each game and drop them in a folder. Full control, no internet needed."
        ),
        Option(
            choice: .steamGridDB,
            icon: "key.fill",
            iconColor: Color(red: 0.92, green: 0.62, blue: 0.12),
            title: "SteamGridDB",
            badge: "BEST QUALITY",
            subtitle: "Free API key, perfect art.",
            description: "The most complete game art database. Free account — no payment, no subscription. Takes 30 seconds to set up."
        ),
        Option(
            choice: .automatic,
            icon: "magnifyingglass.circle.fill",
            iconColor: Color(red: 0.2, green: 0.52, blue: 0.95),
            title: "Automatic",
            badge: nil,
            subtitle: "Zero setup, best effort.",
            description: "We search Steam's public database and use bundled icons. No account needed. Coverage is solid but not perfect."
        )
    ]

    var body: some View {
        ZStack {
            Color(red: 0.04, green: 0.02, blue: 0.09).opacity(0.80)
                .background(.thinMaterial)
                .ignoresSafeArea()

            switch page {
            case 0:  welcomePage
            case 1:  privacyPage
            default: artSourcePage
            }
        }
        .focusable()
        .focused($keyboardFocused)
        .onAppear { keyboardFocused = true }
        .onKeyPress(.leftArrow)  { if page == 2 { navigateDelta(-1) }; return .handled }
        .onKeyPress(.rightArrow) { if page == 2 { navigateDelta(+1) }; return .handled }
        .onKeyPress(.return)     { advance(); return .handled }
        .onKeyPress(.escape)     { if page > 0 { withAnimation { page -= 1 } }; return .handled }
    }

    // Return advances whichever page is showing; on the last page it confirms the choice.
    private func advance() {
        if page < 2 { withAnimation { page += 1 } } else { confirmCurrent() }
    }

    // MARK: - Page 1: Welcome

    private var welcomePage: some View {
        VStack(spacing: 26) {
            if let url = Bundle.main.url(forResource: "Marquee-logo-icon_128", withExtension: "png"),
               let img = NSImage(contentsOf: url) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 110, height: 110)
                    .shadow(color: .black.opacity(0.5), radius: 18, y: 6)
            }

            VStack(spacing: 8) {
                Text("Welcome to Marquee")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("All your Mac games on one shelf.")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.5))
            }

            VStack(alignment: .leading, spacing: 14) {
                infoRow("square.stack.3d.up.fill", .purple,
                        "One library, every store",
                        "CrossOver, Steam, Epic, GOG, and Mac App Store games — found automatically.")
                infoRow("gamecontroller.fill", Color(red: 0.3, green: 0.72, blue: 0.45),
                        "Made for the couch",
                        "A console-style carousel with full keyboard, mouse, and controller navigation.")
                infoRow("clock.fill", .orange,
                        "Knows what you play",
                        "Real playtime tracking, favorites, and smart sorting — all stored on your Mac.")
            }
            .frame(width: 500)

            primaryButton("Get Started") { advance() }
                .frame(width: 300)

            pageDots
        }
        .padding(48)
    }

    // MARK: - Page 2: Privacy & permissions

    private var privacyPage: some View {
        VStack(spacing: 26) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 44, weight: .medium))
                .foregroundStyle(Color(red: 0.3, green: 0.72, blue: 0.45))

            VStack(spacing: 8) {
                Text("Private by design")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Here's everything Marquee touches — the full list.")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.5))
            }

            VStack(alignment: .leading, spacing: 14) {
                infoRow("folder.fill", .cyan,
                        "Reads your game libraries",
                        "CrossOver bottles, Steam/Epic/GOG manifests, and /Applications are scanned read-only to find installed games.")
                infoRow("internaldrive.fill", .gray,
                        "Writes only its own files",
                        "Cover art cache and settings live in your user Library folder. Marquee never modifies games or other apps.")
                infoRow("network", .blue,
                        "Goes online only for cover art",
                        "Art comes from Steam's public listings or SteamGridDB — your choice, next step. No account, no analytics, no tracking.")
                infoRow("hand.raised.fill", .orange,
                        "No macOS permissions required",
                        "Marquee never prompts for privacy access. If macOS ever mentions app changes when a CrossOver game launches, that's CrossOver tidying its own shortcuts — harmless to deny.")
            }
            .frame(width: 560)

            primaryButton("Sounds Good") { advance() }
                .frame(width: 300)

            pageDots
        }
        .padding(48)
    }

    // MARK: - Page 3: Art source (completes setup)

    private var artSourcePage: some View {
        VStack(spacing: 28) {
            VStack(spacing: 8) {
                Text("How should Marquee find cover art?")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("You can change this any time in Settings.")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.45))
            }

            // Coverflow carousel
            ZStack {
                ForEach(0..<options.count, id: \.self) { idx in
                    cardView(optionIndex: idx)
                        .zIndex(idx == selectedOption ? 10 : 0)
                }
            }
            .frame(width: 900, height: 440)

            // Nav dots + hint
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(0..<options.count, id: \.self) { idx in
                        Circle()
                            .fill(idx == selectedOption ? .white : Color.white.opacity(0.28))
                            .frame(width: 7, height: 7)
                            .scaleEffect(idx == selectedOption ? 1.15 : 1.0)
                            .animation(.spring(response: 0.25), value: selectedOption)
                            .onTapGesture { withAnimation { selectedOption = idx } }
                    }
                }
                Text("← →  to browse  ·  click a side card to select it  ·  Esc to go back")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.25))
            }
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 40)
    }

    // MARK: - Shared pieces

    private func infoRow(_ icon: String, _ color: Color, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 34, height: 34)
                .background(color.opacity(0.16))
                .clipShape(RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func primaryButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<3, id: \.self) { idx in
                Circle()
                    .fill(idx == page ? .white : Color.white.opacity(0.28))
                    .frame(width: 7, height: 7)
            }
        }
    }

    // MARK: - Card

    @ViewBuilder
    private func cardView(optionIndex: Int) -> some View {
        let offset = optionIndex - selectedOption
        let isCentered = offset == 0
        let option = options[optionIndex]
        let side: CGFloat = offset < 0 ? -1 : 1

        VStack(alignment: .leading, spacing: isCentered ? 16 : 14) {
            // Icon + title row
            HStack(spacing: 12) {
                Image(systemName: option.icon)
                    .font(.system(size: isCentered ? 28 : 20, weight: .medium))
                    .foregroundStyle(option.iconColor)
                    .frame(width: isCentered ? 54 : 42, height: isCentered ? 54 : 42)
                    .background(option.iconColor.opacity(0.16))
                    .clipShape(RoundedRectangle(cornerRadius: isCentered ? 15 : 11))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(option.title)
                            .font(.system(size: isCentered ? 18 : 15, weight: .bold))
                            .foregroundStyle(.white)
                        if let badge = option.badge {
                            Text(badge)
                                .font(.system(size: 8, weight: .heavy))
                                .foregroundStyle(option.iconColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(option.iconColor.opacity(0.2))
                                .clipShape(Capsule())
                        }
                    }
                    if !isCentered {
                        Text(option.subtitle)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                }
            }

            if isCentered {
                Text(option.description)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)

                // Per-choice detail
                switch option.choice {
                case .steamGridDB:
                    Text("steamgriddb.com  →  Preferences  →  API Keys  →  Create Key")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Paste your API key here", text: $steamGridKey)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10).padding(.vertical, 9)
                            .background(Color.white.opacity(0.1))
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(keyError ? .red : Color.white.opacity(0.22), lineWidth: 1)
                            )
                            .onChange(of: steamGridKey) { _, _ in keyError = false }
                        if keyError {
                            Text("Paste your API key to continue.")
                                .font(.system(size: 11))
                                .foregroundStyle(.red.opacity(0.9))
                        }
                    }

                case .own:
                    Text("~/Library/Application Support/Marquee/Art/\nHi Fi RUSH.jpg")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Text(".jpg · .jpeg · .png all accepted")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))

                case .automatic:
                    HStack(spacing: 8) {
                        sourcePill("Steam",     color: Color(red: 0.1, green: 0.4, blue: 0.8))
                        sourcePill("CrossOver", color: Color(red: 0.75, green: 0.2, blue: 0.1))
                        sourcePill("Epic",      color: Color(red: 0.4, green: 0.1, blue: 0.8))
                    }
                    Text("Great for Steam. Bundled CrossOver icons are used as fallback for Windows games.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.4))
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Action button
                Button(action: confirmCurrent) {
                    Text(option.choice == .steamGridDB ? "Connect & Start" : "Choose This Method")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.black)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }
        }
        .padding(isCentered ? 28 : 22)
        .frame(width: isCentered ? 390 : 290)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(isCentered ? Color.white.opacity(0.11) : Color.white.opacity(0.055))
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(
                            isCentered ? Color.white.opacity(0.38) : Color.white.opacity(0.09),
                            lineWidth: isCentered ? 1.5 : 1
                        )
                )
        )
        .shadow(color: .black.opacity(isCentered ? 0.55 : 0.15), radius: isCentered ? 36 : 8)
        .scaleEffect(isCentered ? 1.0 : 0.76)
        .rotation3DEffect(
            .degrees(isCentered ? 0 : Double(side) * 28),
            axis: (x: 0, y: 1, z: 0),
            perspective: 0.45
        )
        .offset(x: isCentered ? 0 : side * 308)
        .opacity(isCentered ? 1.0 : 0.60)
        .onTapGesture { if !isCentered { withAnimation { selectedOption = optionIndex } } }
        .animation(.spring(response: 0.38, dampingFraction: 0.82), value: selectedOption)
    }

    private func sourcePill(_ label: String, color: Color) -> some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(color.opacity(0.35))
            .clipShape(Capsule())
    }

    // MARK: - Navigation

    private func navigateDelta(_ delta: Int) {
        let count = options.count
        withAnimation { selectedOption = ((selectedOption + delta) % count + count) % count }
    }

    private func confirmCurrent() {
        let option = options[selectedOption]
        switch option.choice {
        case .steamGridDB:
            guard !steamGridKey.trimmingCharacters(in: .whitespaces).isEmpty else {
                withAnimation { keyError = true }
                return
            }
            appState.saveArtPreference(.steamGridDB, steamGridKey: steamGridKey.trimmingCharacters(in: .whitespaces))
        case .own:
            appState.saveArtPreference(.own)
        case .automatic:
            appState.saveArtPreference(.automatic)
        }
    }
}
