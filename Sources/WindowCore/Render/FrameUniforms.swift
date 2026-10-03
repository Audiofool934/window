import CoreGraphics
import Foundation
import simd

/// Byte-for-byte mirror of `Frame` in Room.metal. Every field is a float4 so the layouts cannot drift.
public struct FrameUniforms {
    public var screen = SIMD4<Float>.zero
    public var layer = SIMD4<Float>.zero
    public var eye = SIMD4<Float>.zero
    public var opening = SIMD4<Float>.zero
    public var depths = SIMD4<Float>.zero
    public var trim = SIMD4<Float>.zero
    public var mullionsX = SIMD4<Float>(repeating: 1000)
    public var transomsY = SIMD4<Float>(repeating: 1000)
    public var glass = SIMD4<Float>.zero
    public var camRight = SIMD4<Float>.zero
    public var camUp = SIMD4<Float>.zero
    public var camForward = SIMD4<Float>.zero
    public var sun = SIMD4<Float>.zero
    public var sunLight = SIMD4<Float>.zero
    public var moon = SIMD4<Float>.zero
    public var moonLight = SIMD4<Float>.zero
    public var clouds = SIMD4<Float>.zero
    public var cloudShift0 = SIMD4<Float>.zero
    public var cloudShift1 = SIMD4<Float>.zero
    public var weather = SIMD4<Float>.zero
    public var weather2 = SIMD4<Float>.zero
    public var precip = SIMD4<Float>.zero
    public var exposure = SIMD4<Float>.zero
    public var lampColor = SIMD4<Float>.zero
    public var lamp = SIMD4<Float>.zero
    public var windowLight = SIMD4<Float>.zero
    public var sleeve = SIMD4<Float>.zero
    public var sleeve2 = SIMD4<Float>.zero
    public var misc = SIMD4<Float>.zero
    public var cloudLight0 = SIMD4<Float>.zero
    public var cloudLight1 = SIMD4<Float>.zero
    public var cloudLight2 = SIMD4<Float>.zero
    public var cloudColour0 = SIMD4<Float>.zero
    public var cloudColour1 = SIMD4<Float>.zero
    public var cloudColour2 = SIMD4<Float>.zero
    /// x: how far the glass has crossfaded from the previous outdoor render to the latest.
    /// y, z: the designed sill, left and right, in metres. w: the opening scale (0 shut, 1 designed).
    public var timing = SIMD4<Float>(1, 0, 0, 0)
    /// x: how lived-in the wall is, from 0 bare to 1 fully grown. The opening does not follow it.
    public var occupation = SIMD4<Float>.zero
    public var stars = matrix_identity_float4x4

    public init() {}
}

/// Everything that changes from moment to moment, gathered so a frame can be built from it.
public struct SceneInputs: Sendable {
    public var date: Date
    public var place: Coordinate
    /// Radians clockwise from north that the window looks toward.
    public var facing: Double
    public var atmosphere: Atmosphere
    /// Accumulated drift of the three cloud layers, in kilometres.
    public var cloudShift: [SIMD2<Double>] = [.zero, .zero, .zero]
    public var morph: Double = 0
    public var flash: Double = 0
    /// How wet the glass is, which lags the rain.
    public var wetness: Double = 0
    /// Linear RGB, roughly unit luminance.
    public var lampColor: SIMD3<Double> = LampColor.incandescent
    /// Mean radiance coming through the glass, measured from the last outdoor frame. Lights the room.
    public var windowLight: SIMD3<Double> = SIMD3(repeating: 0.4)
    /// The luminance the eye has adapted to. It follows the window light slowly, so a flash stays a flash.
    public var adaptedLuminance: Double?
    /// 0 standing, 1 face down.
    public var sleevePose: Double = 1
    public var coverMix: Double = 1
    public var hasCover: Bool = false
    public var labelAlpha: Double = 0
    /// Animation clock in seconds.
    public var time: Double = 0
    public var landscapeSeed: Double = 0
    /// 0 is a bare wall. 1 is the most growth around the frame.
    public var growth: Double = 0

    public init(date: Date, place: Coordinate, facing: Double, atmosphere: Atmosphere) {
        self.date = date
        self.place = place
        self.facing = facing
        self.atmosphere = atmosphere
    }
}

public enum LampColor {
    /// A warm white bulb, as the eye sees it once adapted to the room: in linear RGB with unit luminance.
    public static let incandescent = SIMD3<Double>(1.2, 0.97, 0.74)
}

/// Light and exposure worked out on the CPU, shared by every pass.
public enum Lighting {
    public static let lampIntensity = 0.0022

    /// How bright the sky's own scattering is in the shader, so CPU light matches it.
    static let sunIntensity = 22.0

