import SceneKit
import AppKit
import CoreImage

// SCNBox face order: front(+Z), right(+X), back(-Z), left(-X), top(+Y), bottom(-Y)
// Camera sits at +Z, so materials[0] (front face) is what the camera sees.
final class GameBoxNode: SCNNode {
    let game: Game
    private let boxNode = SCNNode()
    private let depth: CGFloat
    private let spineTitle: Bool
    // Rounded-corner fill for the front face art (set from spineColor in setupBox before the
    // front material is built) — reused by applyArt() so real cover art gets the same treatment.
    private var cornerFillColor: NSColor = .black

    // 2:3 cover art proportions (matches 600×900 Steam/SteamGridDB portrait art)
    static let boxWidth:  CGFloat = 2.8    // 2:3 ratio with height — matches 600×900 cover art
    static let boxHeight: CGFloat = 4.2
    static let boxDepth:  CGFloat = 0.14

    // `depth` thickens the case for the Detail page (a chunky game-case look with a
    // readable spine); `spineTitle` draws the title vertically on the left/right faces.
    init(game: Game, depth: CGFloat = GameBoxNode.boxDepth, spineTitle: Bool = false) {
        self.game = game
        self.depth = depth
        self.spineTitle = spineTitle
        super.init()
        setupBox()
    }

    required init?(coder: NSCoder) { nil }

    private func setupBox() {
        let box = SCNBox(
            width: GameBoxNode.boxWidth,
            height: GameBoxNode.boxHeight,
            length: depth,
            chamferRadius: 0.006
        )

        let (r, g, b) = game.sourceBadgeColor
        let baseColor = NSColor(red: r * 0.5, green: g * 0.5, blue: b * 0.5, alpha: 1.0)
        let spineColor = baseColor.blended(withFraction: 0.3, of: .black) ?? .darkGray
        cornerFillColor = spineColor

        let frontMaterial = makeFrontMaterial(baseColor: baseColor)
        let spineMaterial = spineTitle
            ? makeSpineTitleMaterial(spineColor: spineColor)
            : makeSpineMaterial(spineColor: spineColor)
        let edgeMaterial = makeSpineMaterial(spineColor: spineColor)

        // front, right, back, left, top, bottom
        box.materials = [frontMaterial, edgeMaterial, edgeMaterial, spineMaterial, edgeMaterial, edgeMaterial]

        boxNode.geometry = box
        boxNode.castsShadow = true
        addChildNode(boxNode)
    }

    private func makeSpineTitleMaterial(spineColor: NSColor) -> SCNMaterial {
        let mat = SCNMaterial()
        mat.diffuse.contents = spineImage(color: spineColor)
        mat.specular.contents = NSColor(white: 0.12, alpha: 1.0)
        mat.shininess = 0.1
        mat.lightingModel = .phong
        return mat
    }

