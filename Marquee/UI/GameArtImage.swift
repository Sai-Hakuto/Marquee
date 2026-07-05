import SwiftUI
import AppKit

// Gold star badge shown in the top-right corner of favorited cover art (grid + wall).
struct FavoriteStar: View {
    var size: CGFloat = 20

    var body: some View {
        Image(systemName: "star.fill")
            .font(.system(size: size * 0.62, weight: .bold))
            .foregroundStyle(Color(red: 1.0, green: 0.80, blue: 0.25))
            .frame(width: size, height: size)
            .background(Circle().fill(Color.black.opacity(0.46)))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.10), lineWidth: 1))
            .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
    }
}

// Small "press this to activate" badge shown in the bottom-right corner of whichever button
// is currently keyboard/controller-focused (or, for the Detail page's always-available prev/
// next arrows, a fixed shortcut hint) — reflects AppState.lastInputMethod live, same signal
// the top-bar input-method indicator uses. Never shown for mouse users, who just click.
struct InputHintBadge: View {
    enum Kind: Equatable {
        case confirm                                        // the focused control's activation key
        case directional(keyboard: String, controller: String)  // a fixed hint, not tied to focus
    }
    let kind: Kind
    let inputMethod: InputMethod

    var body: some View {
        Group {
            switch (kind, inputMethod) {
            case (.confirm, .keyboard):
                // Mini spacebar-key glyph — the one key every keyboard user immediately reads.
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(Color.black.opacity(0.82))
                    .frame(width: 15, height: 6)
            case (.confirm, .controller):
                Text("A")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .foregroundStyle(.black.opacity(0.85))
            case (.directional(let kb, _), .keyboard):
                Text(kb)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.black.opacity(0.85))
            case (.directional(_, let ctrl), .controller):
                Text(ctrl)
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(.black.opacity(0.85))
            default:
                EmptyView()
            }
        }
        .frame(width: 24, height: 24)
        .background(Circle().fill(Color.white.opacity(0.95)))
        .overlay(Circle().strokeBorder(Color.black.opacity(0.2), lineWidth: 1))
        .shadow(color: .black.opacity(0.45), radius: 3, y: 1)
    }
}

extension View {
    // Overlays an InputHintBadge at the bottom-trailing corner — nil kind or a mouse user
    // renders nothing, so call sites can pass their focus check straight through.
    @ViewBuilder
    func inputHint(_ kind: InputHintBadge.Kind?, method: InputMethod) -> some View {
        if let kind, method != .mouse {
            overlay(alignment: .bottomTrailing) {
                InputHintBadge(kind: kind, inputMethod: method)
                    .offset(x: 8, y: 8)
                    .transition(.scale.combined(with: .opacity))
            }
        } else {
            self
        }
    }
}

// Source color as a SwiftUI Color, derived from Game.sourceBadgeColor.
extension Game {
    var sourceColor: Color {
        let (r, g, b) = sourceBadgeColor
        return Color(red: r, green: g, blue: b)
    }
}

// Branded source pill ("Steam" / "CrossOver" / "Mac" / "Epic"). One component used
// everywhere a source is labelled — the carousel info bar, the list rows + detail panel,
// the grid/wall corner badges, and the Fix Cover panel — so the styling stays identical.
struct SourceBadge: View {
    let game: Game
    enum Size { case regular, compact, mini }
    var size: Size = .regular

    private var font: Font {
        switch size {
        case .regular: return .system(size: 11, weight: .semibold)
        case .compact: return .system(size: 10, weight: .bold)
        case .mini:    return .system(size: 8.5, weight: .bold)
        }
    }
    private var hPad: CGFloat { switch size { case .regular: 8; case .compact: 6.5; case .mini: 5 } }
    private var vPad: CGFloat { switch size { case .regular: 3; case .compact: 2.5; case .mini: 1.5 } }

