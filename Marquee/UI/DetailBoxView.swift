import SwiftUI
import SceneKit
import AppKit

// The right-hand "product shot" box on the Detail page. It owns a tiny SceneKit
// scene with a single thick game-case node that spins in from the carousel's
// head-on orientation, settling into an angled resting pose that shows the spine.
@MainActor
final class DetailBoxController {
    let scene = SCNScene()
    private var boxNode: GameBoxNode?

    // Resting pose: tilted so the left spine (with the title) faces the viewer.
    private let restingY: CGFloat = 0.46
    private let restingX: CGFloat = -0.04
    // Final resting scale — 1.0 for the modal Detail page's roomy frame; List view's inline
    // panel is tighter, so it doubles the box (2.0) to read at a glance. Deliberately allowed
    // to overflow the SCNView's frame at 2×; ListDetailPanel masks the bottom edge with a
    // halftone dissolve instead of a hard clip so it never collides with the title/actions below.
    private let restScale: CGFloat

    init(sizeMultiplier: CGFloat = 1.0) {
        restScale = sizeMultiplier
        setupScene()
    }

    // Camera FOV/distance, factored out so load() can compute how far a scaled-up box needs to
    // shift down to keep its top edge inside the frustum (see load()).
    private static let cameraFOVDegrees: CGFloat = 28   // long lens → minimal perspective distortion
    private static let cameraDistance: CGFloat = 13.5

    private func setupScene() {
        scene.background.contents = NSColor.clear

        let camera = SCNCamera()
        camera.fieldOfView = Self.cameraFOVDegrees
        camera.zNear = 0.1
        camera.zFar = 100
        camera.wantsHDR = false
        let camNode = SCNNode()
        camNode.camera = camera
        camNode.position = SCNVector3(0, 0, Self.cameraDistance)
        scene.rootNode.addChildNode(camNode)

        func light(_ type: SCNLight.LightType, _ color: NSColor, _ intensity: CGFloat, _ euler: SCNVector3) {
            let l = SCNLight()
            l.type = type; l.color = color; l.intensity = intensity; l.castsShadow = false
            let n = SCNNode(); n.light = l; n.eulerAngles = euler
            scene.rootNode.addChildNode(n)
        }
        light(.directional, NSColor(red: 1.0, green: 0.96, blue: 0.9, alpha: 1), 1000,
              SCNVector3(-CGFloat.pi/6, CGFloat.pi/5, 0))
        light(.directional, NSColor(red: 0.55, green: 0.65, blue: 1.0, alpha: 1), 420,
              SCNVector3(0, -CGFloat.pi/3, 0))
        light(.ambient, NSColor(white: 0.34, alpha: 1), 1000, .init(0, 0, 0))
    }

    func load(game: Game, art: NSImage?) {
        boxNode?.removeFromParentNode()
        let node = GameBoxNode(game: game, depth: 0.62, spineTitle: true)
        if let art { node.applyArt(art) }
        // At larger scales (List's inline panel) the box's world height can exceed what the
        // fixed camera frustum shows at this distance, overflowing symmetrically above AND below
        // center — the top was a hard, ugly clip (ListDetailPanel only fades the BOTTOM edge via
        // HalftoneSeam). Shifting the box down just enough keeps its top edge inside the frustum,
        // pushing all the overflow — plus a margin for the idle float in playEntrance() and real
        // breathing room below the nav bar (v0.16.0: 0.16 → 0.5 — the tighter margin still read
        // as flush/cropped against the top, not just "tight") — into that already-masked bottom
        // edge instead. No-op at scale 1.0 (the modal Detail page's box already fits with room to
        // spare).
        let frustumHalfHeight = Self.cameraDistance * tan(Self.cameraFOVDegrees * .pi / 180 / 2)
        let boxHalfHeight = GameBoxNode.boxHeight / 2 * restScale
        let overflow = boxHalfHeight - frustumHalfHeight
        let yOffset: CGFloat = overflow > 0 ? -(overflow + 0.5) : 0
        node.position = SCNVector3(0, yOffset, 0)
        node.eulerAngles = SCNVector3(0, 0, 0)   // start head-on, like the carousel center
        scene.rootNode.addChildNode(node)
        boxNode = node
    }

    // Spin once and settle into the resting pose, then drift gently forever.
    func playEntrance() {
        guard let node = boxNode else { return }
        node.removeAllActions()
        node.eulerAngles = SCNVector3(0, 0, 0)
        let startScale = 0.82 * restScale
        node.scale = SCNVector3(startScale, startScale, startScale)
        node.opacity = 0

        let spin = SCNAction.rotateBy(x: restingX, y: .pi * 2 + restingY, z: 0, duration: 1.1)
        spin.timingMode = .easeOut
        let grow = SCNAction.scale(to: restScale, duration: 1.1)
        grow.timingMode = .easeOut
        let fade = SCNAction.fadeIn(duration: 0.4)

        let entrance = SCNAction.group([spin, grow, fade])
        node.runAction(entrance) { [weak node] in
            // Gentle idle float once settled.
            guard let node else { return }
            let up = SCNAction.moveBy(x: 0, y: 0.08, z: 0, duration: 2.2)
            up.timingMode = .easeInEaseOut
            let down = up.reversed()
            node.runAction(.repeatForever(.sequence([up, down])))
        }
    }
}

struct DetailBoxView: NSViewRepresentable {
    let controller: DetailBoxController

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = controller.scene
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = false
        view.rendersContinuously = true   // keep the spin + idle float smooth
        view.preferredFramesPerSecond = 60
        view.isJitteringEnabled = false
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {}

    // Left to the default, SCNView reports its own fitting size rather than deferring to
    // whatever SwiftUI actually proposes — always echo the proposal back instead.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SCNView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}
