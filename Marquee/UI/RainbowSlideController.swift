import SceneKit
import AppKit

// Rainbow Slide (v0.31.0, geometry rebuilt v0.32.0) — a second 3D view mode built on a genuine
// ferris-wheel conveyor, per Jack's Wii disc-channel reference image: every box rides the rim of
// one large circle lying in the SCREEN plane, hub far below the viewport. Boxes near the apex sit
// highest; each step outward drops a box down the rim and ROLLS it (eulerAngles.z, tangent to the
// circle) so the whole row reads as a single curved, rotating wheel — neighbors overlap slightly
// like fanned cards, all faces pointed straight at the camera (no yaw at all; the v0.31.0 first
// pass was carousel math plus per-slot Y-tilt, which read as a Carousel copy, not a wheel — Jack
// rejected it explicitly). Navigation spins the wheel: every box moves along the rim and its roll
// follows its new tangent, so a step reads as rotation, not sideways translation.
//
// Interaction model (see ui-views.md for the full writeup):
//  - Mouse: the selection ring follows whatever box the cursor is over (ContentView hit-tests on
//    every mouseMoved and calls setHovered), completely independent of the wheel's own position —
//    unlike the carousel, hovering never re-centers anything.
//  - Keyboard/controller: `highlightOffset` is a cursor that slides across the already-visible
//    slots first; only once it's pinned at either edge does further input in the same direction
//    spin the WHEEL (bringing new boxes into view) while the ring stays pinned at that edge slot.
//    Every spin moves exactly one slot (v0.34.0) — a sustained hold repeats faster (more spins per
//    second), never bigger (more games per spin), so fast navigation still visits every game in
//    sort order instead of skipping an unpredictable number of them.
@MainActor
final class RainbowSlideController {
    let scene = SCNScene()
    private var gameNodes: [GameBoxNode] = []

    // The logical game index sitting at screen slot 0 (dead center) — an Int, not a continuous
    // float. Exactly like CarouselController.selectedIndex: the SPRING (springAnimate) is what
    // makes the wheel glide smoothly between integer positions, so the model only ever needs to
    // track "where did it just land."
    private(set) var wheelCenter: Int = 0
    // Which screen slot (-visibleRadius...+visibleRadius, 0 = dead center) shows the
    // keyboard/controller selection ring. Independent of wheelCenter.
    private(set) var highlightOffset: Int = 0
    // Mouse hover overrides the ring entirely, wherever it lands — set by ContentView's
    // mouseMoved hit-test, cleared (nil) when the cursor leaves the scene or empty space.
    private var hoveredGameIndex: Int? = nil
    // Whether the keyboard/controller ring should paint at all — hidden while focus is
    // elsewhere (bottomControls, topBar, ...), mirroring CarouselController.setCarouselFocused.
    // Hover is a separate, always-live signal and ignores this flag entirely.
    private var keyboardRingActive: Bool = true

    // The wheel: one circle in the screen (XY) plane, hub at (0, wheelApexY - wheelRadius).
    // Radius × angleStep sets the arc-length between neighbors: 15 × 0.165 ≈ 2.47 world units
    // against a 2.8-wide box ≈ 12% overlap — the fanned-cards look of the reference image.
    private let wheelRadius:    CGFloat = 15.0
    private let angleStep:      CGFloat = 0.165
    // y of the apex (center slot's box center). v0.33.0: nudged from -0.3 to -0.16 so the apex
    // box's own on-screen center lands vertically between the search bar above and the
    // title/info bar below (measured live via screenshot — see decisions.md #111), now that
    // visibleRadius/FOV below changed what "clears the search bar" actually requires.
    private let wheelApexY:     CGFloat = -0.16
    // ±3 = 7 boxes (v0.33.0, was ±2/5 — Jack's ask for 7 visible again after v0.32.1's zoom).
    // Paired with the FOV widen below so the extra two boxes have room to read as "partially
    // off-screen," not fully clipped.
    let visibleRadius = 3
    // Gentle per-slot recession so nearer-to-center boxes always win the overlap paint order —
    // the reference fans left side under, right side under, center on top.
    private let depthStep:      CGFloat = 0.18
    // The ringed box (hover or keyboard) pops toward the camera and grows, like the Wii cursor
    // enlarging whatever cover it points at — tint alone read flat at uniform box scale.
    private let ringPopScale:   CGFloat = 1.12
    private let ringPopZ:       CGFloat = 0.60

