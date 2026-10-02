import Foundation

/// The current conditions as Open-Meteo reports them.
public struct WeatherReport: Codable, Equatable, Sendable {
    public var observedAt: Date
    public var temperature: Double
    public var humidity: Double?
    public var weatherCode: Int
    /// Millimetres in the preceding fifteen minutes.
    public var precipitation: Double
    public var cloudCover: Double
    public var cloudCoverLow: Double
    public var cloudCoverMid: Double
    public var cloudCoverHigh: Double
    /// Metres, when the model provides it.
    public var visibility: Double?
    /// Kilometres per hour.
    public var windSpeed: Double
    /// Degrees the wind blows from.
    public var windDirection: Double
    /// Metres of snow on the ground.
    public var snowDepth: Double?

    public init(observedAt: Date, temperature: Double, humidity: Double? = nil, weatherCode: Int, precipitation: Double = 0,
                cloudCover: Double, cloudCoverLow: Double, cloudCoverMid: Double, cloudCoverHigh: Double,
                visibility: Double? = nil, windSpeed: Double = 0, windDirection: Double = 0, snowDepth: Double? = nil) {
        self.observedAt = observedAt
        self.temperature = temperature
        self.humidity = humidity
        self.weatherCode = weatherCode
        self.precipitation = precipitation
        self.cloudCover = cloudCover
        self.cloudCoverLow = cloudCoverLow
        self.cloudCoverMid = cloudCoverMid
        self.cloudCoverHigh = cloudCoverHigh
        self.visibility = visibility
        self.windSpeed = windSpeed
        self.windDirection = windDirection
        self.snowDepth = snowDepth
    }

    /// A short plain description, for the menu.
    public var summary: String {
        let words: String
        switch weatherCode {
        case 0: words = "Clear"
        case 1: words = "Mostly clear"
        case 2: words = "Partly cloudy"
        case 3: words = "Overcast"
        case 45, 48: words = "Fog"
        case 51, 53, 55: words = "Drizzle"
        case 56, 57: words = "Freezing drizzle"
        case 61: words = "Light rain"
        case 63: words = "Rain"
        case 65: words = "Heavy rain"
        case 66, 67: words = "Freezing rain"
        case 71: words = "Light snow"
        case 73: words = "Snow"
        case 75: words = "Heavy snow"
        case 77: words = "Snow grains"
        case 80, 81: words = "Showers"
        case 82: words = "Heavy showers"
        case 85, 86: words = "Snow showers"
        case 95: words = "Thunderstorm"
        case 96, 99: words = "Thunderstorm with hail"
        default: words = "Weather code \(weatherCode)"
        }
        return "\(words), \(Int(temperature.rounded()))°"
    }
}

/// What the glass shows, reduced to a few numbers that can be eased between reports.
public struct Atmosphere: Equatable, Sendable {
    public var cloudLow: Double = 0.1
    public var cloudMid: Double = 0.1
    public var cloudHigh: Double = 0.2
    /// 0 to 1, light drizzle to a downpour.
    public var rain: Double = 0
    /// 1 when the rain is fine drizzle.
    public var drizzle: Double = 0
    public var snow: Double = 0
    public var thunder: Double = 0
    public var visibilityKilometres: Double = 30
    /// Metres per second at ten metres, toward the east and the north.
    public var windEast: Double = 1
    public var windNorth: Double = 0
    public var temperature: Double = 15
    public var snowCover: Double = 0
    public var frost: Double = 0

    public init() {}

    public static let calm = Atmosphere()

