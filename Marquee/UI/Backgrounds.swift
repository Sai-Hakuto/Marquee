import SwiftUI
import AppKit

// The three decorative background layers, stacked (back to front) as:
// OuterspaceBackground (or a flat theme color) → HeroBackground → MotionOverlay.
// All of them gate their continuous animation on AppState.windowVisible so a minimized or
// fully-covered window costs (almost) nothing — important while a game runs in front of us.

// MARK: - Motion Overlay (sine-wave particle canvas)
//
// All elements are confined to the top 25% and bottom 25% of the window — the carousel
// fills the middle and would hide anything placed there. Animation is seamless because
// everything is driven by sin/cos (naturally periodic — no jumps, no resets).

struct MotionOverlay: View {
    var showWaves: Bool = true    // false → particles only (used on the Detail page)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 30.0)) { timeline in
            Canvas { ctx, size in
                let t = timeline.date.timeIntervalSinceReferenceDate
                if showWaves {
                    MotionOverlay.drawWaves(ctx, size: size, t: t)
                    MotionOverlay.drawWisps(ctx, size: size, t: t)
                    MotionOverlay.drawOrbs(ctx, size: size, t: t)
                }
                MotionOverlay.drawParticles(ctx, size: size, t: t)
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }

    // Waves in the top 25% (yFrac 0.05–0.22) and bottom 25% (yFrac 0.78–0.95).
    // Amplitude is small enough that the wave stays within its zone.
    private struct WaveDef {
        let yFrac, amp, freq, speed, phase, lineAlpha, dotStep, dotAlpha, dotR: Double
    }
    private static let waves: [WaveDef] = [
        // Upper band
        WaveDef(yFrac: 0.08, amp: 0.042, freq: 1.8, speed: 0.070, phase: 0.00,
                lineAlpha: 0.22, dotStep: 28, dotAlpha: 0.28, dotR: 1.7),
        WaveDef(yFrac: 0.20, amp: 0.033, freq: 1.3, speed: 0.050, phase: 2.09,
                lineAlpha: 0.17, dotStep: 22, dotAlpha: 0.22, dotR: 1.5),
        // Lower band
        WaveDef(yFrac: 0.82, amp: 0.033, freq: 1.5, speed: 0.060, phase: 1.22,
                lineAlpha: 0.17, dotStep: 22, dotAlpha: 0.22, dotR: 1.5),
        WaveDef(yFrac: 0.93, amp: 0.042, freq: 1.1, speed: 0.040, phase: 3.49,
                lineAlpha: 0.22, dotStep: 28, dotAlpha: 0.28, dotR: 1.7),
    ]

    private static func drawWaves(_ ctx: GraphicsContext, size: CGSize, t: Double) {
        let W = size.width, H = size.height
        let τ = 2 * Double.pi
        for w in waves {
            var path = Path()
            var x = 0.0; var first = true
            while x <= W + 4 {
                let y = w.yFrac * H + sin((x / W * w.freq - t * w.speed) * τ + w.phase) * w.amp * H
                let pt = CGPoint(x: x, y: y)
                if first { path.move(to: pt); first = false } else { path.addLine(to: pt) }
                x += 3
            }
            ctx.stroke(path, with: .color(.white.opacity(w.lineAlpha)), lineWidth: 1.0)
            x = 0
            while x <= W {
                let y = w.yFrac * H + sin((x / W * w.freq - t * w.speed) * τ + w.phase) * w.amp * H
                ctx.fill(Path(ellipseIn: CGRect(x: x - w.dotR, y: y - w.dotR,
                                               width: w.dotR * 2, height: w.dotR * 2)),
                         with: .color(.white.opacity(w.dotAlpha)))
                x += w.dotStep
            }
        }
    }

