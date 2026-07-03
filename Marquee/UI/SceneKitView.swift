import SwiftUI
import SceneKit
import AppKit

struct SceneKitView: NSViewRepresentable {
    let scene: SCNScene
    var onRightClick: ((SCNNode, NSEvent) -> Void)?
    var onLeftClick: ((SCNNode) -> Void)?
    var onScroll: ((Int) -> Void)?
    var onMouseInside: ((Bool) -> Void)?
    // Drives SCNView.isPlaying — see updateNSView. Defaults true so every existing call site
    // (Detail page's box, etc.) keeps rendering unless it opts in to the visibility gate.
    var isVisible: Bool = true

    func makeNSView(context: Context) -> MarqueeSCNView {
        let view = MarqueeSCNView()
        view.scene = scene
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = false
        view.showsStatistics = false
        view.preferredFramesPerSecond = 60
        view.rendersContinuously = false
        view.isJitteringEnabled = false
        view.onRightClick  = context.coordinator.handleRightClick
        view.onLeftClick   = context.coordinator.handleLeftClick
        view.onScroll      = context.coordinator.handleScroll
        view.onMouseInside = context.coordinator.handleMouseInside
        return view
    }

    func updateNSView(_ view: MarqueeSCNView, context: Context) {
        view.onRightClick  = context.coordinator.handleRightClick
        view.onLeftClick   = context.coordinator.handleLeftClick
        view.onScroll      = context.coordinator.handleScroll
        view.onMouseInside = context.coordinator.handleMouseInside
        // rendersContinuously=false already means SceneKit only redraws on real scene changes,
        // not a fixed 60fps loop — but SCNFloor's live reflection pass and per-frame hit-test/
        // tracking-area bookkeeping still cost real CPU on every one of those redraws, and nothing
        // stops them from happening while the window is miniaturized or fully covered (AppKit
        // doesn't know SceneKit's internal render loop exists). isPlaying is SceneKit's own kill
        // switch for its render loop — false means genuinely zero rendering work, not just a
        // lower rate, until the window is visible again.
        view.isPlaying = isVisible
    }

    // Left to the default, SCNView reports an oversized fitting size during SwiftUI's insertion/
    // measurement passes, which can inflate an enclosing HStack/ZStack past the fixed window width.
    // Always defer to whatever SwiftUI actually proposes.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarqueeSCNView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: SceneKitView
        init(_ parent: SceneKitView) { self.parent = parent }

        func handleRightClick(node: SCNNode, event: NSEvent) { parent.onRightClick?(node, event) }
        func handleLeftClick(node: SCNNode) { parent.onLeftClick?(node) }
        func handleScroll(_ delta: Int) { parent.onScroll?(delta) }
        func handleMouseInside(_ inside: Bool) { parent.onMouseInside?(inside) }
    }
}

// Custom SCNView: right-click context menu, left-click to open detail,
// trackpad horizontal swipe + mouse scroll wheel to navigate carousel.
final class MarqueeSCNView: SCNView {
    var onRightClick: ((SCNNode, NSEvent) -> Void)?
    var onLeftClick: ((SCNNode) -> Void)?
    var onScroll: ((Int) -> Void)?
    var onMouseInside: ((Bool) -> Void)?

    private var scrollAccumulator: CGFloat = 0
    private let trackpadThreshold: CGFloat = 80   // 80 pt per step on trackpad

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { onMouseInside?(true) }
    override func mouseExited(with event: NSEvent)  { onMouseInside?(false) }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hits = hitTest(point, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue])
        if let node = hits.first?.node {
            onRightClick?(node, event)
        }
    }

    override func mouseUp(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hits = hitTest(point, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue])
        if let node = hits.first?.node {
            onLeftClick?(node)
        }
    }

    override func scrollWheel(with event: NSEvent) {
        if event.phase == .began { scrollAccumulator = 0 }

        if event.hasPreciseScrollingDeltas {
            // Trackpad: horizontal swipe navigates carousel.
            let dx = event.scrollingDeltaX
            let dy = event.scrollingDeltaY
            guard abs(dx) > max(abs(dy), 1.0) else { return }
            scrollAccumulator += dx
            while scrollAccumulator >=  trackpadThreshold { scrollAccumulator -= trackpadThreshold; onScroll?(-1) }
            while scrollAccumulator <= -trackpadThreshold { scrollAccumulator += trackpadThreshold; onScroll?(+1) }
        } else {
            // Physical mouse scroll wheel: vertical delta maps to left/right nav.
            // dy > 0 = wheel up = previous game; dy < 0 = wheel down = next game.
            let dy = event.scrollingDeltaY
            guard abs(dy) >= 1.0 else { return }
            onScroll?(dy > 0 ? -1 : +1)
        }

        if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
            scrollAccumulator = 0
        }
    }
}