    // Vertical-title texture for the case spine (left face). Tall narrow image with the
    // title rotated 90° so it reads top-to-bottom, like a physical game-case spine.
    private func spineImage(color: NSColor) -> NSImage {
        let size = NSSize(width: 110, height: 660)
        let image = NSImage(size: size)
        image.lockFocus()

        let gradient = NSGradient(
            colors: [color.blended(withFraction: 0.2, of: .white) ?? color,
                     color.blended(withFraction: 0.55, of: .black) ?? color],
            atLocations: [0.0, 1.0], colorSpace: .sRGB
        )
        gradient?.draw(in: NSRect(origin: .zero, size: size), angle: 0)

        let ctx = NSGraphicsContext.current
        ctx?.saveGraphicsState()
        let transform = NSAffineTransform()
        // Place origin at bottom-center, rotate so the title reads top-to-bottom
        // along the spine (matching a physical game-case spine).
        transform.translateX(by: size.width / 2, yBy: 24)
        transform.rotate(byDegrees: 90)
        transform.concat()

        let para = NSMutableParagraphStyle()
        para.alignment = .left
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 34, weight: .heavy),
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
            .paragraphStyle: para
        ]
        let str = game.title as NSString
        str.draw(in: NSRect(x: 0, y: -size.width / 2, width: size.height - 48, height: size.width),
                 withAttributes: attrs)

        ctx?.restoreGraphicsState()
        image.unlockFocus()
        return image
    }

    private func makeFrontMaterial(baseColor: NSColor) -> SCNMaterial {
        let mat = SCNMaterial()
        mat.diffuse.contents = GameBoxNode.roundedCorners(placeholderImage(color: baseColor), fill: cornerFillColor)
        mat.specular.contents = NSColor(white: 0.3, alpha: 1.0)
        mat.shininess = 0.25
        mat.lightingModel = .phong
        return mat
    }

    private func makeSpineMaterial(spineColor: NSColor) -> SCNMaterial {
        let mat = SCNMaterial()
        mat.diffuse.contents = spineColor
        mat.specular.contents = NSColor(white: 0.1, alpha: 1.0)
        mat.shininess = 0.1
        mat.lightingModel = .phong
        return mat
    }

    private var starNode: SCNNode?
    private var selectionRingNode: SCNNode?

    // Favorite badge — a small gold star on a dark disc, pinned to the top-right of the
    // box front. Built lazily, then just toggled. As a child of the box it inherits the
    // box's position/scale/rotation automatically.
    func setFavorite(_ favorite: Bool) {
        if favorite {
            if starNode == nil {
                let plane = SCNPlane(width: 0.66, height: 0.66)
                let mat = SCNMaterial()
                mat.diffuse.contents = GameBoxNode.starBadgeImage()
                mat.lightingModel = .constant       // full-bright, readable on any cover
                mat.transparencyMode = .aOne        // use the PNG alpha channel
                mat.isDoubleSided = false
                plane.materials = [mat]
                let n = SCNNode(geometry: plane)
                n.position = SCNVector3(GameBoxNode.boxWidth / 2 - 0.42,
                                        GameBoxNode.boxHeight / 2 - 0.42,
                                        depth / 2 + 0.03)
                addChildNode(n)
                starNode = n
            }
            starNode?.isHidden = false
        } else {
            starNode?.isHidden = true
        }
    }

    private static func starBadgeImage() -> NSImage {
        let dim: CGFloat = 256
        let img = NSImage(size: NSSize(width: dim, height: dim))
        img.lockFocus()

        // Dark translucent disc backing
        let disc = NSBezierPath(ovalIn: NSRect(x: 14, y: 14, width: dim - 28, height: dim - 28))
        NSColor(white: 0.0, alpha: 0.46).setFill()
        disc.fill()
        NSColor(white: 1.0, alpha: 0.10).setStroke()
        disc.lineWidth = 3
        disc.stroke()

        // Gold star (SF Symbol, tinted in a separate image so only the star is gold)
        let cfg = NSImage.SymbolConfiguration(pointSize: 138, weight: .bold)
        if let sym = NSImage(systemSymbolName: "star.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(cfg) {
            let s = sym.size
            let star = NSImage(size: s)
            star.lockFocus()
            sym.draw(at: .zero, from: NSRect(origin: .zero, size: s), operation: .sourceOver, fraction: 1)
            NSColor(red: 1.0, green: 0.80, blue: 0.25, alpha: 1.0).set()
            NSRect(origin: .zero, size: s).fill(using: .sourceAtop)
            star.unlockFocus()
            star.draw(in: NSRect(x: (dim - s.width) / 2, y: (dim - s.height) / 2 + 2,
                                 width: s.width, height: s.height))
        }

        img.unlockFocus()
        return img
    }

    func setSelected(_ selected: Bool) {
        guard let mat = boxNode.geometry?.materials.first else { return }
        mat.emission.contents = selected
            ? NSColor(red: 0.18, green: 0.16, blue: 0.28, alpha: 1.0)
            : NSColor.black

        if selected {
            if selectionRingNode == nil {
                // Plane is larger than the box face to give the glow room to spread.
                // Texture maps the ring rect to exactly 2.8×4.2 scene units (see ringTexture).
                let plane = SCNPlane(width: GameBoxNode.ringPlaneW, height: GameBoxNode.ringPlaneH)
                let mat2 = SCNMaterial()
                mat2.diffuse.contents = GameBoxNode.ringTexture()
                mat2.lightingModel = .constant
                mat2.transparencyMode = .aOne
                mat2.isDoubleSided = false
                // Draw on top of the floor/neighbors so the bottom edge + downward glow
                // aren't clipped by the reflective SCNFloor sitting at the box's base.
                mat2.readsFromDepthBuffer = false
                mat2.writesToDepthBuffer = false
                plane.materials = [mat2]
                let n = SCNNode(geometry: plane)
                n.position = SCNVector3(0, 0, depth / 2 + 0.006)
                n.renderingOrder = 50
                n.name = "selectionRing"
                addChildNode(n)
                selectionRingNode = n
            }
            selectionRingNode?.isHidden = false
        } else {
            selectionRingNode?.isHidden = true
        }
    }

    // Grey out + slightly dim a box the live search doesn't match — the carousel's equivalent of
    // Grid/Wall/List's `View.searchGreyscale`. SceneKit materials have no saturation knob, but
    // `SCNNode.filters` runs a Core Image filter over the node's whole rendered output (art +
    // favorite star + selection ring, in one pass) — same effect, one line to toggle.
    private static let searchDimFilter: CIFilter = {
        let f = CIFilter(name: "CIColorControls")!
        f.setValue(0.0, forKey: kCIInputSaturationKey)
        f.setValue(-0.12, forKey: kCIInputBrightnessKey)
        return f
    }()

    func setSearchDimmed(_ dimmed: Bool) {
        filters = dimmed ? [GameBoxNode.searchDimFilter] : nil
    }

    // Ring texture geometry. The inner ring rect is a 2:3 portrait (320×480) matching the
    // box face (2.8×4.2); a uniform margin all around gives the glow room. Scale factor is
    // 320 / 2.8 = 114.286 px per scene unit, so the plane size is the canvas size / that.
    private static let ringInnerW: CGFloat = 320
    private static let ringInnerH: CGFloat = 480
    private static let ringMargin: CGFloat = 56
    private static let ringCornerRadiusPx: CGFloat = 18
    private static let ringPxPerUnit: CGFloat = ringInnerW / GameBoxNode.boxWidth
    static var ringPlaneW: CGFloat { (ringInnerW + ringMargin * 2) / ringPxPerUnit }
    static var ringPlaneH: CGFloat { (ringInnerH + ringMargin * 2) / ringPxPerUnit }

    // Same corner radius as the selection ring, expressed as a fraction of the box face width
    // so it applies correctly to art images of any resolution (all 2:3 portrait, like the box
    // face itself) — keeps the poster's own corners from ever peeking past the rounded ring.
    private static let frontCornerRadiusFraction: CGFloat = ringCornerRadiusPx / ringInnerW

    // Bakes an opaque fill color under the rounded-off corners rather than cutting them
    // genuinely transparent. A real alpha cutout (`transparencyMode = .aOne` + actual alpha < 1
    // pixels) reclassifies the front material into SceneKit's transparent render queue — tried
    // and reverted twice: a `renderingOrder` push alone
    // didn't stop the carousel's transparent `SCNFloor` from winning the paint order and clipping
    // the box's bottom edge, and adding `readsFromDepthBuffer = false` to fix THAT broke the
    // separate favorite-star overlay (a sibling node that no longer got respected once the front
    // face started ignoring the depth buffer). An opaque fill sidesteps all of it — the material
    // never leaves the opaque queue, so nothing about box-vs-box or box-vs-overlay depth
    // ordering changes.
    // Builds the canvas from the image's actual PIXEL dimensions (via its CGImage), not
    // `NSImage.size` — Steam-downloaded JPEGs can carry non-72 DPI metadata (seen: 71.12,
    // 96.52), which inflates `.size` to a fractional value that doesn't line up with the
    // real pixel grid (e.g. a 300×450 image reporting size (303.7, 455.6)). Baking the
    // rounded-corner composite at that inflated, non-integer size produced a corrupted
    // SceneKit texture for the affected games — the front face's bottom portion rendered as
    // solid fill color instead of art (only visible on the large, close-to-camera carousel
    // boxes). Pixel-exact sizing sidesteps whatever DPI/rounding step in SceneKit's texture
    // upload was choking on the fractional canvas.
    private static func roundedCorners(_ image: NSImage, fill: NSColor) -> NSImage {
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return image
        }
        let size = NSSize(width: cgImage.width, height: cgImage.height)
        let radius = size.width * frontCornerRadiusFraction
        let result = NSImage(size: size)
        result.lockFocus()
        fill.setFill()
        NSRect(origin: .zero, size: size).fill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: radius, yRadius: radius).addClip()
        NSGraphicsContext.current?.cgContext.draw(cgImage, in: NSRect(origin: .zero, size: size))
        result.unlockFocus()
        return result
    }

    private static func ringTexture() -> NSImage {
        let w = ringInnerW + ringMargin * 2
        let h = ringInnerH + ringMargin * 2
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()

        NSGraphicsContext.current?.cgContext.setLineCap(.round)
        NSGraphicsContext.current?.cgContext.setLineJoin(.round)

        let strokeW: CGFloat = 4
        let innerRect = NSRect(x: ringMargin, y: ringMargin, width: ringInnerW, height: ringInnerH)
        let path = NSBezierPath(roundedRect: innerRect, xRadius: ringCornerRadiusPx, yRadius: ringCornerRadiusPx)

        // Smooth outward glow: many translucent passes with a Gaussian alpha falloff so the
        // edge fades continuously instead of stepping (no "staircase" banding). Widest pass
        // first; each narrower pass paints on top, building intensity toward the core.
        let glow = NSColor(red: 0.66, green: 0.42, blue: 1.0, alpha: 1.0)
        let maxGlow: CGFloat = 38
        let sigma   = maxGlow * 0.42
        let steps   = 64
        for i in 0..<steps {
            let d = maxGlow * (1 - CGFloat(i) / CGFloat(steps - 1))   // outer → inner
            let alpha = 0.012 * exp(-(d * d) / (2 * sigma * sigma))
            path.lineWidth = strokeW + d * 2
            glow.withAlphaComponent(alpha).setStroke()
            path.stroke()
        }

        // Crisp white core stroke on top
        path.lineWidth = strokeW
        NSColor.white.withAlphaComponent(0.95).setStroke()
        path.stroke()

        img.unlockFocus()
        return img
    }

    private func placeholderImage(color: NSColor) -> NSImage {
        let size = NSSize(width: 300, height: 450)  // 2:3 ratio matches box geometry
        let image = NSImage(size: size)
        image.lockFocus()

        // Background gradient
        let gradient = NSGradient(
            colors: [color, color.blended(withFraction: 0.6, of: .black) ?? color],
            atLocations: [0.0, 1.0],
            colorSpace: .sRGB
        )
        gradient?.draw(in: NSRect(origin: .zero, size: size), angle: -90)

        // Game title text
        let title = game.title
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = .center

        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 28, weight: .bold),
            .foregroundColor: NSColor.white.withAlphaComponent(0.9),
            .paragraphStyle: paragraphStyle
        ]
        let textRect = NSRect(x: 10, y: size.height / 2 - 20, width: size.width - 20, height: 40)
        title.draw(in: textRect, withAttributes: attrs)

        image.unlockFocus()
        return image
    }

    func applyArt(_ image: NSImage) {
        guard let mat = boxNode.geometry?.materials.first else { return }
        mat.diffuse.contents = GameBoxNode.roundedCorners(image, fill: cornerFillColor)
    }
}
