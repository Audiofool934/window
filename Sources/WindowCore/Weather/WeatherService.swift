import Foundation

/// Keeps the current conditions fresh: every fifteen minutes, on wake, and when the place changes.
public final class WeatherService {
    public var onUpdate: ((WeatherReport) -> Void)?
    public private(set) var latest: WeatherReport?
    private let client: OpenMeteoClient
    private var place: Coordinate?
    private var timer: Timer?
    private var lastFetch: Date?
    private var fetching = false
    private var running = false
    private var failures = 0
    public static let interval: TimeInterval = 15 * 60

    public init(client: OpenMeteoClient = OpenMeteoClient()) {
        self.client = client
    }

    public func start() {
        running = true
        if let cached = Self.cached, let place, cached.place == place.cityLevel,
           Date().timeIntervalSince(cached.fetched) < 3600 {
            latest = cached.report
            onUpdate?(cached.report)
        }
        schedule(after: 0)
    }

    public func stop() {
        running = false
        timer?.invalidate()
        timer = nil
    }

    public func setPlace(_ newPlace: Coordinate) {
        let rounded = newPlace.cityLevel
        guard rounded != place else { return }
        place = rounded
        if running { schedule(after: 0) }
    }

    /// After sleep the sky may be hours out of date.
    public func refreshIfStale() {
        guard running else { return }
        if lastFetch.map({ Date().timeIntervalSince($0) > 10 * 60 }) ?? true { schedule(after: 0) }
    }

    private func schedule(after seconds: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in self?.fetch() }
    }

    private func fetch() {
        guard let place, !fetching else { return }
        fetching = true
        Task { [weak self] in
            guard let self else { return }
            do {
                let report = try await self.client.current(at: place)
                Debug.log("weather for \(place.latitude), \(place.longitude): code \(report.weatherCode), \(report.summary)")
                await MainActor.run {
                    self.fetching = false
                    self.failures = 0
                    guard self.running else { return }
                    self.lastFetch = Date()
                    self.latest = report
                    Self.cached = Cache(place: place, fetched: Date(), report: report)
                    self.onUpdate?(report)
                    self.schedule(after: Self.interval)
                }
            } catch {
                Debug.log("weather failed: \(error)")
                await MainActor.run {
                    self.fetching = false
                    self.failures += 1
                    // Back off gently while offline, but never wait longer than the normal interval.
                    self.schedule(after: min(60 * pow(2, Double(self.failures - 1)), Self.interval))
                }
            }
        }
    }

    struct Cache: Codable {
        var place: Coordinate
        var fetched: Date
        var report: WeatherReport
    }

    private static let cacheKey = "weather.cache"

    static var cached: Cache? {
        get { UserDefaults.standard.data(forKey: cacheKey).flatMap { try? JSONDecoder().decode(Cache.self, from: $0) } }
        set { UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: cacheKey) }
    }
}