    // Wisps — thin rotated ellipses drifting slowly through the upper/lower zones.
    // Path.applying(CGAffineTransform) lets us rotate without a full context save/restore.
    private static func drawWisps(_ ctx: GraphicsContext, size: CGSize, t: Double) {
        let W = size.width, H = size.height
        let τ = 2 * Double.pi
        // (x-frac, y-frac, length, thickness, base-rotation, drift-speed, phase, alpha)
        let wisps: [(Double, Double, Double, Double, Double, Double, Double, Double)] = [
            // Upper zone
            (0.10, 0.06,  90, 3.0,  0.15, 0.035, 0.0,  0.12),
            (0.32, 0.13,  65, 2.0, -0.10, 0.028, 1.2,  0.09),
            (0.55, 0.05, 110, 2.5,  0.22, 0.042, 2.4,  0.10),
            (0.74, 0.19,  75, 2.0,  0.08, 0.032, 0.7,  0.08),
            (0.88, 0.10,  55, 2.0, -0.18, 0.038, 3.1,  0.11),
            (0.22, 0.22,  80, 2.5,  0.12, 0.025, 1.8,  0.07),
            (0.65, 0.15,  95, 3.0, -0.08, 0.030, 4.2,  0.09),
            // Lower zone
            (0.08, 0.80,  85, 2.5, -0.12, 0.038, 0.5,  0.11),
            (0.28, 0.90,  70, 2.0,  0.18, 0.030, 1.9,  0.09),
            (0.50, 0.83, 100, 3.0,  0.06, 0.035, 3.3,  0.12),
            (0.70, 0.93,  60, 2.0, -0.22, 0.042, 0.9,  0.08),
            (0.85, 0.78,  90, 2.5,  0.14, 0.028, 2.6,  0.10),
            (0.40, 0.88,  75, 2.0, -0.08, 0.032, 4.8,  0.07),
            (0.92, 0.85,  55, 2.0,  0.20, 0.038, 1.4,  0.09),
        ]
        for (bxF, byF, len, thick, rot, sp, ph, alpha) in wisps {
            let cx = bxF * W + sin(t * sp * τ + ph) * 18
            let cy = byF * H + cos(t * (sp * 0.7) * τ + ph + 0.5) * 8
            let angle = rot + sin(t * sp * 0.4 * τ + ph) * 0.06
            let rect  = CGRect(x: -len / 2, y: -thick / 2, width: len, height: thick)
            let xform = CGAffineTransform(translationX: cx, y: cy).rotated(by: angle)
            ctx.fill(Path(ellipseIn: rect).applying(xform), with: .color(.white.opacity(alpha)))
        }
    }

    private static func drawOrbs(_ ctx: GraphicsContext, size: CGSize, t: Double) {
        let W = size.width, H = size.height
        let τ = 2 * Double.pi
        // Orbs in top 25% and bottom 25% only
        let orbs: [(Double, Double, Double, Double, Double, Double)] = [
            (0.15, 0.08, 16, 12, 0.07, 0.00),  // upper
            (0.43, 0.14, 12, 10, 0.06, 1.57),
            (0.78, 0.06, 18, 14, 0.08, 0.80),
            (0.25, 0.85, 14, 12, 0.07, 2.36),  // lower
            (0.58, 0.92, 18, 14, 0.06, 3.14),
            (0.85, 0.80, 13, 10, 0.09, 1.88),
        ]
        for (bx, by, r, dy, sp, ph) in orbs {
            let ox = bx * W
            let oy = by * H + sin(t * sp * τ + ph) * dy
            for ring in stride(from: 3, through: 0, by: -1) {
                let rf = Double(ring)
                let rr = r * (1.0 + (3.0 - rf) * 0.65)
                ctx.fill(Path(ellipseIn: CGRect(x: ox - rr, y: oy - rr, width: rr * 2, height: rr * 2)),
                         with: .color(.white.opacity(0.05 / (rf * 0.5 + 0.4))))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: ox - 2, y: oy - 2, width: 4, height: 4)),
                     with: .color(.white.opacity(0.40)))
        }
    }

    private static func drawParticles(_ ctx: GraphicsContext, size: CGSize, t: Double) {
        let W = size.width, H = size.height
        let τ = 2 * Double.pi
        // First 23 land in the upper 22% of the screen; the rest in the lower 22%.
        for i in 0..<45 {
            let fi  = Double(i)
            let bx  = (fi * 137.508).truncatingRemainder(dividingBy: W)
            let rawY = (fi * 97.321).truncatingRemainder(dividingBy: H * 0.22)
            let by  = i < 23 ? rawY + H * 0.01 : H * 0.77 + rawY
            let px  = bx + sin(t * 0.04 * τ + fi * 0.83) * 10
            let py  = by + cos(t * 0.03 * τ + fi * 0.51) * 6
            let sz  = 1.5 + (fi * 2.5).truncatingRemainder(dividingBy: 2.0)
            let alpha = 0.07 + (fi * 7.3).truncatingRemainder(dividingBy: 0.10)
            ctx.fill(Path(ellipseIn: CGRect(x: px - sz / 2, y: py - sz / 2, width: sz, height: sz)),
                     with: .color(.white.opacity(alpha)))
        }
    }
}

