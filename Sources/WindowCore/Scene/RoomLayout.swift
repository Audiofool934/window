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

        // Centre the window, sill, and label as one block, set slightly above the optical centre.
        let blockTop = openingTop
        let blockBottom = openingBottom - 0.24
        let blockCentre = (blockTop + blockBottom) / 2
        let contentCentreY = safeTop + contentHeight / 2 - contentHeight * 0.02
        let eye = CGPoint(x: width / 2, y: contentCentreY + blockCentre * pointsPerMetre)

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
        return RoomLayout(
            screenSize: screenSize,
            scale: scale,
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
    }

    /// Projects a world point to screen points.
    public func project(_ p: SIMD3<Double>) -> CGPoint {
        let k = focal / p.z
        return CGPoint(x: eye.x + p.x * k, y: eye.y - p.y * k)
    }

    /// The visible glass, inside the frame, in screen points.
    public var glassRect: CGRect {
        let z = glassDepth
        let a = project(SIMD3(openingLeft + frameWidth, openingTop - frameWidth, z))
        let b = project(SIMD3(openingRight - frameWidth, openingBottom + bottomRail, z))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    /// The region that can hold the sleeve, the lamp, their glow, and the label.
    public var objectsRect: CGRect {
        let sillY = openingBottom
        let lampTop = project(SIMD3(lampCentre.x, lampCentre.y + lampRadius * 3.4, lampCentre.z))
        let sleeveTop = project(SIMD3(sleeveCentreX, sillY + sleeveSize + 0.05, sleeveBaseZ))
        let left = project(SIMD3(sleeveCentreX - sleeveSize * 0.9, sillY, sillFrontDepth - 0.1))
        let right = project(SIMD3(lampCentre.x + lampRadius * 3.4, sillY, lampCentre.z))
        let bottom = project(SIMD3(0, sillY - sillThickness - 0.2, wallDistance))
        let top = min(lampTop.y, sleeveTop.y)
        let rect = CGRect(x: left.x, y: top, width: right.x - left.x, height: bottom.y - top)
        return rect.integral.intersection(CGRect(origin: .zero, size: screenSize))
    }

    /// The baseline centre for the title, under the sleeve on the wall below the sill.
    public var labelAnchor: CGPoint {
        let p = project(SIMD3(sleeveCentreX, openingBottom - sillThickness - 0.075, wallDistance))
        return CGPoint(x: p.x, y: p.y)
    }
}
