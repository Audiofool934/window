import Foundation

/// What a source reports about the song. Only the sill sees it.
public struct NowPlaying: Equatable, Sendable {
    /// A Spotify URI such as spotify:track:4uLU6hMCjMI75M1A2tKUQC.
    public var uri: String
    public var title: String
    public var artist: String
    public var album: String
    /// Cover art the source already knows, when it knows it.
    public var artworkURL: URL?
    public var isPlaying: Bool

    public init(uri: String, title: String, artist: String, album: String = "", artworkURL: URL? = nil, isPlaying: Bool) {
        self.uri = uri
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
        self.isPlaying = isPlaying
    }

    /// The open.spotify.com page for the item, which the public oEmbed endpoint accepts.
    public var webURL: URL? {
        let parts = uri.split(separator: ":")
        guard parts.count == 3, parts[0] == "spotify", ["track", "episode"].contains(String(parts[1])) else { return nil }
        return URL(string: "https://open.spotify.com/\(parts[1])/\(parts[2])")
    }
}

/// Where "now playing" comes from.
public enum MusicSource: String, CaseIterable, Sendable {
    /// The Spotify app on this Mac, read locally. No login, but blind to other devices.
    case mac
    /// The Spotify account through the Web API: phone, speakers, and this Mac alike.
    case account
}

public protocol NowPlayingSource: AnyObject {
    /// Called on the main queue whenever the reported state changes; nil means nothing at all.
    var onChange: ((NowPlaying?) -> Void)? { get set }
    func start()
    func stop()
    /// Ask again now, for example when the local app hints that something changed.
    func refresh()
}