// MARK: - Outerspace Animated Background

struct OuterspaceBackground: View {
    @Environment(AppState.self) private var appState
    @State private var pulse1: Double = 0
    @State private var pulse2: Double = 0

    var body: some View {
        ZStack {
            Color(red: 0.10, green: 0.04, blue: 0.22)
            // Primary nebula — large, upper-left drift
            RadialGradient(
                colors: [
                    Color(red: 0.52, green: 0.12, blue: 0.90).opacity(pulse1),
                    Color(red: 0.22, green: 0.05, blue: 0.52).opacity(pulse1 * 0.55),
                    .clear
                ],
                center: .init(x: 0.35, y: 0.25),
                startRadius: 60,
                endRadius: 660
            )
            // Secondary nebula — smaller, lower-right counter-phase
            RadialGradient(
                colors: [
                    Color(red: 0.20, green: 0.05, blue: 0.72).opacity(pulse2),
                    .clear
                ],
                center: .init(x: 0.72, y: 0.70),
                startRadius: 20,
                endRadius: 400
            )
        }
        .ignoresSafeArea()
        .onAppear {
            if appState.windowVisible { startPulsing() }
        }
        // Real continuous cost (RadialGradient interpolated every frame) for a purely
        // decorative nebula — pause it the instant nobody can see the window (miniaturized,
        // fully covered, or on another Space) and resume on return. A plain (non-animated)
        // reassignment cancels an in-flight repeatForever loop and holds the current value,
        // so pausing costs nothing extra and resuming just starts the same loop again.
        .onChange(of: appState.windowVisible) { _, visible in
            if visible {
                startPulsing()
            } else {
                pulse1 = pulse1
                pulse2 = pulse2
            }
        }
    }

    private func startPulsing() {
        withAnimation(.easeInOut(duration: 5).repeatForever(autoreverses: true)) {
            pulse1 = 0.72
        }
        withAnimation(.easeInOut(duration: 3.5).delay(1.2).repeatForever(autoreverses: true)) {
            pulse2 = 0.55
        }
    }
}

// MARK: - Dynamic Hero Background
// The selected game's wide Steam hero art, heavily blurred + dimmed, sitting behind the
// carousel and crossfading on selection change. Falls back to nothing (theme shows through)
// when the game has no Steam match. Lazily loaded per selection; the art cache makes repeat
// selections instant. Toggleable via the Appearance menu (UserDefaults "heroBackgroundEnabled").
struct HeroBackground: View {
    let game: Game?
    @State private var image: NSImage?

    var body: some View {
        // `scaledToFill()` alone lets the image's ideal size (driven by its own aspect ratio)
        // leak into the layout proposal for the rest of `rootStack`'s ZStack, which was pushing
        // the nav bar logo/icons, music player, and bottom controls out of the visible window
        // (positions looked correct via GeometryReader, but the elements never actually drew —
        // a SwiftUI ideal-size/compositing quirk fixed by giving the image a hard, bounded frame
        // to fill instead of letting it size itself first).
        GeometryReader { geo in
            ZStack {
                if let image {
                    // Dialed back from the original 40pt/0.55 combo, which blurred the art past
                    // the point of resembling the game at all — this keeps enough shape/color
                    // through to read as "that game's backdrop" while still staying a subtle,
                    // out-of-focus layer behind the foreground content.
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .blur(radius: 12.8)
                        .overlay(Color.black.opacity(0.42))
                        .transition(.opacity)
                        .id(image)
                }
            }
        }
        .ignoresSafeArea()
        // Keyed on connectivity too: fetchHero returns nil offline (theme backdrop only), so a
        // reconnect must retry the CURRENT selection — the id-only key would otherwise leave it
        // hero-less until the user happens to move.
        .task(id: "\(game?.id.uuidString ?? "-")/\(NetworkMonitor.shared.isOnline)") {
            guard let game else { withAnimation(.easeInOut(duration: 0.5)) { image = nil }; return }
            let url = await ArtFetcher.shared.fetchHero(for: game)
            let loaded = url.flatMap { NSImage(contentsOf: $0) }
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.5)) { image = loaded }
        }
    }
}
