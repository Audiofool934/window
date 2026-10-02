import Foundation
import Testing
@testable import WindowCore

@Suite struct WeatherTests {
    static let sample = """
    {"latitude":1.3,"longitude":103.8,"current":{"time":"2026-10-02T04:45","interval":900,"temperature_2m":30.3,
    "relative_humidity_2m":72,"precipitation":0.2,"weather_code":53,"cloud_cover":83,"cloud_cover_low":26,
    "cloud_cover_mid":13,"cloud_cover_high":74,"visibility":9980.0,"wind_speed_10m":8.4,"wind_direction_10m":187,"snow_depth":0.0}}
    """

    @Test func decodesOpenMeteoCurrentConditions() throws {
        let report = try OpenMeteoClient.decode(Data(Self.sample.utf8))
        #expect(report.weatherCode == 53)
        #expect(report.temperature == 30.3)
        #expect(report.cloudCoverHigh == 74)
        #expect(report.visibility == 9980)
        #expect(report.summary == "Drizzle, 30°")
        #expect(report.observedAt == ISO8601DateFormatter().date(from: "2026-10-02T04:45:00Z"))
    }

    @Test func onlyRoundedCoordinatesLeaveTheMachine() {
        let url = OpenMeteoClient.requestURL(for: Coordinate(latitude: 1.28967, longitude: 103.85007).cityLevel)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(Set(items.map(\.name)) == ["latitude", "longitude", "current", "timezone"])
        #expect(items.first { $0.name == "latitude" }?.value == "1.3")
        #expect(items.first { $0.name == "longitude" }?.value == "103.9")
        #expect(url.host == "api.open-meteo.com")
    }

    func report(code: Int, low: Double = 20, precipitation: Double = 0, temperature: Double = 12,
                visibility: Double? = 20_000, snowDepth: Double? = 0) -> WeatherReport {
        WeatherReport(observedAt: Date(), temperature: temperature, weatherCode: code, precipitation: precipitation,
                      cloudCover: low, cloudCoverLow: low, cloudCoverMid: 0, cloudCoverHigh: 0, visibility: visibility,
                      windSpeed: 18, windDirection: 270, snowDepth: snowDepth)
    }

    @Test func drizzleRainSnowAndFogBecomeWhatTheGlassShows() {
        let drizzle = Atmosphere(report(code: 53))
        #expect(drizzle.drizzle == 1 && drizzle.rain > 0.1 && drizzle.rain < 0.4)
        // Rain falls from cloud overhead, whatever the deck totals said.
        #expect(drizzle.cloudLow >= 0.75)

        let downpour = Atmosphere(report(code: 65))
        #expect(downpour.rain > drizzle.rain)
        let storm = Atmosphere(report(code: 99))
        #expect(storm.thunder == 1)

        let snow = Atmosphere(report(code: 73, temperature: -3, snowDepth: 0.1))
        #expect(snow.snow > 0.5 && snow.rain == 0 && snow.snowCover == 1)

        let fog = Atmosphere(report(code: 45, visibility: 2000))
        #expect(fog.visibilityKilometres <= 0.35)
    }

    @Test func precipitationUnderACloudyCodeStillFalls() {
        let warm = Atmosphere(report(code: 3, precipitation: 0.5, temperature: 20))
        #expect(warm.rain > 0 && warm.snow == 0)
        let cold = Atmosphere(report(code: 3, precipitation: 0.5, temperature: -2))
        #expect(cold.snow > 0 && cold.rain == 0)
    }

    @Test func windIsReportedAsWhereItComesFrom() {
        // A westerly blows toward the east.
        let atmosphere = Atmosphere(report(code: 0))
        #expect(atmosphere.windEast > 4.9 && abs(atmosphere.windNorth) < 1e-9)
    }

    @Test func easingMovesPartWayAndVisibilityEasesInLogSpace() {
        var clear = Atmosphere.calm
        clear.visibilityKilometres = 30
        var fog = Atmosphere.calm
        fog.visibilityKilometres = 0.3
        fog.rain = 1
        let half = clear.approaching(fog, by: 0.5)
        #expect(abs(half.rain - 0.5) < 1e-9)
        #expect(abs(half.visibilityKilometres - 3) < 1e-9)
    }
}
