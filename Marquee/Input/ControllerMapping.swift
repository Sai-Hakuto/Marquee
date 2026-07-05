import Foundation
import Observation

// User-remappable controller buttons. Directional input (d-pad, thumbsticks) is deliberately
// NOT remappable — direction is direction on every brand of pad; what differs between
// ecosystems (and muscle memories) is which face button means "yes" and which means "no"
// (Xbox: A confirms / B backs out; Nintendo: physically swapped), plus where people expect
// pause and prev/next to live.
enum ControllerButton: String, CaseIterable {
    case a, b, x, y
    case leftShoulder, rightShoulder
    case leftTrigger, rightTrigger
    case menu, options

    // Position-based labels (what the button IS on the pad, not what it does) — shown in the
    // remap UI and the pause menu's button hints.
    var label: String {
        switch self {
        case .a:             return "A"
        case .b:             return "B"
        case .x:             return "X"
        case .y:             return "Y"
        case .leftShoulder:  return "LB"
        case .rightShoulder: return "RB"
        case .leftTrigger:   return "LT"
        case .rightTrigger:  return "RT"
        case .menu:          return "Menu"
        case .options:       return "Options"
        }
    }
}

// Everything a button can be asked to do. Small on purpose: navigation stays on the
// d-pad/sticks, so a remap can rearrange the verbs but never orphan movement itself.
enum MappableAction: String, CaseIterable {
    case confirm, back, pauseMenu, prevGame, nextGame, prevFilter, nextFilter

    var label: String {
        switch self {
        case .confirm:    return "Confirm / Select"
        case .back:       return "Back / Cancel"
        case .pauseMenu:  return "Pause Menu"
        case .prevGame:   return "Previous Game / View"
        case .nextGame:   return "Next Game / View"
        case .prevFilter: return "Previous Filter"
        case .nextFilter: return "Next Filter"
        }
    }

    var subtitle: String {
        switch self {
        case .confirm:    return "Open Detail, press buttons, launch"
        case .back:       return "Close overlays, step out of menus"
        case .pauseMenu:  return "The console-style overlay"
        case .prevGame:   return "Detail page: step back — library pages: switch view mode"
        case .nextGame:   return "Detail page: step forward — library pages: switch view mode"
        case .prevFilter: return "Cycle the source filter chip backward"
        case .nextFilter: return "Cycle the source filter chip forward"
        }
    }

    // The existing ControllerAction each verb fires — ControllerInput routes a pressed button
    // through the mapping to one of these, and ContentView's onChange consumes them exactly as
    // it always has. Remapping never adds a new downstream code path.
    var controllerAction: ControllerAction {
        switch self {
        case .confirm:    return .confirm
        case .back:       return .back
        case .pauseMenu:  return .pauseMenu
        case .prevGame:   return .pageLeft
        case .nextGame:   return .pageRight
        case .prevFilter: return .filterLeft
        case .nextFilter: return .filterRight
        }
    }

    var defaultButton: ControllerButton {
        switch self {
        case .confirm:    return .a
        case .back:       return .b
        case .pauseMenu:  return .menu
        case .prevGame:   return .leftShoulder
        case .nextGame:   return .rightShoulder
        case .prevFilter: return .leftTrigger
        case .nextFilter: return .rightTrigger
        }
    }
}

// The one shared mapping between ControllerInput (reads it on every button press) and the
// remap UIs (Settings' Controller section, the pause menu's layout cycler). A singleton
// rather than an AppState member because ControllerInput and the Settings scene have no
// common ancestor to inject it through.
//
// INVARIANT: `assignments` is always TOTAL — every MappableAction has exactly one button at
// all times. There is no "unassign"; giving a button to an action that would steal it from
// another action SWAPS the two instead. That's what makes it impossible to remap yourself
// into a dead controller (e.g. no confirm button anywhere) no matter what's pressed in the
// rebind flow.
@MainActor
@Observable
final class ControllerMappingStore {
    static let shared = ControllerMappingStore()

    private static let defaultsKey = "controllerButtonAssignments"

    private(set) var assignments: [MappableAction: ControllerButton]

    // Non-nil while the Settings remap UI is listening for "press any button". ControllerInput
    // checks this FIRST on every button press and routes the press here instead of firing its
    // action — so the app doesn't navigate underneath the capture prompt.
    private(set) var captureTarget: MappableAction? = nil
    private var captureTimeout: Task<Void, Never>? = nil

    private init() {
        assignments = Self.load()
    }

    // MARK: - Reads

    func button(for action: MappableAction) -> ControllerButton {
        assignments[action] ?? action.defaultButton
    }

    func action(for button: ControllerButton) -> MappableAction? {
        assignments.first(where: { $0.value == button })?.key
    }

    // MARK: - Presets

    enum Preset: String, CaseIterable {
        case standard   // Xbox/PlayStation convention: A(×) confirms, B(○) backs out
        case nintendo   // Switch convention: the two face buttons swap roles

        var label: String {
            switch self {
            case .standard: return "Standard (Xbox)"
            case .nintendo: return "Swapped (Nintendo)"
            }
        }
    }

    // Which preset the current assignments amount to — nil when hand-customized beyond both.
    var activePreset: Preset? {
        let defaults = MappableAction.allCases.allSatisfy {
            $0 == .confirm || $0 == .back || button(for: $0) == $0.defaultButton
        }
        guard defaults else { return nil }
        if button(for: .confirm) == .a, button(for: .back) == .b { return .standard }
        if button(for: .confirm) == .b, button(for: .back) == .a { return .nintendo }
        return nil
    }

    func applyPreset(_ preset: Preset) {
        var next: [MappableAction: ControllerButton] = [:]
        for action in MappableAction.allCases { next[action] = action.defaultButton }
        if preset == .nintendo {
            next[.confirm] = .b
            next[.back] = .a
        }
        assignments = next
        persist()
    }

    // MARK: - Rebinding (swap-on-conflict)

    func assign(_ button: ControllerButton, to action: MappableAction) {
        let previous = self.button(for: action)
        if let holder = self.action(for: button), holder != action {
            assignments[holder] = previous
        }
        assignments[action] = button
        persist()
        endCapture()
    }

    func beginCapture(for action: MappableAction) {
        captureTarget = action
        captureTimeout?.cancel()
        // Nothing pressed for a while = the user wandered off (or has no controller in hand) —
        // don't leave the app permanently swallowing every button press.
        captureTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled else { return }
            self?.endCapture()
        }
    }

    func endCapture() {
        captureTimeout?.cancel()
        captureTimeout = nil
        captureTarget = nil
    }

    // MARK: - Persistence

    private func persist() {
        let raw = Dictionary(uniqueKeysWithValues: assignments.map { ($0.key.rawValue, $0.value.rawValue) })
        UserDefaults.standard.set(raw, forKey: Self.defaultsKey)
    }

    private static func load() -> [MappableAction: ControllerButton] {
        var result: [MappableAction: ControllerButton] = [:]
        let raw = UserDefaults.standard.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        for action in MappableAction.allCases {
            result[action] = raw[action.rawValue].flatMap(ControllerButton.init(rawValue:))
                ?? action.defaultButton
        }
        // A hand-edited/corrupt defaults entry could give two actions the same button — that
        // breaks the totality invariant the swap logic relies on, so fall back to defaults.
        if Set(result.values).count != result.count {
            result = Dictionary(uniqueKeysWithValues: MappableAction.allCases.map { ($0, $0.defaultButton) })
        }
        return result
    }
}
