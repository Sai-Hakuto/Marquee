import SwiftUI
import AppKit

// Small shared UI pieces used across several views.

// MARK: - Filter chip button style (top nav bar)

struct FilterChipStyle: ButtonStyle {
    let isActive: Bool
    var isDim: Bool = false
    var isFocused: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(isActive ? .white : (isDim ? .white.opacity(0.32) : .white.opacity(0.48)))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(isActive ? Color.white.opacity(0.22) : Color.white.opacity(isDim ? 0.04 : 0.06))
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(isFocused ? Color.white.opacity(0.9) : .clear, lineWidth: 2))
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
    }
}

// MARK: - PLAY hold-to-confirm (decisions.md #96)
//
// Traces a border stroke around a PLAY-shaped button as AppState.playHoldProgress climbs from
// 0 to 1 over the hold duration, starting from the shape's own path origin and sweeping all the
// way around — it only forms a fully closed loop ("connects to the other side") right as the
// hold completes, matching Jack's own description of the desired feel.
struct PlayHoldOutline: View {
    let progress: Double
    let cornerRadius: CGFloat
    var color: Color = .white

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .trim(from: 0, to: progress)
            .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
            .shadow(color: color.opacity(0.8), radius: progress > 0.02 ? 5 : 0)
            .allowsHitTesting(false)
    }
}

// A drop-in replacement for `Button { session.launch(game) } label: { ... }` on every
// PLAY-shaped control — launching now requires holding for `AppState.playHoldDuration` instead
// of firing on a single click/key/button press (Jack's report: it's too easy to accidentally
// launch a game). Built on `DragGesture(minimumDistance: 0)` rather than `Button` because a
// `Button`'s action fires on release regardless of how long it was held — there's no way to
// make it require a duration. `onChanged` (fires continuously while pressed) starts the hold
// exactly once (`AppState.beginPlayHold` is idempotent per-game); `onEnded` (release) cancels it
// if it hasn't completed. `cornerRadius` must match the caller's own `.clipShape`/`.background`
// corner radius so the hold-progress outline traces the button's actual edge. Keyboard/
// controller confirm on a focused PLAY control does NOT go through this view at all — those
// route through the identical `AppState.beginPlayHold`/`cancelPlayHold` pair directly from
// ContentView's key/controller router, so all three input methods share one implementation and
// one clock, just reached from different gesture recognizers.
struct PlayHoldButton<Label: View>: View {
    let game: Game
    let cornerRadius: CGFloat
    let onComplete: () -> Void
    @ViewBuilder let label: () -> Label

    @Environment(AppState.self) private var appState

    var body: some View {
        let isHeld = appState.playHoldTargetID == game.id
        label()
            .overlay(PlayHoldOutline(progress: isHeld ? appState.playHoldProgress : 0,
                                      cornerRadius: cornerRadius))
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in appState.beginPlayHold(game, onComplete: onComplete) }
                    .onEnded { _ in appState.cancelPlayHold(game) }
            )
    }
}

// MARK: - Helpers

extension Array {
    subscript(safe index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}

// Bridges NSMenuItem target-action (ObjC) to a Swift closure
final class MenuAction: NSObject {
    private let closure: () -> Void
    init(_ closure: @escaping () -> Void) { self.closure = closure }
    @objc func run() { closure() }
}

// MARK: - Theme Colors

extension AppState.AppTheme {
    var backgroundColor: Color {
        switch self {
        case .outerspace: return Color(red: 0.10, green: 0.04, blue: 0.22)
        case .jetBlack:   return .black
        case .softGrey:   return Color(red: 0.13, green: 0.13, blue: 0.15)
        }
    }

    var sceneBackground: NSColor {
        switch self {
        case .outerspace: return NSColor(red: 0.10, green: 0.04, blue: 0.22, alpha: 1)
        case .jetBlack:   return .black
        case .softGrey:   return NSColor(white: 0.13, alpha: 1)
        }
    }

    var swatch: Color {
        switch self {
        case .outerspace: return Color(red: 0.42, green: 0.10, blue: 0.78)
        case .jetBlack:   return Color(white: 0.18)   // lifted from 0.08 so it's visible on dark chrome
        case .softGrey:   return Color(white: 0.42)
        }
    }
}