    // Steam-in-CrossOver games (CrossOverSource.scanBottledSteamLibrary) show a small
    // Steam-blue badge peeking out from behind the CrossOver pill's right edge — with Steam
    // installed INSIDE a bottle, a "CrossOver" game is frequently
    // also a Steam game under the hood, and the pill alone hides that. Purely cosmetic:
    // `GameMetadata.viaLauncher` is read ONLY here, never by filtering/launch/identity.
    private var peekingBrandColor: Color? {
        guard case .crossOver = game.source, game.metadata.viaLauncher == "steam" else { return nil }
        return Color(red: 0.11, green: 0.49, blue: 0.82)  // same blue as .steam's sourceBadgeColor
    }
    private var peekDiameter: CGFloat { switch size { case .regular: 15; case .compact: 12; case .mini: 10 } }
    private var peekOffsetX: CGFloat { switch size { case .regular: 9; case .compact: 7; case .mini: 6 } }

    var body: some View {
        let pill = Text(game.sourceBadgeTitle)
            .font(font)
            .foregroundStyle(.white)
            .padding(.horizontal, hPad)
            .padding(.vertical, vPad)
            .background(Capsule().fill(game.sourceColor.opacity(0.92)))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.22), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
            .fixedSize()

        // Drawn via .background (not .overlay) so the opaque pill paints OVER most of the
        // circle — only the offset sliver past the trailing edge is visible, reading as "peeking
        // out from behind" rather than a badge stuck on top. The rotation tilts the glyph itself
        // (a plain circle wouldn't visibly read as angled) for a "peeking around a corner" look.
        if let color = peekingBrandColor {
            pill.background(alignment: .trailing) {
                SteamGlyph()
                    .frame(width: peekDiameter * 0.62, height: peekDiameter * 0.62)
                    .frame(width: peekDiameter, height: peekDiameter)
                    .background(Circle().fill(color))
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.4), radius: 1.5, y: 1)
                    .rotationEffect(.degrees(16))
                    .offset(x: peekOffsetX, y: -peekDiameter * 0.32)
            }
        } else {
            pill
        }
    }
}

// A simplified, recognizable rendition of Steam's own mark (the outer ring + two "pearls"
// joined by a swoosh) — replaces the plain "S" letter the peeking badge used to show, so it
// reads as Steam's actual icon rather than an abbreviation, even at SourceBadge's smallest
// (10pt) size. Drawn as vector shapes (not a bundled bitmap) so it stays crisp at any size and
// needs no new asset/bundling step.
private struct SteamGlyph: View {
    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            let lineW = w * 0.11

            var ring = Path()
            ring.addEllipse(in: CGRect(x: w * 0.06, y: h * 0.06, width: w * 0.88, height: h * 0.88))
            ctx.stroke(ring, with: .color(.white), lineWidth: lineW)

            var swoosh = Path()
            swoosh.move(to: CGPoint(x: w * 0.30, y: h * 0.74))
            swoosh.addQuadCurve(to: CGPoint(x: w * 0.72, y: h * 0.30),
                                 control: CGPoint(x: w * 0.28, y: h * 0.28))
            ctx.stroke(swoosh, with: .color(.white), lineWidth: lineW * 0.85)

            ctx.fill(Path(ellipseIn: CGRect(x: w * 0.18, y: h * 0.58, width: w * 0.28, height: h * 0.28)),
                     with: .color(.white))
            ctx.fill(Path(ellipseIn: CGRect(x: w * 0.56, y: h * 0.18, width: w * 0.22, height: h * 0.22)),
                     with: .color(.white))
        }
    }
}

// Shared right-click menu used by grid / wall / list tiles (the carousel uses its own
// AppKit NSMenu). Fix Cover Art opens the same Fix Cover panel; Hide/Unhide toggles
// visibility. Drop into any view via `.contextMenu { GameContextMenu(game: game) }`.
struct GameContextMenu: View {
    @Environment(AppState.self) private var appState
    let game: Game
    // List view shows landscape banner art, so it also offers "Fix Banner Art…".
    var showFixBanner: Bool = false

    var body: some View {
        let isHidden = appState.hiddenGameIDs.contains(game.id)
        Button {
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                appState.fixCoverTarget = game
            }
        } label: { Label("Fix Cover Art…", systemImage: "photo") }