    public init(_ report: WeatherReport) {
        cloudLow = report.cloudCoverLow / 100
        cloudMid = report.cloudCoverMid / 100
        cloudHigh = report.cloudCoverHigh / 100
        temperature = report.temperature
        visibilityKilometres = min(max((report.visibility ?? 30_000) / 1000, 0.05), 60)

        switch report.weatherCode {
        case 45, 48: visibilityKilometres = min(visibilityKilometres, 0.35)
        case 51: rain = 0.16; drizzle = 1
        case 53: rain = 0.24; drizzle = 1
        case 55: rain = 0.34; drizzle = 1
        case 56: rain = 0.2; drizzle = 1; frost = 0.5
        case 57: rain = 0.34; drizzle = 1; frost = 0.6
        case 61: rain = 0.36
        case 63: rain = 0.6
        case 65: rain = 0.88
        case 66: rain = 0.42; frost = 0.5
        case 67: rain = 0.8; frost = 0.6
        case 71: snow = 0.32
        case 73: snow = 0.6
        case 75: snow = 0.9
        case 77: snow = 0.24
        case 80: rain = 0.42
        case 81: rain = 0.66
        case 82: rain = 1
        case 85: snow = 0.42
        case 86: snow = 0.85
        case 95: rain = 0.72; thunder = 0.6
        case 96, 99: rain = 0.9; thunder = 1
        default: break
        }
        // A model can report rain under a "cloudy" code; fifteen-minute totals settle the question.
        if rain == 0 && snow == 0 && report.precipitation > 0.04 {
            let amount = min(report.precipitation * 4 / 6, 1) * 0.7 + 0.15
            if report.temperature < 0.5 { snow = amount } else { rain = amount }
        }
        // Precipitation falls from cloud overhead, whatever the layer totals say.
        let wet = max(rain, snow)
        if wet > 0 {
            cloudLow = max(cloudLow, 0.75 + 0.25 * wet)
            cloudMid = max(cloudMid, 0.5)
            visibilityKilometres = min(visibilityKilometres, 30 - 26 * wet)
        }
        if report.weatherCode == 3 { cloudLow = max(cloudLow, max(report.cloudCover / 100 - 0.05, 0.6)) }

        // Wind is reported as the direction it comes from.
        let toward = (report.windDirection + 180) * .pi / 180
        let speed = report.windSpeed / 3.6
        windEast = speed * sin(toward)
        windNorth = speed * cos(toward)

        snowCover = min(max((report.snowDepth ?? 0) / 0.04, 0), 1)
        if report.temperature < -1 { frost = max(frost, min((-1 - report.temperature) / 12, 1) * 0.7) }
    }

    /// Eases every field toward the target by the fraction t.
    public func approaching(_ target: Atmosphere, by t: Double) -> Atmosphere {
        func mix(_ a: Double, _ b: Double) -> Double { a + (b - a) * t }
        var next = self
        next.cloudLow = mix(cloudLow, target.cloudLow)
        next.cloudMid = mix(cloudMid, target.cloudMid)
        next.cloudHigh = mix(cloudHigh, target.cloudHigh)
        next.rain = mix(rain, target.rain)
        next.drizzle = mix(drizzle, target.drizzle)
        next.snow = mix(snow, target.snow)
        next.thunder = mix(thunder, target.thunder)
        // Visibility eases in log space so a fog bank arrives at a believable pace.
        next.visibilityKilometres = exp(mix(log(visibilityKilometres), log(target.visibilityKilometres)))
        next.windEast = mix(windEast, target.windEast)
        next.windNorth = mix(windNorth, target.windNorth)
        next.temperature = mix(temperature, target.temperature)
        next.snowCover = mix(snowCover, target.snowCover)
        next.frost = mix(frost, target.frost)
        return next
    }
}

/// Fetches current conditions. Only the coordinates leave the machine.
public struct OpenMeteoClient: Sendable {
    public var session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public static func requestURL(for place: Coordinate) -> URL {
        let fields = [
            "temperature_2m", "relative_humidity_2m", "precipitation", "weather_code",
            "cloud_cover", "cloud_cover_low", "cloud_cover_mid", "cloud_cover_high",
            "visibility", "wind_speed_10m", "wind_direction_10m", "snow_depth"
        ]
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.1f", place.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.1f", place.longitude)),
            URLQueryItem(name: "current", value: fields.joined(separator: ",")),
            URLQueryItem(name: "timezone", value: "GMT")
        ]
        return components.url!
    }

    public func current(at place: Coordinate) async throws -> WeatherReport {
        var request = URLRequest(url: Self.requestURL(for: place.cityLevel), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw URLError(.badServerResponse)
        }
        return try Self.decode(data)
    }

    public static func decode(_ data: Data) throws -> WeatherReport {
        struct Envelope: Decodable {
            struct Current: Decodable {
                var time: String
                var temperature_2m: Double
                var relative_humidity_2m: Double?
                var precipitation: Double?
                var weather_code: Int
                var cloud_cover: Double?
                var cloud_cover_low: Double?
                var cloud_cover_mid: Double?
                var cloud_cover_high: Double?
                var visibility: Double?
                var wind_speed_10m: Double?
                var wind_direction_10m: Double?
                var snow_depth: Double?
            }
            var current: Current
        }
        let current = try JSONDecoder().decode(Envelope.self, from: data).current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let total = current.cloud_cover ?? 0
        return WeatherReport(
            observedAt: formatter.date(from: current.time) ?? Date(),
            temperature: current.temperature_2m,
            humidity: current.relative_humidity_2m,
            weatherCode: current.weather_code,
            precipitation: current.precipitation ?? 0,
            cloudCover: total,
            cloudCoverLow: current.cloud_cover_low ?? total,
            cloudCoverMid: current.cloud_cover_mid ?? 0,
            cloudCoverHigh: current.cloud_cover_high ?? 0,
            visibility: current.visibility,
            windSpeed: current.wind_speed_10m ?? 0,
            windDirection: current.wind_direction_10m ?? 0,
            snowDepth: current.snow_depth
        )
    }
}
