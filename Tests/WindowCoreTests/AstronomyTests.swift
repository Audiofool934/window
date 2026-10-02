import Foundation
import simd
import Testing
@testable import WindowCore

@Suite struct AstronomyTests {
    func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    func degrees(_ radians: Double) -> Double { radians * 180 / .pi }

    @Test func sunAtNoonOnTheJuneSolsticeOverGreenwich() {
        // Solar noon at Greenwich on 21 June is a minute or two after 12:00 UTC; the sun stands 23.4 degrees above the equinox height.
        let sun = Astronomy.sun(at: date("2026-06-21T12:02:00Z"), for: Coordinate(latitude: 51.4769, longitude: 0))
        #expect(abs(degrees(sun.altitude) - 61.97) < 0.4)
        #expect(abs(degrees(sun.azimuth) - 180) < 1.5)
    }

    @Test func sunIsUpInTheMorningEastAndDownAtMidnight() {
        let singapore = Coordinate(latitude: 1.3, longitude: 103.8)
        let morning = Astronomy.sun(at: date("2026-10-02T01:00:00Z"), for: singapore)
        #expect(morning.altitude > 0)
        #expect(degrees(morning.azimuth) > 45 && degrees(morning.azimuth) < 135)
        let midnight = Astronomy.sun(at: date("2026-10-02T16:00:00Z"), for: singapore)
        #expect(degrees(midnight.altitude) < -60)
    }

    @Test func moonIsFullOnTheHarvestMoonAndNewAtTheApril2024Eclipse() {
        let place = Coordinate(latitude: 40, longitude: -100)
        let full = date("2026-09-26T16:49:00Z")
        let fullLit = Astronomy.moonIllumination(sun: Astronomy.sun(at: full, for: place).vector,
                                                 moon: Astronomy.moon(at: full, for: place).position.vector)
        #expect(fullLit > 0.97)
        let eclipse = date("2024-04-08T18:21:00Z")
        let newLit = Astronomy.moonIllumination(sun: Astronomy.sun(at: eclipse, for: place).vector,
                                                moon: Astronomy.moon(at: eclipse, for: place).position.vector)
        #expect(newLit < 0.01)
    }

    @Test func equatorialFrameIsARotation() {
        let m = Astronomy.localToEquatorial(at: date("2026-10-02T12:00:00Z"), for: Coordinate(latitude: 1.3, longitude: 103.8))
        let identity = m.transpose * m
        for i in 0..<3 { for j in 0..<3 { #expect(abs(identity[i][j] - (i == j ? 1 : 0)) < 1e-9) } }
        // Straight up at latitude phi points at declination phi.
        let up = m * SIMD3<Double>(0, 1, 0)
        #expect(abs(degrees(asin(up.z)) - 1.3) < 1e-6)
    }

    @Test func cityLevelRoundsToATenthOfADegree() {
        let place = Coordinate(latitude: 1.28967, longitude: 103.85007).cityLevel
        #expect(place == Coordinate(latitude: 1.3, longitude: 103.9))
    }
}

@Suite struct LocationTests {
    @Test func parsesTimeZoneCoordinates() {
        let singapore = LocationProvider.parseISO6709("+0117+10351")!
        #expect(abs(singapore.latitude - (1 + 17.0 / 60)) < 1e-9)
        #expect(abs(singapore.longitude - (103 + 51.0 / 60)) < 1e-9)
        let losAngeles = LocationProvider.parseISO6709("+340308-1181434")!
        #expect(abs(losAngeles.latitude - (34 + 3.0 / 60 + 8.0 / 3600)) < 1e-9)
        #expect(abs(losAngeles.longitude + (118 + 14.0 / 60 + 34.0 / 3600)) < 1e-9)
        #expect(LocationProvider.parseISO6709("garbage") == nil)
    }

    @Test func findsTheMacsTimeZoneCity() {
        let berlin = LocationProvider.timeZoneCoordinate(TimeZone(identifier: "Europe/Berlin")!)
        #expect(berlin == Coordinate(latitude: 52.5, longitude: 13.4))
    }

    @Test func facesTheSunsSideOfTheSky() {
        #expect(WindowDefaults.facingDegrees(latitude: 52) == 180)
        #expect(WindowDefaults.facingDegrees(latitude: -33) == 0)
        #expect(WindowDefaults.facingDegrees(latitude: 1.3) == 270)
    }
}