        if showFixBanner {
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    appState.fixBannerTarget = game
                }
            } label: { Label("Fix Banner Art…", systemImage: "rectangle.on.rectangle") }
        }

        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                appState.toggleFavorite(game)
            }
        } label: {
            Label(appState.isFavorite(game) ? "Remove Favorite" : "Add to Favorites",
                  systemImage: appState.isFavorite(game) ? "star.slash" : "star")
        }

        Divider()

        Button {
            isHidden ? appState.unhideGame(game) : appState.hideGame(game)
        } label: {
            Label(isHidden ? "Unhide Game" : "Hide Game",
                  systemImage: isHidden ? "eye" : "eye.slash")
        }

        if appState.isCustomLibraryGame(game) {
            Button(role: .destructive) {
                appState.removeFromLibrary(game)
            } label: { Label("Remove from Library…", systemImage: "trash") }
        }
    }
}

struct GameArtImage: View {
    let game: Game

    var body: some View {
        if let path = game.localArtPath, let image = NSImage(contentsOf: path) {
            // GeometryReader + an explicit .frame() BEFORE .scaledToFill() is required, not
            // optional — without it, .scaledToFill() reports its own (aspect-correct, but
            // uncapped) ideal size upward instead of the proposed one, and for a square
            // source image (e.g. a bundled .icns app icon, which has no real portrait cover)
            // inside a 2:3 grid/wall tile that oversized report wins the enclosing ZStack's
            // layout, so the tile's own .clipShape masks the OVERFLOWED square instead of the
            // intended tile rect — the art visibly bleeds past its cell into neighbors. Same
            // "unconstrained ideal size" bug class as HeroBackground's v0.11.6 fix; identical cure.
            GeometryReader { geo in
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
        } else {
            placeholderView
        }
    }

    private var placeholderView: some View {
        let (r, g, b) = game.sourceBadgeColor
        return ZStack {
            LinearGradient(
                colors: [
                    Color(red: r * 0.65, green: g * 0.65, blue: b * 0.65),
                    Color(red: r * 0.18, green: g * 0.18, blue: b * 0.18)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            Text(game.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(8)
        }
    }
}

// Landscape Steam header art (460×215), used by List view rows. Loads asynchronously and
// falls back to the portrait cover (scaled to fill the band) until/unless a header resolves.
struct SteamHeaderImage: View {
    @Environment(AppState.self) private var appState
    let game: Game
    @State private var header: NSImage?
    @State private var loaded = false

    var body: some View {
        Group {
            if let header {
                Image(nsImage: header).resizable().scaledToFill()
            } else {
                GameArtImage(game: game)   // portrait fallback, cropped to the band
            }
        }
        // Both fix versions are folded into the task id: a "Fix Cover Art…" override (cover
        // fallback) AND a "Fix Banner Art…" override re-fetch the banner live, no relaunch.
        .task(id: "\(game.id.uuidString)#\(appState.coverFixVersion)#\(appState.bannerFixVersion)") {
            header = nil
            loaded = false
            if let url = await ArtFetcher.shared.fetchHeader(for: game),
               let img = NSImage(contentsOf: url) {
                header = img
            }
            loaded = true
        }
    }
}

// MARK: - List banner: prominent-color panel + comic-book halftone seam + landscape art
//
// Instead of stretching the wide header art across the whole row (where it scales poorly),
// the list banner shows the art zoomed into the RIGHT portion of the row and fills the LEFT
// with a "prominent" color sampled from the art itself. The two halves are blended with a
// gradient plus a Ben-Day / Lichtenstein style halftone dot field so the color appears to
// dissolve into the artwork — a clean, comic-book look.

// Pulls a vibrant, legible backdrop color out of artwork.
enum ArtColor {
    static func prominent(from image: NSImage) -> Color {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return Color(white: 0.18)
        }
        let w = 24, h = 24
        var data = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &data, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: w * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return Color(white: 0.18)
        }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var wr = 0.0, wg = 0.0, wb = 0.0, wsum = 0.0   // saturation-weighted vibrant average
        var ar = 0.0, ag = 0.0, ab = 0.0, n = 0.0      // plain average (fallback for muted art)
        for i in stride(from: 0, to: data.count, by: 4) {
            let r = Double(data[i]) / 255, g = Double(data[i + 1]) / 255, b = Double(data[i + 2]) / 255
            ar += r; ag += g; ab += b; n += 1
            let mx = max(r, g, b), mn = min(r, g, b)
            let sat = mx <= 0 ? 0 : (mx - mn) / mx
            let lum = (r + g + b) / 3
            // Favour saturated, mid-bright pixels; all but ignore near-black / near-white.
            let weight = sat * sat * (lum > 0.12 && lum < 0.9 ? 1 : 0.1)
            wr += r * weight; wg += g * weight; wb += b * weight; wsum += weight
        }

        let r: Double, g: Double, b: Double
        if wsum > 0.02 { r = wr / wsum; g = wg / wsum; b = wb / wsum }
        else if n > 0 { r = ar / n; g = ag / n; b = ab / n }
        else { return Color(white: 0.18) }

        // Tune for a backdrop: punch the saturation a touch and clamp brightness into a deep
        // band so white title text stays legible while the color still reads as "the" color.
        let nsc = NSColor(red: r, green: g, blue: b, alpha: 1).usingColorSpace(.deviceRGB) ?? .darkGray
        var hue: CGFloat = 0, s: CGFloat = 0, br: CGFloat = 0, a: CGFloat = 0
        nsc.getHue(&hue, saturation: &s, brightness: &br, alpha: &a)
        s = min(1, s * 1.18 + 0.04)
        br = min(0.60, max(0.30, br))
        return Color(hue: Double(hue), saturation: Double(s), brightness: Double(br))
    }
}

// Comic-book halftone dots that are large/merged at the start of `axis` (reading as solid
// color) and shrink to nothing by the end — dissolving a solid fill into whatever's beneath/
// beside it. Originally built for ListBannerArt's horizontal color→art seam; also reused as
// a `.mask()` (any opaque color works — only the alpha of what's drawn matters to a mask) for
// a vertical comic-book-dot fade, e.g. the List detail panel's oversized 3D box art tapering
// into transparency at the bottom instead of a hard clip. `fadeStart` (0...1) delays the
// dissolve — everything before it renders as a solid, undotted fill.
struct HalftoneSeam: View {
    let color: Color
    var axis: Axis = .horizontal
    var fadeStart: CGFloat = 0

    var body: some View {
        Canvas { ctx, size in
            let spacing: CGFloat = 7
            let maxR = spacing * 0.72

            if fadeStart > 0 {
                let solidRect = axis == .vertical
                    ? CGRect(x: 0, y: 0, width: size.width, height: size.height * fadeStart)
                    : CGRect(x: 0, y: 0, width: size.width * fadeStart, height: size.height)
                ctx.fill(Path(solidRect), with: .color(color))
            }

            var y: CGFloat = 0
            var row = 0
            while y <= size.height + spacing {
                let xOffset: CGFloat = (row % 2 == 0) ? 0 : spacing / 2
                var x = xOffset
                while x <= size.width + spacing {
                    let raw = axis == .vertical ? y / size.height : x / size.width
                    if raw >= fadeStart {
                        // 0 = solid (fade start), 1 = gone (far end)
                        let t = max(0, min(1, (raw - fadeStart) / max(0.001, 1 - fadeStart)))
                        let r = maxR * (1 - t) * (1 - t)
                        if r > 0.3 {
                            ctx.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                                     with: .color(color))
                        }
                    }
                    x += spacing
                }
                y += spacing
                row += 1
            }
        }
    }
}

// The composited list-row banner: zoomed art on the right, prominent color on the left,
// halftone seam between. Falls back to the portrait cover / placeholder when no header art.
struct ListBannerArt: View {
    @Environment(AppState.self) private var appState
    let game: Game
    var highlighted: Bool