    /// Sunlight colour after its path through the air, seen from a given height.
    public static func sunlight(altitude: Double, heightKilometres h: Double = 0) -> SIMD3<Double> {
        let earth = 6360.0
        // Bodies stay lit a little after sunset when they sit high above the ground.
        let dip = acos(earth / (earth + h))
        let effective = altitude + dip
        if effective < -0.02 { return .zero }
        let degrees = max(effective, -0.01) * 180 / .pi
        let airMass = 1 / (sin(max(effective, 0)) + 0.50572 * pow(max(degrees + 6.07995, 0.5), -1.6364))
        let rayleigh = SIMD3<Double>(0.0464, 0.1085, 0.2648) * exp(-h / 8)
        let mie = 0.0053 * exp(-h / 1.2)
        let ozone = SIMD3<Double>(0.0098, 0.0282, 0.0013)
        let depth = (rayleigh + SIMD3(repeating: mie) + ozone) * min(airMass, 40)
        let transmittance = SIMD3<Double>(exp(-depth.x), exp(-depth.y), exp(-depth.z))
        let horizonFade = smoothstep(-0.02, 0.01, effective)
        return transmittance * horizonFade * sunIntensity * 0.32
    }

    /// Outdoor exposure, from how bright the view through the glass is.
    public static func outdoorExposure(windowLuminance key: Double) -> Double {
        0.42 / pow(key + 0.0016, 0.66)
    }

    /// The eye inside adapts to the room: daylight bounced off the walls, and a small even fill when the window is dark.
    public static func roomExposure(windowLuminance key: Double) -> Double {
        0.34 / (0.16 * key + 0.0028)
    }

    /// How dark it is, for the night look and the stars.
    public static func nightFactor(sunAltitude: Double) -> Double {
        1 - smoothstep(-0.13, -0.02, sunAltitude)
    }

