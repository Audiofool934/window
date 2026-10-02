import Foundation
import WindowCore

/// What the menu changes, kept in user defaults.
final class Settings {
    private let defaults = UserDefaults.standard

    var isOn: Bool {
        get { defaults.object(forKey: "on") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "on") }
    }

    /// The small title and artist under the sleeve.
    var showTitle: Bool {
        get { defaults.object(forKey: "showTitle") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "showTitle") }
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

    /// The hills outside stay the same from launch to launch.
    var landscapeSeed: Double {
        if let seed = defaults.object(forKey: "landscapeSeed") as? Double { return seed }
        let seed = Double.random(in: 1...97).rounded()
        defaults.set(seed, forKey: "landscapeSeed")
        return seed
    }
}