    @State private var header: NSImage?
    @State private var hasArt = false
    @State private var color: Color = Color(white: 0.16)

    var body: some View {
        GeometryReader { geo in
            let W = geo.size.width
            let artW = W * 0.5            // art is genuinely HALF as wide as the old full-row art
            ZStack(alignment: .leading) {
                // Base: the prominent color fills the whole row (it shows on the left and
                // wherever the art's feathered left edge lets it through).
                color

                // Right: the landscape art confined to the right 50% (scaledToFill = zoomed
                // into the frame), with its left edge feathered into the color beneath.
                artLayer
                    .frame(width: artW, height: geo.size.height)
                    .clipped()
                    .frame(width: W, height: geo.size.height, alignment: .trailing)
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.50),
                                .init(color: .white, location: 0.62)
                            ],
                            startPoint: .leading, endPoint: .trailing
                        )
                    )

                // Comic-book halftone dissolve over the seam: dots merge with the color on the
                // left and shrink to nothing over the art, gaps revealing the artwork.
                HalftoneSeam(color: color)
                    .frame(width: W * 0.24)
                    .offset(x: W * 0.42)
                    .allowsHitTesting(false)

                // Subtle dark anchor under the title for guaranteed legibility.
                LinearGradient(
                    colors: [Color.black.opacity(0.30), Color.black.opacity(0)],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: W * 0.45)

