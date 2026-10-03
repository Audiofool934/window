import CoreGraphics
import Foundation
import simd

/// The room in real units, seen from one eye. Everything on screen is projected from it.
///
/// World space has the eye at the origin, x to the right, y up, and z into the screen, in metres.
/// Screen space is in points with the origin at the top left, as the window server lays out displays.
public struct RoomLayout: Equatable, Sendable {
    public var screenSize: CGSize
    /// Pixels per point.
    public var scale: Double
    /// Points kept clear at the top and bottom of the display, so a larger opening stays on the glass.
    public var safeTop: Double
    public var safeBottom: Double
    /// The most this screen can open the window before the glass leaves it. 1 is the designed window.
    public var maxOpeningScale: Double
    /// Where straight ahead lands on the screen, in points.
    public var eye: CGPoint
    /// Points per unit of x/z, so a point at depth z moves focal/z points per metre.
    public var focal: Double
    /// Focal length used for the view outside, which is wider than the room's own perspective.
    public var outdoorFocal: Double

    // The wall and its window opening.
    public var wallDistance: Double
    public var revealDepth: Double
    public var sillProjection: Double
    public var sillThickness: Double
    public var sillHorn: Double
    public var openingLeft: Double
    public var openingRight: Double
    public var openingBottom: Double
    public var openingTop: Double
    public var frameWidth: Double
    public var bottomRail: Double
    public var barWidth: Double
    /// Vertical glazing bars, as x positions in metres.
    public var mullions: [Double]
    /// Horizontal glazing bars, as y positions in metres.
    public var transoms: [Double]

    // What stands on the sill.
    public var sleeveCentreX: Double
    public var sleeveBaseZ: Double
    public var sleeveYaw: Double
    public var sleeveLean: Double
    public var sleeveSize: Double = 0.315
    public var sleeveThickness: Double = 0.004
    public var lampCentre: SIMD3<Double>
    public var lampRadius: Double
    public var lampBaseRadius: Double
    public var lampBaseHeight: Double

    /// Where the glass plane sits.
    public var glassDepth: Double { wallDistance + revealDepth }
    public var sillFrontDepth: Double { wallDistance - sillProjection }

    public static func make(screenSize: CGSize, scale: Double, safeTop: Double = 25, safeBottom: Double = 0) -> RoomLayout {
        let width = Double(screenSize.width)
        let height = Double(screenSize.height)
        let contentHeight = max(height - safeTop - safeBottom, height * 0.6)

        // Real proportions: a 1.8 m by 1.3 m window in a thick wall, seen from a chair 2.4 m away.
        let openingWidth = 1.8
        let openingHeight = 1.3
        let wallDistance = 2.4
        let pointsPerMetre = min(contentHeight / 2.2, width / 2.75)
        let focal = pointsPerMetre * wallDistance

        // A seated eye sits a little above the sill, so the sill top shows and the horizon is low in the glass.
        let eyeAboveSill = 0.36
        let openingBottom = -eyeAboveSill
        let openingTop = openingBottom + openingHeight

        // The opening stays centred on the screen at every size. Its middle sits above the eye,
        // so the horizon stays low in the glass.
        let openingMidY = (openingBottom + openingTop) / 2
        let eye = CGPoint(x: width / 2, y: height / 2 + openingMidY * pointsPerMetre)

        let left = -openingWidth / 2
        let right = openingWidth / 2
        let revealDepth = 0.2
        let glassScale = focal / (wallDistance + revealDepth)
        let glassHeightPoints = (openingHeight - 0.09) * glassScale
        // The outside view spans about 58 degrees across the glass, wider than the room's own perspective.
        let glassWidthPoints = (openingWidth - 0.09) * glassScale
        let outdoorFocal = glassWidthPoints / 2 / tan(29 * Double.pi / 180)
        _ = glassHeightPoints

        let sillY = openingBottom
        var layout = RoomLayout(
            screenSize: screenSize,
            scale: scale,
            safeTop: safeTop,
            safeBottom: safeBottom,
            maxOpeningScale: 1,
            eye: eye,
            focal: focal,
            outdoorFocal: outdoorFocal,
            wallDistance: wallDistance,
            revealDepth: revealDepth,
            sillProjection: 0.13,
            sillThickness: 0.045,
            sillHorn: 0.07,
            openingLeft: left,
            openingRight: right,
            openingBottom: openingBottom,
            openingTop: openingTop,
            frameWidth: 0.045,
            bottomRail: 0.06,
            barWidth: 0.03,
            mullions: [0],
            transoms: [openingBottom + openingHeight * 0.72],
            sleeveCentreX: -0.42,
            sleeveBaseZ: wallDistance + revealDepth - 0.035,
            sleeveYaw: 0.2,
            sleeveLean: 0.15,
            // The lamp stands in the niche, so its light stays in the reveals and spills softly into the room.
            lampCentre: SIMD3(0.5, sillY + 0.06 + 0.095, wallDistance + 0.075),
            lampRadius: 0.095,
            lampBaseRadius: 0.045,
            lampBaseHeight: 0.06
        )
        layout.maxOpeningScale = layout.largestFittedOpening()
        return layout
    }