    // v0.33.0 (decisions.md #111): damping raised 11 → 19, much closer to critical damping
    // against omega 22 (critical = damping ≈ omega). The old ratio was heavily underdamped —
    // `1 - exp(-d·t)·cos(w·t)` visibly overshoots and oscillates before settling, which reads as
    // "a lot in motion" once several boxes are re-springing at once (every wheel spin moves every
    // visible box simultaneously). Higher damping keeps the same spring shape (still eases, still
    // has a little life to it) but kills most of the bounce/overshoot. Carousel's own spring is
    // untouched — this constant is local to Rainbow Slide, and Jack's complaint was specific to
    // this view.
    private let springDamping:  CGFloat = 19.0
    private let springOmega:    CGFloat = 22.0
    private let springDuration: TimeInterval = 0.55

    init() { setupScene() }

    // MARK: - Scene Setup

    private func setupScene() {
        scene.background.contents = NSColor.clear
        addCamera()
        addLighting()
        // No SCNFloor here (unlike the Carousel): the wheel's outer boxes drop several units
        // below the apex slot, so any floor plane either intersects them or has to sit so low
        // its reflection reads as noise. The reference image has no floor either — covers hang
        // in space on the wheel.
    }

    func updateBackground(_ color: NSColor) {
        scene.background.contents = NSColor.clear
    }