    static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// The same tone curve as the shader, on luminance, for choosing label ink on the CPU.
    public static func displayValue(_ radiance: Double, exposure: Double) -> Double {
        let x = max(radiance * exposure, 0)
        let linear = min(max((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0), 1)
        return linear <= 0.0031308 ? linear * 12.92 : 1.055 * pow(linear, 1 / 2.4) - 0.055
    }
}

extension FrameUniforms {
    /// Builds the frame for one display. Layer origin and size are filled per pass.
    /// `openingScale` sizes the hole. `glassRect` is the pane the outdoor view was rendered for.
    /// The live room keeps one opening, and the glass is allocated for that full size.
    public static func make(layout: RoomLayout, inputs: SceneInputs, openingScale: Double = 1, glassRect: CGRect? = nil) -> FrameUniforms {
        var f = FrameUniforms()
        let s = layout.scale
        func px(_ v: Double) -> Float { Float(v * s) }
        func v4(_ a: Double, _ b: Double, _ c: Double, _ d: Double) -> SIMD4<Float> {
            SIMD4(Float(a), Float(b), Float(c), Float(d))
        }
        func v4(_ v: SIMD3<Double>, _ w: Double) -> SIMD4<Float> { v4(v.x, v.y, v.z, w) }

        f.screen = SIMD4(px(layout.screenSize.width), px(layout.screenSize.height), Float(s), Float(inputs.time))
        f.eye = SIMD4(px(layout.eye.x), px(layout.eye.y), px(layout.focal), px(layout.outdoorFocal))
        let edges = layout.openingEdges(scale: openingScale)
        f.opening = v4(edges.left, edges.right, edges.bottom, edges.top)
        let sillShift = edges.bottom - layout.openingBottom
        f.depths = v4(layout.wallDistance, layout.revealDepth, layout.sillProjection, layout.sillThickness)
        let trim = layout.trimScale(for: openingScale)
        f.trim = v4(layout.sillHorn, layout.frameWidth * trim, layout.bottomRail * trim, layout.barWidth * trim)
        let width = edges.right - edges.left
        let height = edges.top - edges.bottom
        // One mullion and one transom, hidden when the opening is too small to hold them.
        if width > layout.barWidth * 6 {
            f.mullionsX[0] = Float((edges.left + edges.right) / 2)
        }
        if height > 0.22 {
            f.transomsY[0] = Float(edges.bottom + height * 0.72)
        }
        var glass = glassRect ?? layout.glassRect(openingScale: openingScale)
        if glass.isNull || glass.width < 1 || glass.height < 1 { glass = layout.glassRect }
        f.glass = SIMD4(px(glass.minX), px(glass.minY), px(glass.maxX), px(glass.maxY))
        f.timing.y = Float(layout.openingLeft)
        f.timing.z = Float(layout.openingRight)
        f.timing.w = Float(openingScale)
        f.occupation = SIMD4(Float(min(max(inputs.growth, 0), 1)), 0, 0, 0)

        let a = inputs.facing
        // The view outside tilts up a few degrees, so the glass holds mostly sky over a low horizon.
        let pitch = 5.0 * Double.pi / 180
        f.camForward = v4(sin(a) * cos(pitch), sin(pitch), cos(a) * cos(pitch), 0)
        f.camRight = v4(cos(a), 0, -sin(a), 0)
        f.camUp = v4(-sin(a) * sin(pitch), cos(pitch), -cos(a) * sin(pitch), 0)

        let sun = Astronomy.sun(at: inputs.date, for: inputs.place)
        let moon = Astronomy.moon(at: inputs.date, for: inputs.place)
        let sunVector = sun.vector
        let moonVector = moon.position.vector
        let lit = Astronomy.moonIllumination(sun: sunVector, moon: moonVector)
        let sunGround = Lighting.sunlight(altitude: sun.altitude)
        f.sun = v4(sunVector, sun.altitude)
        f.sunLight = v4(sunGround, 1)
        f.moon = v4(moonVector, lit)
        // Moonlight is far brighter here than in nature, standing in for the eye's own adaptation.
        let moonGround = Lighting.sunlight(altitude: moon.position.altitude) * lit * 0.012
        // The disc is drawn at twice its true size, about as large as it seems to the eye.
        f.moonLight = v4(moonGround, 0.0045 * 2)

        let atmosphere = inputs.atmosphere
        let darkness = min(atmosphere.rain * 0.85 + atmosphere.thunder * 0.3 + atmosphere.snow * 0.35, 1)
        f.clouds = v4(atmosphere.cloudLow, atmosphere.cloudMid, atmosphere.cloudHigh, darkness)
        f.cloudShift0 = v4(inputs.cloudShift[0].x, inputs.cloudShift[0].y, inputs.cloudShift[1].x, inputs.cloudShift[1].y)
        // Cirrus combs out along the wind; with no wind, along the west-east drift of the mid-latitudes.
        let windAngle = (atmosphere.windEast == 0 && atmosphere.windNorth == 0) ? 0 : atan2(atmosphere.windNorth, atmosphere.windEast)
        f.cloudShift1 = v4(inputs.cloudShift[2].x, inputs.cloudShift[2].y, inputs.morph, windAngle)
        let heights = [1.3, 3.8, 8.5]
        var lights: [SIMD4<Float>] = []
        var colours: [SIMD4<Float>] = []
        for h in heights {
            let bySun = Lighting.sunlight(altitude: sun.altitude, heightKilometres: h)
            let byMoon = Lighting.sunlight(altitude: moon.position.altitude, heightKilometres: h) * lit * 0.012
            if simd_reduce_add(bySun) >= simd_reduce_add(byMoon) {
                lights.append(v4(sunVector, 0))
                colours.append(v4(bySun, 0))
            } else {
                lights.append(v4(moonVector, 0))
                colours.append(v4(byMoon, 0))
            }
        }
        f.cloudLight0 = lights[0]; f.cloudLight1 = lights[1]; f.cloudLight2 = lights[2]
        f.cloudColour0 = colours[0]; f.cloudColour1 = colours[1]; f.cloudColour2 = colours[2]

        f.weather = v4(atmosphere.rain, atmosphere.snow, atmosphere.drizzle, atmosphere.thunder)
        let night = Lighting.nightFactor(sunAltitude: sun.altitude)
        f.weather2 = v4(atmosphere.visibilityKilometres, atmosphere.frost, atmosphere.snowCover, night)
        // Rain and snow slant with the wind that crosses the line of sight.
        let crossWind = atmosphere.windEast * cos(a) - atmosphere.windNorth * sin(a)
        let windSpeed = (atmosphere.windEast * atmosphere.windEast + atmosphere.windNorth * atmosphere.windNorth).squareRoot()
        f.precip = v4(max(min(crossWind / 9, 0.5), -0.5), max(min(crossWind / 1.4, 1.6), -1.6), inputs.wetness, windSpeed)

        let key = max(luminance(inputs.windowLight), 0)
        let adapted = max(inputs.adaptedLuminance ?? key, 0)
        // The hole can shut, but the room keeps enough light to read as a wall.
        // The glass keeps the real outdoor exposure either way.
        let openness = Opening.lightOpenness(openingScale)
        let outdoorExposure = Lighting.outdoorExposure(windowLuminance: adapted)
        let roomExposure = Lighting.roomExposure(windowLuminance: adapted * openness)
        f.exposure = v4(outdoorExposure, roomExposure, inputs.flash, Lighting.lampIntensity)
        f.lampColor = v4(inputs.lampColor, 1)
        var lamp = layout.lampCentre
        lamp.y += sillShift
        f.lamp = v4(lamp, layout.lampRadius)
        f.windowLight = v4(inputs.windowLight, key)
        f.sleeve = v4(layout.sleeveCentreX, layout.sleeveBaseZ, layout.sleeveYaw, inputs.sleevePose)
        f.sleeve2 = v4(layout.sleeveSize, layout.sleeveThickness, inputs.coverMix, inputs.hasCover ? 1 : 0)
        let starVisibility = night * (1 - min(atmosphere.cloudLow * 0.2, 0.2))
        f.misc = v4(inputs.landscapeSeed, a, inputs.labelAlpha, starVisibility)

        let m = Astronomy.localToEquatorial(at: inputs.date, for: inputs.place)
        f.stars = simd_float4x4(
            SIMD4(Float(m.columns.0.x), Float(m.columns.0.y), Float(m.columns.0.z), 0),
            SIMD4(Float(m.columns.1.x), Float(m.columns.1.y), Float(m.columns.1.z), 0),
            SIMD4(Float(m.columns.2.x), Float(m.columns.2.y), Float(m.columns.2.z), 0),
            SIMD4(0, 0, 0, 1)
        )
        return f
    }

    static func luminance(_ c: SIMD3<Double>) -> Double {
        0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
    }
}
