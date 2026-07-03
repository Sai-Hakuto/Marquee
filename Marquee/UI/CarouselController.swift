import SceneKit
import AppKit

// On macOS, SCNVector3 components are CGFloat (not Float like on iOS).
// All arc math uses CGFloat throughout.

@MainActor
final class CarouselController {
    let scene = SCNScene()
    private var gameNodes: [GameBoxNode] = []
    private(set) var selectedIndex: Int = 0

    private let arcRadius:      CGFloat = 30.0     // flat arc — boxes spread in x with negligible z-depth
    private let angleStep:      CGFloat = 0.075    // 25% wider spread: offset±2 half off screen, ±3 barely visible
    private let visibleRadius   = 5               // ±5 = 11 boxes; offset±2+ clip at window edges
    private let selectedZBoost: CGFloat = 0.5     // subtle z-pop ensures center renders over side boxes

    private let springDamping:  CGFloat = 11.0
    private let springOmega:    CGFloat = 22.0
    private let springDuration: TimeInterval = 0.65

    init() { setupScene() }

    // MARK: - Scene Setup

    private func setupScene() {
        scene.background.contents = NSColor.clear  // SwiftUI layer owns the background color
        addCamera()
        addLighting()
        addFloor()
    }

    func updateBackground(_ color: NSColor) {
        // Background is handled by the SwiftUI layer; SceneKit stays transparent.
        scene.background.contents = NSColor.clear
    }

    private func addCamera() {
        let camera = SCNCamera()
        camera.fieldOfView = 92        // wide FOV — more boxes visible before clipping at edges
        camera.zNear = 0.1
        camera.zFar = 80
        // No global HDR bloom — bleeds onto adjacent boxes and washes out cover art.
        // Selected box gets per-box emission glow instead (see GameBoxNode.setSelected).
        camera.wantsHDR = false

        let node = SCNNode()
        node.name = "mainCamera"
        node.camera = camera
        node.position = SCNVector3(0, 0, 5.0)   // closer = 2× apparent size; centered vertically
        node.eulerAngles = SCNVector3(0, 0, 0)  // no tilt — head-on view
        scene.rootNode.addChildNode(node)
    }

    private func addLighting() {
        func makeLight(type: SCNLight.LightType, color: NSColor, intensity: CGFloat,
                       euler: SCNVector3) -> SCNNode {
            let light = SCNLight()
            light.type = type
            light.color = color
            light.intensity = intensity
            light.castsShadow = false
            let node = SCNNode()
            node.light = light
            node.eulerAngles = euler
            return node
        }

        scene.rootNode.addChildNode(makeLight(
            type: .directional,
            color: NSColor(red: 1.0, green: 0.95, blue: 0.85, alpha: 1.0),
            intensity: 900,
            euler: SCNVector3(-CGFloat.pi / 5, CGFloat.pi / 7, 0)
        ))
        scene.rootNode.addChildNode(makeLight(
            type: .directional,
            color: NSColor(red: 0.5, green: 0.6, blue: 1.0, alpha: 1.0),
            intensity: 300,
            euler: SCNVector3(0, -CGFloat.pi / 3, 0)
        ))
        scene.rootNode.addChildNode(makeLight(
            type: .ambient,
            color: NSColor(white: 0.18, alpha: 1.0),
            intensity: 1000,
            euler: .init(0, 0, 0)
        ))
    }

    private func addFloor() {
        let floor = SCNFloor()
        floor.reflectivity = 0.25
        floor.reflectionFalloffEnd = 4.5

        let mat = SCNMaterial()
        mat.diffuse.contents = NSColor.clear
        floor.materials = [mat]

        let node = SCNNode()
        node.name = "floor"
        node.geometry = floor
        let yPos = -(CGFloat(GameBoxNode.boxHeight) / 2) - 0.02
        node.position = SCNVector3(0, yPos, 0)
        scene.rootNode.addChildNode(node)
    }

    // MARK: - Game Layout

    func loadGames(_ games: [Game], animated: Bool = false, selectedIndex initialIndex: Int = 0) {
        selectedIndex = games.isEmpty ? 0 : max(0, min(initialIndex, games.count - 1))
        gameNodes.forEach { $0.removeFromParentNode() }
        gameNodes = []

        for game in games {
            let node = GameBoxNode(game: game)
            scene.rootNode.addChildNode(node)
            gameNodes.append(node)
        }

        for (i, node) in gameNodes.enumerated() {
            let (pos, rotY, scale) = arcTransform(index: i, selected: selectedIndex)
            node.position = pos
            node.eulerAngles.y = rotY
            node.scale = SCNVector3(scale, scale, scale)
            node.opacity = isVisible(index: i) ? 1.0 : 0.0
            node.setSelected(i == selectedIndex)
        }
    }

    func animateEntrance() {
        for (i, node) in gameNodes.enumerated() {
            guard isVisible(index: i) else { node.opacity = 0; continue }

            let (finalPos, finalRotY, finalScale) = arcTransform(index: i, selected: selectedIndex)

            node.position = SCNVector3(finalPos.x, 14, finalPos.z)
            node.eulerAngles.y = finalRotY
            node.scale = SCNVector3(finalScale, finalScale, finalScale)
            node.opacity = 0

            let distance = abs(i - selectedIndex)
            let delay = Double(distance) * 0.055

            node.runAction(SCNAction.sequence([
                SCNAction.wait(duration: delay),
                SCNAction.group([
                    SCNAction.fadeIn(duration: 0.25),
                    springDropAction(from: node.position, to: finalPos)
                ])
            ]))
        }
    }

