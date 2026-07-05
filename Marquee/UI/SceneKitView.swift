import SwiftUI
import SceneKit
import AppKit

struct SceneKitView: NSViewRepresentable {
    let scene: SCNScene
    var onRightClick: ((SCNNode, NSEvent) -> Void)?
    var onLeftClick: ((SCNNode) -> Void)?
    var onScroll: ((Int) -> Void)?
    var onMouseInside: ((Bool) -> Void)?
    // Continuous hover hit-test — Rainbow Slide's "whatever box the cursor is over gets the
    // outline" needs a hit node on every mouse MOVE, not just clicks (nil = cursor over empty
    // space/floor). The carousel doesn't set this, so MarqueeSCNView skips the extra per-move
    // hit-testing entirely for it (see mouseMoved below).
    var onMouseMove: ((SCNNode?) -> Void)?
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
        view.onMouseMove   = context.coordinator.handleMouseMove
        return view
    }

    func updateNSView(_ view: MarqueeSCNView, context: Context) {
        view.onRightClick  = context.coordinator.handleRightClick
        view.onLeftClick   = context.coordinator.handleLeftClick
        view.onScroll      = context.coordinator.handleScroll
        view.onMouseInside = context.coordinator.handleMouseInside
        view.onMouseMove   = context.coordinator.handleMouseMove
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
        func handleMouseMove(_ node: SCNNode?) { parent.onMouseMove?(node) }
    }
}

// Custom SCNView: right-click context menu, left-click to open detail,
// trackpad horizontal swipe + mouse scroll wheel to navigate carousel.
final class MarqueeSCNView: SCNView {
    var onRightClick: ((SCNNode, NSEvent) -> Void)?
    var onLeftClick: ((SCNNode) -> Void)?
    var onScroll: ((Int) -> Void)?
    var onMouseInside: ((Bool) -> Void)?
    var onMouseMove: ((SCNNode?) -> Void)?

    private var scrollAccumulator: CGFloat = 0
    private let trackpadThreshold: CGFloat = 80   // 80 pt per step on trackpad

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        // .mouseMoved is unconditional (not gated on onMouseMove being set) since tracking-area
        // options can't be swapped per-frame — the mouseMoved override below is what actually
        // skips the hit-test when nobody's listening (the carousel never sets onMouseMove).
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) { onMouseInside?(true) }
    override func mouseExited(with event: NSEvent)  { onMouseInside?(false); onMouseMove?(nil) }

    override func mouseMoved(with event: NSEvent) {
        guard onMouseMove != nil else { return }
        let point = convert(event.locationInWindow, from: nil)
        let hits = hitTest(point, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue])
        onMouseMove?(hits.first?.node)
    }

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
            // Physical mouse scroll wheel: vertical delta maps to left/right nav, one step per
            // notch — no momentum/coast (removed per Jack's ask, decisions.md #101 reverted).
            // A full-magnitude notch (the normal case) still fires immediately, exactly once,
            // regardless of how large dy is — unchanged from before. Some mice (and a low
            // system "scroll speed" setting) emit FRACTIONAL deltas under 1.0 when the wheel is
            // turned slowly, which the old code silently dropped every single time with no
            // accumulation — "scrolling too slow does nothing at all." Only that sub-threshold
            // remainder gets accumulated (mirroring the trackpad accumulator above), so slow
            // notches still add up to a step instead of vanishing.
            let dy = event.scrollingDeltaY
            guard dy != 0 else { return }
            if abs(dy) >= 1.0 {
                onScroll?(dy > 0 ? -1 : +1)
            } else {
                scrollAccumulator += dy
                if scrollAccumulator >= 1.0 { scrollAccumulator -= 1.0; onScroll?(-1) }
                else if scrollAccumulator <= -1.0 { scrollAccumulator += 1.0; onScroll?(+1) }
            }
        }

        if event.momentumPhase == .ended || event.momentumPhase == .cancelled {
            scrollAccumulator = 0
        }
    }
}
