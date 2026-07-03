import GameController

// Watches for connected game controllers and maps their input to app actions.
// Navigation (left/right) sets appState.selectedIndex directly so ContentView's
// onChange can drive the carousel. Confirm/back set appState.controllerAction
// which ContentView consumes.
@MainActor
final class ControllerInput {
    private weak var appState: AppState?
    private var observers: [Any] = []
    private var axisCooldown = false    // prevents thumbstick from firing hundreds of times/sec

    init() {
        // Discover Bluetooth controllers in range.
        GCController.startWirelessControllerDiscovery {}

        observers.append(
            NotificationCenter.default.addObserver(
                forName: .GCControllerDidConnect,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard let controller = note.object as? GCController else { return }
                Task { @MainActor [weak self] in self?.wire(controller) }
            }
        )
        observers.append(
            NotificationCenter.default.addObserver(
                forName: .GCControllerDidDisconnect,
                object: nil,
                queue: .main
            ) { _ in }  // could show a HUD later
        )
        // Wire already-connected controllers (Task ensures main-actor isolation)
        let existing = GCController.controllers()
        Task { @MainActor [weak self] in existing.forEach { self?.wire($0) } }
    }

    func bind(to appState: AppState) {
        self.appState = appState
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        GCController.stopWirelessControllerDiscovery()
    }

    // MARK: - Wiring

    private func wire(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }

        // D-pad — all four directions route through the shared key-handling path in
        // ContentView, so each focus zone (carousel, grid/wall/list, music widget,
        // top/bottom bars, detail page) reacts the same as it does to the arrow keys.
        pad.dpad.left.pressedChangedHandler  = { [weak self] _, _, pressed in if pressed { self?.fire(.navLeft) } }
        pad.dpad.right.pressedChangedHandler = { [weak self] _, _, pressed in if pressed { self?.fire(.navRight) } }
        pad.dpad.up.pressedChangedHandler    = { [weak self] _, _, pressed in if pressed { self?.fire(.navUp) } }
        pad.dpad.down.pressedChangedHandler  = { [weak self] _, _, pressed in if pressed { self?.fire(.navDown) } }

        // Left thumbstick — cool-down prevents a held stick from blazing through the library
        pad.leftThumbstick.xAxis.valueChangedHandler = { [weak self] _, value in
            guard let self else { return }
            if abs(value) > 0.55, !self.axisCooldown {
                self.fire(value > 0 ? .navRight : .navLeft)
                self.axisCooldown = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 250_000_000)   // 250 ms
                    self.axisCooldown = false
                }
            } else if abs(value) < 0.25 {
                self.axisCooldown = false
            }
        }
        // Left thumbstick vertical — up/down for zone switching + volume in the music widget.
        pad.leftThumbstick.yAxis.valueChangedHandler = { [weak self] _, value in
            guard let self else { return }
            if abs(value) > 0.55, !self.axisCooldown {
                self.fire(value > 0 ? .navUp : .navDown)
                self.axisCooldown = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    self.axisCooldown = false
                }
            } else if abs(value) < 0.25 {
                self.axisCooldown = false
            }
        }

        // A (Xbox) / Cross (PlayStation) = confirm
        pad.buttonA.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { self?.confirm() }
        }

        // B (Xbox) / Circle (PlayStation) = back
        pad.buttonB.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { self?.back() }
        }

        // Shoulder buttons (L1/R1) — previous/next game, used on the Detail page.
        pad.leftShoulder.pressedChangedHandler  = { [weak self] _, _, pressed in if pressed { self?.fire(.pageLeft) } }
        pad.rightShoulder.pressedChangedHandler = { [weak self] _, _, pressed in if pressed { self?.fire(.pageRight) } }

        // Menu/Start button — toggle full screen, the same action as ⌥⏎/⌃⌘F/the top-bar button.
        pad.buttonMenu.pressedChangedHandler = { [weak self] _, _, pressed in
            if pressed { self?.fire(.toggleFullScreen) }
        }
    }

    // MARK: - Actions

    private func fire(_ action: ControllerAction) {
        guard let appState else { return }
        appState.lastInputMethod = .controller
        appState.controllerAction = action
    }

    private func confirm() { fire(.confirm) }
    private func back()    { fire(.back) }
}