    private func addCamera() {
        let camera = SCNCamera()
        // Camera position (distance) is unchanged from v0.32.0's fix for the v0.31.0
        // close-camera distortion — narrowing the FOV instead ("zooming" the lens rather than
        // walking the camera in) is the one of the two that DOESN'T reintroduce that
        // distortion; a telephoto narrow-FOV shot flattens perspective on off-axis boxes, a
        // wide-FOV close shot exaggerates it. v0.32.1 (Jack's ask: boxes read "twice as large"):
        // 68° → 40° roughly doubles the apex box's screen-space size at the same z 9 distance.
        // v0.33.0: widened slightly to 46° so the now-±3 wheel (7 boxes, was ±2/5) has room for
        // the two extra boxes to read as "partially off-screen at the edge" rather than fully
        // clipped — still a noticeably tighter frame than v0.32.0's original 68°, per Jack's ask
        // to zoom out "just a little," not revert the zoom-in.
        camera.fieldOfView = 46
        camera.zNear = 0.1
        camera.zFar = 80
        camera.wantsHDR = false
        let node = SCNNode()
        node.name = "mainCamera"
        node.camera = camera
        node.position = SCNVector3(0, 0, 9.0)
        node.eulerAngles = SCNVector3(0, 0, 0)
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

    // MARK: - Layout

    func loadGames(_ games: [Game], selectedIndex: Int = 0) {
        wheelCenter = games.isEmpty ? 0 : max(0, min(selectedIndex, games.count - 1))
        highlightOffset = 0
        hoveredGameIndex = nil
        lastPoppedIndex = nil
        gameNodes.forEach { $0.removeFromParentNode() }
        gameNodes = games.map { GameBoxNode(game: $0, roundedCorners: true) }
        gameNodes.forEach { scene.rootNode.addChildNode($0) }

        for (i, node) in gameNodes.enumerated() {
            let (pos, rotZ, scale) = wheelTransform(index: i)
            node.position = pos
            node.eulerAngles.z = rotZ
            node.scale = SCNVector3(scale, scale, scale)
            node.opacity = isVisible(index: i) ? 1.0 : 0.0
        }
        refreshHighlightRings()
    }

    func animateEntrance() {
        for (i, node) in gameNodes.enumerated() {
            guard isVisible(index: i) else { node.opacity = 0; continue }

            let (finalPos, finalRotZ, finalScale) = wheelTransform(index: i)
            node.position = SCNVector3(finalPos.x, finalPos.y + 12, finalPos.z)
            node.eulerAngles.z = finalRotZ
            node.scale = SCNVector3(finalScale, finalScale, finalScale)
            node.opacity = 0

            let distance = abs(wrappedOffset(for: i))
            let delay = Double(distance) * 0.05

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
        let d = springDamping, w = springOmega, dur = springDuration
        return SCNAction.customAction(duration: dur) { node, elapsed in
            let t: CGFloat = elapsed / CGFloat(dur)
            let s = 1.0 - exp(-d * t) * cos(w * t)
            node.position = SCNVector3(
                start.x + (end.x - start.x) * s,
                start.y + (end.y - start.y) * s,
                start.z + (end.z - start.z) * s
            )
        }
    }

    // MARK: - Navigation

    // External/absolute navigation — search auto-navigation, favorites reorder, Detail page
    // prev/next, etc. all just say "this is the current game now" the same way they already
    // tell the carousel via `carousel.navigate(to:)`. Re-centers the wheel on that index with
    // the ring back at dead center, same as loading fresh.
    func navigate(to newIndex: Int) {
        guard !gameNodes.isEmpty else { return }
        let newIndex = ((newIndex % gameNodes.count) + gameNodes.count) % gameNodes.count
        guard newIndex != wheelCenter || highlightOffset != 0 else { return }
        wheelCenter = newIndex
        highlightOffset = 0
        relayout(animated: true)
    }

    // Slides the highlight ring among already-visible slots; once it's pinned at either edge,
    // further presses in the same direction spin the wheel exactly ONE slot at a time — never
    // more, no matter how fast or how long the input keeps coming (v0.34.0: an earlier
    // accelerating multi-slot spin made rapid navigation skip a variable, unpredictable number of
    // games instead of walking the sort order one at a time — see ContentView.navigateRainbowSlide).
    // Returns whether this call actually spun the wheel (vs. just sliding the ring).
    @discardableResult
    func navigateHighlight(_ delta: Int) -> Bool {
        guard !gameNodes.isEmpty else { return false }
        let proposed = highlightOffset + delta
        if proposed >= -visibleRadius && proposed <= visibleRadius {
            highlightOffset = proposed
            refreshHighlightRings()
            return false
        }
        wheelCenter = wrap(wheelCenter + delta)
        highlightOffset = delta > 0 ? visibleRadius : -visibleRadius
        relayout(animated: true)
        return true
    }

    // The game index the ring currently sits on (hover takes priority over the
    // keyboard/controller highlight) — this is what ContentView mirrors into
    // `appState.selectedIndex` after every navigation/hover change.
    var ringedGameIndex: Int? {
        guard !gameNodes.isEmpty else { return nil }
        return hoveredGameIndex ?? wrap(wheelCenter + highlightOffset)
    }

    // Mouse hover — independent of the keyboard/controller highlight. `nil` clears it (cursor
    // left the scene, or landed on the floor/empty space).
    func setHovered(gameIndex: Int?) {
        guard hoveredGameIndex != gameIndex else { return }
        hoveredGameIndex = gameIndex
        refreshHighlightRings()
    }

    // Shows/hides the keyboard/controller ring specifically — call when focus enters/leaves the
    // carousel zone, mirroring CarouselController.setCarouselFocused. Hover ignores this
    // entirely (it's a separate, always-live signal from the mouse).
    func setFocused(_ focused: Bool) {
        keyboardRingActive = focused
        refreshHighlightRings()
    }

    private func relayout(animated: Bool) {
        for (i, node) in gameNodes.enumerated() {
            let visible = isVisible(index: i)
            if !visible { node.opacity = 0; continue }
            if node.opacity < 1 { node.opacity = 1 }   // also heals an interrupted entrance fade

            let (pos, rotZ, scale) = wheelTransform(index: i)
            if animated {
                springAnimate(node: node, to: pos, rotZ: rotZ, scale: scale)
            } else {
                node.position = pos
                node.eulerAngles.z = rotZ
                node.scale = SCNVector3(scale, scale, scale)
            }
        }
        refreshHighlightRings()
    }

    private func springAnimate(node: SCNNode, to pos: SCNVector3, rotZ: CGFloat, scale: CGFloat,
                               duration: TimeInterval? = nil) {
        let sp = node.presentation.position
        let srz = node.presentation.eulerAngles.z
        let ssc = node.presentation.scale.x
        let d = springDamping, w = springOmega, dur = duration ?? springDuration

        node.removeAllActions()
        // removeAllActions can kill the entrance's grouped fadeIn mid-flight (e.g. startup focus
        // landing on the search bar settles the ring pop during the reveal), freezing the box
        // semi-transparent forever. Anything we're spring-animating is by definition visible —
        // finish any interrupted fade ourselves.
        if node.opacity < 1 {
            node.runAction(SCNAction.fadeIn(duration: 0.15))
        }
        node.runAction(SCNAction.customAction(duration: dur) { node, elapsed in
            let t: CGFloat = elapsed / CGFloat(dur)
            let s = 1.0 - exp(-d * t) * cos(w * t)
            node.position = SCNVector3(
                sp.x + (pos.x - sp.x) * s,
                sp.y + (pos.y - sp.y) * s,
                sp.z + (pos.z - sp.z) * s
            )
            node.eulerAngles.z = srz + (rotZ - srz) * s
            let sc = ssc + (scale - ssc) * s
            node.scale = SCNVector3(sc, sc, sc)
        })
    }

    // The game index whose box should render ringed AND popped — wheelTransform consults this,
    // so pop state lives in the one transform function instead of a second code path.
    private var ringedForLayout: Int? {
        guard !gameNodes.isEmpty else { return nil }
        return hoveredGameIndex ?? (keyboardRingActive ? wrap(wheelCenter + highlightOffset) : nil)
    }
    // Last box given the ring pop, so a ring move can settle it back without relaying-out the
    // whole wheel (which would removeAllActions on boxes mid-spin for no reason).
    private var lastPoppedIndex: Int? = nil

    private func refreshHighlightRings() {
        guard !gameNodes.isEmpty else { return }
        let ringed = ringedForLayout
        for (i, node) in gameNodes.enumerated() {
            node.setHighlightTint(i == ringed)
        }
        // Pop the newly ringed box toward the camera / settle the previous one — a quicker
        // spring than the wheel's own so the pop tracks a moving cursor responsively.
        if ringed != lastPoppedIndex {
            let affected = [lastPoppedIndex, ringed].compactMap { $0 }
            lastPoppedIndex = ringed
            for i in affected where i < gameNodes.count && isVisible(index: i) {
                let (pos, rotZ, scale) = wheelTransform(index: i)
                springAnimate(node: gameNodes[i], to: pos, rotZ: rotZ, scale: scale, duration: 0.3)
            }
        }
    }

    // MARK: - Wheel Math

    private func wrap(_ i: Int) -> Int {
        guard !gameNodes.isEmpty else { return 0 }
        let count = gameNodes.count
        return ((i % count) + count) % count
    }

    private func wrappedOffset(for index: Int) -> Int {
        let count = gameNodes.count
        guard count > 1 else { return 0 }
        var offset = index - wheelCenter
        if offset > count / 2 { offset -= count }
        if offset < -(count / 2) { offset += count }
        return offset
    }

    // The whole view mode in one function: a box at wheel angle θ (offset slots from the apex)
    // sits on the rim at (R·sinθ, apexY − R·(1−cosθ)) and is rolled by −θ so its up-vector points
    // along the rim's radius — i.e. tangent to the wheel, leaning outward exactly like the fanned
    // covers in the reference image. Faces stay square to the camera (no yaw), size stays uniform
    // (the reference's covers are all the same size); only the ringed box pops/grows.
    private func wheelTransform(index: Int) -> (position: SCNVector3, rotationZ: CGFloat, scale: CGFloat) {
        let offset: CGFloat = CGFloat(wrappedOffset(for: index))
        let theta           = offset * angleStep
        let x               = wheelRadius * sin(theta)
        let y               = wheelApexY - wheelRadius * (1.0 - cos(theta))
        var z               = -abs(offset) * depthStep
        var scale: CGFloat  = 1.0
        if index == ringedForLayout {
            z     += ringPopZ
            scale  = ringPopScale
        }
        return (SCNVector3(x, y, z), -theta, scale)
    }

    private func isVisible(index: Int) -> Bool {
        abs(wrappedOffset(for: index)) <= visibleRadius
    }

    // MARK: - Art

    func applyArt(image: NSImage, toGameAt index: Int) {
        guard index < gameNodes.count else { return }
        gameNodes[index].applyArt(image)
    }

    func applyFavorites(_ ids: Set<UUID>) {
        for node in gameNodes { node.setFavorite(ids.contains(node.game.id)) }
    }

    func applySearchDimming(_ shouldDim: (Game) -> Bool) {
        for node in gameNodes { node.setSearchDimmed(shouldDim(node.game)) }
    }

    // Maps a hit-test result node (the inner geometry node SceneKit returns) up its parent chain
    // to the owning GameBoxNode, then to its index. Returns nil if the hit landed on the floor,
    // empty space, or nothing at all.
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
