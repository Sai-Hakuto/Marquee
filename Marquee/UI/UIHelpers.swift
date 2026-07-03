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