                // Dim non-highlighted rows with a flat darken (NOT a stack-wide .opacity,
                // which composites the layers with alpha and bleeds the art through the
                // solid color panel).
                if !highlighted {
                    Color.black.opacity(0.16)
                }
            }
        }
        .task(id: "\(game.id.uuidString)#\(appState.coverFixVersion)#\(appState.bannerFixVersion)") {
            await load()
        }
    }

    @ViewBuilder private var artLayer: some View {
        if let header {
            Image(nsImage: header).resizable().scaledToFill()
        } else {
            GameArtImage(game: game)   // portrait placeholder fill (no art available)
        }
    }

    private func load() async {
        header = nil
        hasArt = false
        var img: NSImage?
        if let url = await ArtFetcher.shared.fetchHeader(for: game), let i = NSImage(contentsOf: url) {
            img = i
        } else if let p = game.localArtPath, let i = NSImage(contentsOf: p) {
            img = i
        }
        header = img
        hasArt = img != nil
        if let img {
            color = ArtColor.prominent(from: img)
        } else {
            let (r, g, b) = game.sourceBadgeColor
            color = Color(red: r, green: g, blue: b)
        }
    }
}

// MARK: - Hover affordance for clickable chrome (filters, view/theme/music icons)
//
// Adds a subtle scale + brightness lift and a pointing-hand cursor while the pointer is
// over the element — so all interactive chrome feels alive, matching the tile hover.
struct HoverHighlight: ViewModifier {
    var scale: CGFloat = 1.14
    var brighten: Double = 0.18
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(hovering ? scale : 1)
            .brightness(hovering ? brighten : 0)
            .animation(.easeOut(duration: 0.13), value: hovering)
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
    }
}

extension View {
    func hoverHighlight(scale: CGFloat = 1.14, brighten: Double = 0.18) -> some View {
        modifier(HoverHighlight(scale: scale, brighten: brighten))
    }
}

// MARK: - Search match glow (Grid/Wall/List)
//
// A soft glow for tiles/rows the live search currently matches — distinct from the purple
// "selected" glow and the gold favorite-star color so all three read as separate signals when
// they overlap. Carousel doesn't need this (the centered box already IS the top match).
// Bright spring-green — the app's palette is otherwise purple (selected)/gold (favorite)/source-
// brand colors, none of which are anywhere near green, so this reads as a distinct third signal
// against any game's own art or the blue/purple hero backdrop.
let searchMatchGlowColor = Color(red: 0.40, green: 1.0, blue: 0.55)

extension View {
    // `active` = this tile is a live search match. `selected` = the existing selection glow is
    // already showing (which should win — it's the stronger, higher-priority signal).
    @ViewBuilder
    func searchMatchGlow(active: Bool, selected: Bool, radius: CGFloat = 16) -> some View {
        if active && !selected {
            shadow(color: searchMatchGlowColor.opacity(0.85), radius: radius, y: 2)
                .shadow(color: searchMatchGlowColor.opacity(0.55), radius: radius * 1.8, y: 2)
        } else {
            self
        }
    }

    // Desaturates + dims a tile the live search no longer matches, so a glance instantly separates
    // "still in the running" from "typed past" without having to read every title. `active` =
    // there's a live query AND this tile doesn't match it at all. `.animation(nil, value:)`
    // overrides the ambient withAnimation the search TextField's own binding wraps every keystroke
    // in (which is what makes grid/wall/list positions slide) — the user asked for this specific
    // effect to snap instantly instead of fading, so it can't inherit that spring.
    @ViewBuilder
    func searchGreyscale(active: Bool) -> some View {
        saturation(active ? 0 : 1)
            .opacity(active ? 0.4 : 1)
            .animation(nil, value: active)
    }
}
