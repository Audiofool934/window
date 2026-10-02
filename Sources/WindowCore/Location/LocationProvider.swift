import CoreLocation
import Foundation

/// Where the window is. Kept at city level and on this machine; only the rounded coordinates go out, for the weather.
public final class LocationProvider: NSObject, CLLocationManagerDelegate {
    public enum Origin: String, Sendable {
        /// Location Services, rounded to a tenth of a degree.
        case located
        /// The reference city of the Mac's time zone, when location is not available.
        case timeZone
    }

    public var onUpdate: ((Coordinate, Origin) -> Void)?
    public private(set) var current: (coordinate: Coordinate, origin: Origin)?
    private let manager = CLLocationManager()
    private var timer: Timer?

    public override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }

    public func start() {
        // The last known place first, so the sky is right from the first frame.
        if let saved = Self.saved {
            current = (saved, .located)
        } else if let zone = Self.timeZoneCoordinate() {
            current = (zone, .timeZone)
        }
        if let current { onUpdate?(current.coordinate, current.origin) }
        requestIfAllowed()
        // Laptops travel; a few times a day is plenty for a sky.
        timer = Timer.scheduledTimer(withTimeInterval: 3 * 3600, repeats: true) { [weak self] _ in self?.requestIfAllowed() }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func requestIfAllowed() {
        switch manager.authorizationStatus {
        case .notDetermined: manager.requestWhenInUseAuthorization()
        case .denied, .restricted: fallBack()
        default: manager.requestLocation()
        }
    }

    public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Debug.log("location authorization \(manager.authorizationStatus.rawValue)")
        switch manager.authorizationStatus {
        case .notDetermined: break
        case .denied, .restricted: fallBack()
        default: manager.requestLocation()
        }
    }

    public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        let place = Coordinate(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude).cityLevel
        Self.saved = place
        publish(place, .located)
    }

    public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if current == nil { fallBack() }
    }

    private func fallBack() {
        guard current?.origin != .located || Self.saved == nil else { return }
        if let zone = Self.timeZoneCoordinate() { publish(zone, .timeZone) }
    }

    private func publish(_ place: Coordinate, _ origin: Origin) {
        Debug.log("place \(place.latitude), \(place.longitude) from \(origin.rawValue)")
        guard current?.coordinate != place || current?.origin != origin else { return }
        current = (place, origin)
        onUpdate?(place, origin)
    }

    private static let savedKey = "location.cityLevel"

    static var saved: Coordinate? {
        get {
            guard let data = UserDefaults.standard.data(forKey: savedKey) else { return nil }
            return try? JSONDecoder().decode(Coordinate.self, from: data)
        }
        set {
            UserDefaults.standard.set(newValue.flatMap { try? JSONEncoder().encode($0) }, forKey: savedKey)
        }
    }

    /// The time zone database lists a reference city for each zone, which is close enough for a sky.
    public static func timeZoneCoordinate(_ zone: TimeZone = .current, table: String = "/usr/share/zoneinfo/zone.tab") -> Coordinate? {
        guard let text = try? String(contentsOfFile: table, encoding: .utf8) else { return nil }
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let fields = line.split(separator: "\t")
            guard fields.count >= 3, fields[2] == zone.identifier else { continue }
            return parseISO6709(String(fields[1]))?.cityLevel
        }
        return nil
    }

    /// Parses "+0117+10351" or "+340308-1181434" into degrees.
    static func parseISO6709(_ text: String) -> Coordinate? {
        let scalars = Array(text)
        guard let split = scalars.dropFirst().firstIndex(where: { $0 == "+" || $0 == "-" }) else { return nil }
        func degrees(_ part: ArraySlice<Character>, degreeDigits: Int) -> Double? {
            guard let sign = part.first, sign == "+" || sign == "-" else { return nil }
            let digits = String(part.dropFirst())
            guard digits.count >= degreeDigits + 2, digits.allSatisfy(\.isNumber) else { return nil }
            let chars = Array(digits)
            let d = Double(String(chars[0..<degreeDigits]))!
            let m = Double(String(chars[degreeDigits..<(degreeDigits + 2)]))!
            let s = chars.count >= degreeDigits + 4 ? Double(String(chars[(degreeDigits + 2)..<(degreeDigits + 4)]))! : 0
            let value = d + m / 60 + s / 3600
            return sign == "-" ? -value : value
        }
        guard let lat = degrees(scalars[0..<split], degreeDigits: 2),
              let lon = degrees(scalars[split...], degreeDigits: 3) else { return nil }
        return Coordinate(latitude: lat, longitude: lon)
    }
}