    private func springDropAction(from start: SCNVector3, to end: SCNVector3) -> SCNAction {
        let d  = springDamping
        let w  = springOmega
        let dur = springDuration
        return SCNAction.customAction(duration: dur) { node, elapsed in
            let t: CGFloat = elapsed / CGFloat(dur)
            let spring     = 1.0 - exp(-d * t) * cos(w * t)
            let px = start.x + (end.x - start.x) * spring
            let py = start.y + (end.y - start.y) * spring
            let pz = start.z + (end.z - start.z) * spring
            node.position = SCNVector3(px, py, pz)
        }
    }

    // MARK: - Navigation

    func navigate(to newIndex: Int) {
        guard !gameNodes.isEmpty, newIndex != selectedIndex else { return }
        let newIndex = ((newIndex % gameNodes.count) + gameNodes.count) % gameNodes.count
        gameNodes[selectedIndex].setSelected(false)
        selectedIndex = newIndex
        gameNodes[selectedIndex].setSelected(true)

        for (i, node) in gameNodes.enumerated() {
            let visible = isVisible(index: i)
            if !visible { node.opacity = 0; continue }
            if node.opacity == 0 { node.opacity = 1 }

            let (targetPos, targetRotY, targetScale) = arcTransform(index: i, selected: newIndex)
            springAnimate(node: node, to: targetPos, rotY: targetRotY, scale: targetScale)
        }
    }

    private func springAnimate(node: SCNNode, to pos: SCNVector3, rotY: CGFloat, scale: CGFloat) {
        let sp  = node.presentation.position
        let sry = node.presentation.eulerAngles.y
        let ssc = node.presentation.scale.x
        let d   = springDamping
        let w   = springOmega
        let dur = springDuration

        node.removeAllActions()
        node.runAction(SCNAction.customAction(duration: dur) { node, elapsed in
            let t: CGFloat  = elapsed / CGFloat(dur)
            let s           = 1.0 - exp(-d * t) * cos(w * t)
            let px = sp.x  + (pos.x  - sp.x)  * s
            let py = sp.y  + (pos.y  - sp.y)  * s
            let pz = sp.z  + (pos.z  - sp.z)  * s
            node.position      = SCNVector3(px, py, pz)
            node.eulerAngles.y = sry + (rotY  - sry) * s
            let sc             = ssc + (scale - ssc) * s
            node.scale         = SCNVector3(sc, sc, sc)
        })
    }

    // MARK: - Arc Math

    private func wrappedOffset(for index: Int, selected: Int) -> Int {
        let count = gameNodes.count
        guard count > 1 else { return 0 }
        var offset = index - selected
        if offset >  count / 2 { offset -= count }
        if offset < -(count / 2) { offset += count }
        return offset
    }

    private func arcTransform(index: Int, selected: Int) -> (position: SCNVector3, rotationY: CGFloat, scale: CGFloat) {
        let offset: CGFloat = CGFloat(wrappedOffset(for: index, selected: selected))
        let angle           = offset * angleStep
        let x               = arcRadius * sin(angle)
        let z               = -arcRadius * (1.0 - cos(angle))
        let zBoost: CGFloat = (index == selected) ? selectedZBoost : 0
        let scale           = max(0.75, 1.50 - abs(offset) * 0.03)  // center 1.50, 3% falloff per step
        return (SCNVector3(x, 0, z + zBoost), 0, scale)  // rotY=0: all boxes face camera head-on
    }

    private func isVisible(index: Int) -> Bool {
        abs(wrappedOffset(for: index, selected: selectedIndex)) <= visibleRadius
    }

    // MARK: - Art

    func applyArt(image: NSImage, toGameAt index: Int) {
        guard index < gameNodes.count else { return }
        gameNodes[index].applyArt(image)
    }

    // Show/hide the favorite star badge on each box based on the given id set.
    func applyFavorites(_ ids: Set<UUID>) {
        for node in gameNodes { node.setFavorite(ids.contains(node.game.id)) }
    }

    // Grey out boxes the live search doesn't match — carousel's counterpart to Grid/Wall/List's
    // searchGreyscale. Takes a predicate rather than a precomputed id set since the caller
    // (ContentView) already owns AppState.matchScore, the single source of truth for "matches".
    func applySearchDimming(_ shouldDim: (Game) -> Bool) {
        for node in gameNodes { node.setSearchDimmed(shouldDim(node.game)) }
    }

    // Show or hide the selection ring on the currently-selected box.
    // Call when keyboard/controller focus enters or leaves the carousel zone,
    // and when the mouse enters or exits the SceneKit view.
    func setCarouselFocused(_ focused: Bool) {
        guard !gameNodes.isEmpty, selectedIndex < gameNodes.count else { return }
        gameNodes[selectedIndex].setSelected(focused)
    }

    // Maps a hit-test result node (the inner geometry node SceneKit returns) up
    // its parent chain to the owning GameBoxNode, then to its index. Returns nil
    // if the click landed on the floor or empty space.
    func gameIndex(forHitNode node: SCNNode) -> Int? {
        var current: SCNNode? = node
        while let n = current {
            if let box = n as? GameBoxNode {
                return gameNodes.firstIndex(where: { $0 === box })
            }
            current = n.parent
        }
        return nil
    }
}
