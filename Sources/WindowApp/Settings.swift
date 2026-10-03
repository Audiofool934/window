import Foundation
import WindowCore

/// What the menu changes, kept in user defaults.
final class Settings {
    private let defaults = UserDefaults.standard

    var isOn: Bool {
        get { defaults.object(forKey: "on") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "on") }
    }

    /// How large the opening is. 0 is the designed window, 1 is the largest that still sits short of the edges.
    var openingAmount: Double {
        get {
            guard defaults.object(forKey: "openingAmount") != nil else { return 1 }
            return min(max(defaults.double(forKey: "openingAmount"), 0), 1)
        }
        set { defaults.set(min(max(newValue, 0), 1), forKey: "openingAmount") }
    }

    /// The small title and artist under the sleeve.
    var showTitle: Bool {
        get { defaults.object(forKey: "showTitle") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showTitle") }
    }

    /// This Mac's location, or a place the user picked on the map.
    enum PlaceMode: String {
        case automatic
        case chosen
    }

    var placeMode: PlaceMode {
        get { PlaceMode(rawValue: defaults.string(forKey: "placeMode") ?? "") ?? .automatic }
        set { defaults.set(newValue.rawValue, forKey: "placeMode") }
    }

    /// The place chosen on the map, already at city level. Kept when the mode switches back to this Mac.
    var chosenPlace: Coordinate? {
        get {
            guard defaults.object(forKey: "chosenLatitude") != nil, defaults.object(forKey: "chosenLongitude") != nil else { return nil }
            return Coordinate(latitude: defaults.double(forKey: "chosenLatitude"), longitude: defaults.double(forKey: "chosenLongitude"))
        }
        set {
            if let newValue {
                let place = newValue.cityLevel
                defaults.set(place.latitude, forKey: "chosenLatitude")
                defaults.set(place.longitude, forKey: "chosenLongitude")
            } else {
                defaults.removeObject(forKey: "chosenLatitude")
                defaults.removeObject(forKey: "chosenLongitude")
            }
        }
    }

    /// Degrees from north the window faces, or nil to face the sun's side of the sky for the place.
    var facing: Double? {
        get { defaults.object(forKey: "facing") as? Double }
        set { defaults.set(newValue, forKey: "facing") }
    }

    var source: MusicSource {
        get { (defaults.string(forKey: "source")).flatMap(MusicSource.init(rawValue:)) ?? .mac }
        set { defaults.set(newValue.rawValue, forKey: "source") }
    }

    /// The Client ID of the user's own Spotify developer app.
    var clientID: String? {
        get { defaults.string(forKey: "spotifyClientID").flatMap { $0.isEmpty ? nil : $0 } }
        set { defaults.set(newValue, forKey: "spotifyClientID") }
    }

    /// The growth state last settled on, so the wall does not flash bare while the logs are read.
    var savedGrowthState: Int? {
        get {
            guard defaults.object(forKey: "growthState") != nil else { return nil }
            return min(max(defaults.integer(forKey: "growthState"), 0), 3)
        }
        set {
            if let newValue {
                defaults.set(min(max(newValue, 0), 3), forKey: "growthState")
            } else {
                defaults.removeObject(forKey: "growthState")
            }
        }
    }

    /// The hills outside stay the same from launch to launch.
    var landscapeSeed: Double {
        if let seed = defaults.object(forKey: "landscapeSeed") as? Double { return seed }
        let seed = Double.random(in: 1...97).rounded()
        defaults.set(seed, forKey: "landscapeSeed")
        return seed
    }
}
