import CoreGraphics
import Foundation
import simd

/// Moves the scene through time: cloud drift, weather easing between reports, wet glass, lightning,
/// the lamp's colour, and the sleeve on the sill. One driver serves every display.
public final class SceneDriver {
    public var place: Coordinate
    /// Radians clockwise from north.
    public var facing: Double
    public var landscapeSeed: Double

    /// The weather the glass is easing toward.
    public private(set) var target = Atmosphere.calm
    public private(set) var atmosphere = Atmosphere.calm
    private var cloudShift: [SIMD2<Double>] = [.zero, .zero, .zero]
    private var morph = 0.0
    private var wetness = 0.0
    private var clock = 0.0
    private var last: Date?
    private var lightning = Lightning()

    // The sill.
    public private(set) var standing = false
    private var pose = 1.0
    private var poseFrom = 1.0
    private var poseStart = -10.0
    private var lampColor = LampColor.incandescent
    private var lampTarget = LampColor.incandescent
    private var coverMix = 1.0
    private var hasCover = false
    private var labelAlpha = 0.0
    public var showLabel = true

    public init(place: Coordinate, facing: Double, landscapeSeed: Double) {
        self.place = place
        self.facing = facing
        self.landscapeSeed = landscapeSeed
    }

    /// A new report: the glass eases toward it over a minute or two, as weather does.
    public func setWeather(_ report: WeatherReport, immediately: Bool = false) {
        target = Atmosphere(report)
        if immediately {
            atmosphere = target
            wetness = min(target.rain * 1.2, 1)
        }
    }

    /// Something is playing: stand the sleeve up. Nothing is: lay it face down.
    public func setStanding(_ value: Bool) {
        guard value != standing else { return }
        standing = value
        poseFrom = pose
        poseStart = clock
    }

    /// A new cover has been loaded into the renderer.
    public func coverChanged(crossfade: Bool) {
        hasCover = true
        coverMix = crossfade ? 0 : 1
    }

    /// The song's colour for the lamp, or plain warm white when nothing is playing.
    public func setLamp(_ color: SIMD3<Double>?) {
        lampTarget = color ?? LampColor.incandescent
    }

    /// The sleeve, its cover, or its label is moving: only the sill needs drawing.
    public var isSillMoving: Bool {
        clock - poseStart < Self.poseDuration(rising: standing) + 0.1 || coverMix < 1 || abs(labelAlpha - labelTarget) > 0.01
    }

    /// The lamp is changing colour, which reaches the whole room.
    public var isLampMoving: Bool {
        simd_length(lampColor - lampTarget) > 0.01
    }

    /// Whether anything is moving enough to need full frame rate.
    public var isAnimating: Bool {
        isSillMoving || isLampMoving || lightning.isActive(at: clock)
    }

    /// Rain and snow need a steady frame rate to fall smoothly; clear skies drift slowly enough for less.
    public var needsFastFrames: Bool {
        atmosphere.rain > 0.02 || atmosphere.snow > 0.02 || isAnimating
    }

    private var labelTarget: Double { (standing && showLabel) ? 1 : 0 }

    public func advance(to date: Date) {
        let dt = min(max(last.map { date.timeIntervalSince($0) } ?? 0, 0), 0.5)
        last = date
        clock += dt

        // Weather eases over about a minute and a half; fog banks and rain fade in at the same pace.
        atmosphere = atmosphere.approaching(target, by: 1 - exp(-dt / 90))
        // Glass wets quickly once rain starts and dries slowly after it stops.
        let wetTarget = min(atmosphere.rain * 1.2, 1)
        let tau = wetTarget > wetness ? 25.0 : 420.0
        wetness += (wetTarget - wetness) * (1 - exp(-dt / tau))

        // Clouds drift with the wind, faster aloft.
        let wind = SIMD2(atmosphere.windEast, atmosphere.windNorth) / 1000
        let lift = [1.8, 2.6, 4.0]
        for i in 0..<3 {
            cloudShift[i] += wind * lift[i] * dt
            // Stay well inside single precision; a jump every few days is lost among changing clouds.
            if simd_length(cloudShift[i]) > 5000 { cloudShift[i] = .zero }
        }
        morph += dt * 0.0035
        if morph > 1000 { morph = 0 }

        lightning.advance(clock: clock, thunder: atmosphere.thunder)
        lampColor += (lampTarget - lampColor) * (1 - exp(-dt / 0.6))
        coverMix = min(coverMix + dt / 0.8, 1)
        labelAlpha += (labelTarget - labelAlpha) * (1 - exp(-dt / 0.35))

        let duration = Self.poseDuration(rising: standing)
        let t = min(max((clock - poseStart) / duration, 0), 1)
        let goal = standing ? 0.0 : 1.0
        pose = poseFrom + (goal - poseFrom) * (standing ? Self.lift(t) : Self.fall(t))
    }

    static func poseDuration(rising: Bool) -> Double { rising ? 1.3 : 0.95 }

    /// Lifted by hand: eases in and out.
    static func lift(_ t: Double) -> Double { t * t * (3 - 2 * t) }

    /// Tipping over: slow to start, quick through the middle, a small settle at the end.
    static func fall(_ t: Double) -> Double {
        if t < 0.82 {
            let u = t / 0.82
            return u * u * (1.2 - 0.2 * u)
        }
        let u = (t - 0.82) / 0.18
        return 1 + 0.025 * sin(u * .pi) * (1 - u)
    }

    /// The inputs for one frame, given the light measured through that display's glass.
    public func inputs(at date: Date, windowLight: SIMD3<Double>, adaptedLuminance: Double?) -> SceneInputs {
        var inputs = SceneInputs(date: date, place: place, facing: facing, atmosphere: atmosphere)
        inputs.cloudShift = cloudShift
        inputs.morph = morph
        inputs.flash = lightning.flash(at: clock)
        inputs.wetness = wetness
        inputs.lampColor = lampColor
        inputs.windowLight = windowLight
        inputs.adaptedLuminance = adaptedLuminance
        inputs.sleevePose = min(max(pose, 0), 1.02)
        inputs.coverMix = coverMix
        inputs.hasCover = hasCover
        inputs.labelAlpha = labelAlpha
        inputs.time = clock.truncatingRemainder(dividingBy: 7200)
        inputs.landscapeSeed = landscapeSeed
        return inputs
    }

    public var sillPose: Double { min(max(pose, 0), 1.02) }
}

/// Strikes come at random intervals in a thunderstorm, each a few quick flickers.
struct Lightning {
    private var next = 8.0
    private var pulses: [(time: Double, peak: Double)] = []
    private var random = SystemRandomNumberGenerator()

    mutating func advance(clock: Double, thunder: Double) {
        pulses.removeAll { clock - $0.time > 1.5 }
        guard thunder > 0.05 else {
            next = clock + 8
            return
        }
        if clock >= next {
            let count = Int.random(in: 2...4, using: &random)
            var t = clock
            for i in 0..<count {
                pulses.append((t, Double.random(in: 0.25...0.55, using: &random) * (i == 0 ? 1 : 0.8)))
                t += Double.random(in: 0.05...0.16, using: &random)
            }
            next = clock + Double.random(in: 7...38, using: &random) / max(thunder, 0.2)
        }
    }

    func flash(at clock: Double) -> Double {
        pulses.reduce(0) { sum, pulse in
            let age = clock - pulse.time
            return age < 0 ? sum : sum + pulse.peak * exp(-age / 0.06)
        }
    }

    func isActive(at clock: Double) -> Bool {
        pulses.contains { clock - $0.time < 0.6 }
    }
}