    /// The opening at `scale`, grown equally around the screen centre. 0 is shut. 1 is the designed 1.8 m by 1.3 m window.
    public func openingEdges(scale: Double) -> (left: Double, right: Double, bottom: Double, top: Double) {
        let scale = max(scale, 0)
        let midX = (openingLeft + openingRight) * 0.5
        let midY = (openingBottom + openingTop) * 0.5
        let halfW = (openingRight - openingLeft) * 0.5 * scale
        let halfH = (openingTop - openingBottom) * 0.5 * scale
        return (midX - halfW, midX + halfW, midY - halfH, midY + halfH)
    }

    /// Moves the sill and the sleeve onto the opening at `scale`. The designed layout is scale 1.
    public func following(openingScale scale: Double) -> RoomLayout {
        var placed = self
        let bottom = openingEdges(scale: scale).bottom
        let dy = bottom - openingBottom
        placed.openingBottom = bottom
        placed.openingTop += dy
        placed.lampCentre.y += dy
        placed.transoms = transoms.map { $0 + dy }
        return placed
    }

    /// The frame thins with a shrinking opening and stays at its real thickness once the window is full size.
    public func trimScale(for openingScale: Double) -> Double {
        min(max(openingScale, 0), 1)
    }

    /// The hole at `scale`, on the wall, in screen points. A shut opening is empty.
    public func openingRect(openingScale scale: Double) -> CGRect {
        let edges = openingEdges(scale: scale)
        let topLeft = project(SIMD3(edges.left, edges.top, wallDistance))
        let bottomRight = project(SIMD3(edges.right, edges.bottom, wallDistance))
        return CGRect(x: topLeft.x, y: topLeft.y, width: bottomRight.x - topLeft.x, height: bottomRight.y - topLeft.y)
    }

    /// Fully open is this fraction of the opening that would touch the screen edges.
    public static let maxFill = 0.85

    /// Largest scale on this display. A wide screen stops short of the top and bottom, a tall screen
    /// short of the left and right, by `maxFill`. The designed window is always allowed.
    public func largestFittedOpening(limit: Double = .greatestFiniteMagnitude) -> Double {
        let metresToPoints = focal / wallDistance
        let holeWidth = (openingRight - openingLeft) * metresToPoints
        let holeHeight = (openingTop - openingBottom) * metresToPoints
        guard holeWidth > 1, holeHeight > 1 else { return 1 }
        let edgeToEdge = min(Double(screenSize.width) / holeWidth, Double(screenSize.height) / holeHeight)
        return min(max(edgeToEdge * Self.maxFill, 1), limit)
    }

    /// `amount` runs from the designed window (0) to the largest this screen allows (1).
    public func openingScale(amount: Double) -> Double {
        let full = largestFittedOpening()
        let t = min(max(amount, 0), 1)
        return 1 + (full - 1) * t
    }

    /// Projects a world point to screen points.
    public func project(_ p: SIMD3<Double>) -> CGPoint {
        let k = focal / p.z
        return CGPoint(x: eye.x + p.x * k, y: eye.y - p.y * k)
    }

    /// The visible glass of the designed window, inside the frame, in screen points.
    public var glassRect: CGRect { glassRect(openingScale: 1) }

    /// The glass at `scale`. A shut opening has no glass.
    public func glassRect(openingScale scale: Double) -> CGRect {
        let edges = openingEdges(scale: scale)
        let trim = trimScale(for: scale)
        let frame = frameWidth * trim
        let rail = bottomRail * trim
        guard edges.right - edges.left > frame * 2 + 0.01, edges.top - edges.bottom > frame + rail + 0.01 else { return .null }
        let z = glassDepth
        let a = project(SIMD3(edges.left + frame, edges.top - frame, z))
        let b = project(SIMD3(edges.right - frame, edges.bottom + rail, z))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    /// The region that can hold the sleeve and the label.
    /// The sill rides the opening, so this covers it from the shut wall down to the fully open one.
    public var objectsRect: CGRect {
        let sills = [
            openingEdges(scale: 0).bottom,
            openingBottom,
            openingEdges(scale: max(maxOpeningScale, 1)).bottom
        ]
        let union = sills.reduce(into: CGRect.null) { rect, sillY in
            rect = rect.union(objectBounds(sillY: sillY))
        }
        return union.integral.intersection(CGRect(origin: .zero, size: screenSize))
    }

    private func objectBounds(sillY: Double) -> CGRect {
        let dy = sillY - openingBottom
        let lamp = SIMD3(lampCentre.x, lampCentre.y + dy, lampCentre.z)
        let lampTop = project(SIMD3(lamp.x, lamp.y + lampRadius * 3.4, lamp.z))
        let sleeveTop = project(SIMD3(sleeveCentreX, sillY + sleeveSize + 0.05, sleeveBaseZ))
        let left = project(SIMD3(sleeveCentreX - sleeveSize * 0.9, sillY, sillFrontDepth - 0.1))
        let right = project(SIMD3(lamp.x + lampRadius * 3.4, sillY, lamp.z))
        let bottom = project(SIMD3(0, sillY - sillThickness - 0.2, wallDistance))
        let top = min(lampTop.y, sleeveTop.y)
        return CGRect(x: left.x, y: top, width: right.x - left.x, height: bottom.y - top)
    }

    /// The baseline centre for the title, under the sleeve on the wall below the sill.
    public var labelAnchor: CGPoint {
        let p = project(SIMD3(sleeveCentreX, openingBottom - sillThickness - 0.075, wallDistance))
        return CGPoint(x: p.x, y: p.y)
    }
}
