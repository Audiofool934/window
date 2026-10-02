import Foundation
import simd

/// A place on Earth in degrees.
public struct Coordinate: Equatable, Codable, Sendable {
    public var latitude: Double
    public var longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }

    /// Rounded to a tenth of a degree, which is about city level.
    public var cityLevel: Coordinate {
        Coordinate(latitude: (latitude * 10).rounded() / 10, longitude: (longitude * 10).rounded() / 10)
    }
}

/// A direction in the observer's sky.
public struct SkyPosition: Equatable, Sendable {
    /// Radians clockwise from north.
    public var azimuth: Double
    /// Radians above the horizon.
    public var altitude: Double

    /// Unit vector in the local frame: x east, y up, z north.
    public var vector: SIMD3<Double> {
        SIMD3(cos(altitude) * sin(azimuth), sin(altitude), cos(altitude) * cos(azimuth))
    }
}

/// Low-precision sun and moon positions, after the formulas popularised by SunCalc.
/// The error is well under the size of the sun's disc, which is all a window needs.
public enum Astronomy {
    private static let rad = Double.pi / 180
    private static let obliquity = 23.4397 * rad

    public static func daysSinceJ2000(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86_400 - 10_957.5
    }

    /// Local sidereal time in radians.
    static func siderealTime(days d: Double, longitude: Double) -> Double {
        rad * (280.16 + 360.985_623_5 * d) + longitude * rad
    }

    private static func rightAscension(_ l: Double, _ b: Double) -> Double {
        atan2(sin(l) * cos(obliquity) - tan(b) * sin(obliquity), cos(l))
    }

    private static func declination(_ l: Double, _ b: Double) -> Double {
        asin(sin(b) * cos(obliquity) + cos(b) * sin(obliquity) * sin(l))
    }

    private static func horizontal(hourAngle h: Double, latitude phi: Double, declination dec: Double) -> SkyPosition {
        let fromSouth = atan2(sin(h), cos(h) * sin(phi) - tan(dec) * cos(phi))
        let altitude = asin(sin(phi) * sin(dec) + cos(phi) * cos(dec) * cos(h))
        var azimuth = fromSouth + .pi
        if azimuth >= 2 * .pi { azimuth -= 2 * .pi }
        return SkyPosition(azimuth: azimuth, altitude: altitude)
    }

    /// Atmospheric refraction lifts bodies near the horizon by about half a degree.
    static func refraction(altitude h: Double) -> Double {
        let clamped = max(h, 0)
        let lift = 0.000_296_7 / tan(clamped + 0.003_125_36 / (clamped + 0.089_011_79))
        // Fade the correction out well below the horizon, where nothing is visible anyway.
        let fade = min(max((h + 4 * rad) / (3 * rad), 0), 1)
        return lift * fade
    }

    public static func sun(at date: Date, for place: Coordinate) -> SkyPosition {
        let d = daysSinceJ2000(date)
        let m = rad * (357.5291 + 0.985_600_28 * d)
        let center = rad * (1.9148 * sin(m) + 0.02 * sin(2 * m) + 0.0003 * sin(3 * m))
        let longitude = m + center + rad * 102.9372 + .pi
        let ra = rightAscension(longitude, 0)
        let dec = declination(longitude, 0)
        let hourAngle = siderealTime(days: d, longitude: place.longitude) - ra
        var position = horizontal(hourAngle: hourAngle, latitude: place.latitude * rad, declination: dec)
        position.altitude += refraction(altitude: position.altitude)
        return position
    }

    public struct Moon: Equatable, Sendable {
        public var position: SkyPosition
        public var distanceKilometres: Double
    }

    public static func moon(at date: Date, for place: Coordinate) -> Moon {
        let d = daysSinceJ2000(date)
        let meanLongitude = rad * (218.316 + 13.176_396 * d)
        let meanAnomaly = rad * (134.963 + 13.064_993 * d)
        let meanDistance = rad * (93.272 + 13.229_350 * d)
        let l = meanLongitude + rad * 6.289 * sin(meanAnomaly)
        let b = rad * 5.128 * sin(meanDistance)
        let distance = 385_001 - 20_905 * cos(meanAnomaly)
        let hourAngle = siderealTime(days: d, longitude: place.longitude) - rightAscension(l, b)
        var position = horizontal(hourAngle: hourAngle, latitude: place.latitude * rad, declination: declination(l, b))
        // The moon is close enough that the observer's offset from Earth's centre lowers it by up to a degree.
        position.altitude -= asin(6378.14 / distance * cos(position.altitude))
        position.altitude += refraction(altitude: position.altitude)
        return Moon(position: position, distanceKilometres: distance)
    }

    /// Fraction of the moon's disc that is lit, from the angle between the sun and the moon.
    public static func moonIllumination(sun: SIMD3<Double>, moon: SIMD3<Double>) -> Double {
        (1 - simd_dot(simd_normalize(sun), simd_normalize(moon))) / 2
    }

    /// Columns are the local east, up, and north axes written in equatorial coordinates.
    /// Multiplying a local direction by this matrix gives the direction among the fixed stars.
    public static func localToEquatorial(at date: Date, for place: Coordinate) -> simd_double3x3 {
        let theta = siderealTime(days: daysSinceJ2000(date), longitude: place.longitude)
        let phi = place.latitude * rad
        let east = SIMD3(-sin(theta), cos(theta), 0)
        let up = SIMD3(cos(phi) * cos(theta), cos(phi) * sin(theta), sin(phi))
        let north = SIMD3(-sin(phi) * cos(theta), -sin(phi) * sin(theta), cos(phi))
        return simd_double3x3(columns: (east, up, north))
    }
}
