import AppKit
import Foundation

/// Reads the Spotify app on this Mac. Spotify announces every change with a distributed notification,
/// and AppleScript answers the first question after launch. Nothing leaves the machine, and Spotify is never launched.
public final class SpotifyLocalSource: NowPlayingSource {
    public static let bundleIdentifier = "com.spotify.client"
    static let notification = Notification.Name("com.spotify.client.PlaybackStateChanged")

    public var onChange: ((NowPlaying?) -> Void)?
    /// Called when Spotify posts a change, so an account source can ask its API straight away.
    public var onHint: (() -> Void)?
    private var observers: [NSObjectProtocol] = []
    private let scripting = DispatchQueue(label: "blog.audiofool.window.applescript")
    private var running = false
    private var last: NowPlaying?

    public init() {}

    public func start() {
        guard !running else { return }
        running = true
        let distributed = DistributedNotificationCenter.default()
        observers.append(distributed.addObserver(forName: Self.notification, object: nil, queue: .main) { [weak self] note in
            self?.handle(note.userInfo)
        })
        let workspace = NSWorkspace.shared.notificationCenter
        observers.append(workspace.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == Self.bundleIdentifier else { return }
            self?.publish(nil)
        })
        refresh()
    }

    public func stop() {
        running = false
        for observer in observers {
            DistributedNotificationCenter.default().removeObserver(observer)
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }

    public var isSpotifyRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier).isEmpty
    }

    /// Asks Spotify directly. Only when it is already running, since a script would otherwise launch it.
    public func refresh() {
        guard running else { return }
        guard isSpotifyRunning else {
            publish(nil)
            return
        }
        scripting.async { [weak self] in
            let result = Self.query()
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                switch result {
                case .playing(let state): self.publish(state)
                case .stopped: self.publish(nil)
                case .unavailable: break // Keep what the notifications said.
                }
            }
        }
    }

    private func handle(_ info: [AnyHashable: Any]?) {
        Debug.log("spotify notification: \(info?["Player State"] ?? "?") \(info?["Name"] ?? "")")
        onHint?()
        guard let info else { return }
        let state = (info["Player State"] as? String) ?? ""
        if state == "Stopped" {
            publish(nil)
            return
        }
        guard let uri = info["Track ID"] as? String, !uri.hasPrefix("spotify:ad:") else { return }
        let next = NowPlaying(uri: uri,
                              title: (info["Name"] as? String) ?? "",
                              artist: (info["Artist"] as? String) ?? "",
                              album: (info["Album"] as? String) ?? "",
                              artworkURL: last?.uri == uri ? last?.artworkURL : nil,
                              isPlaying: state == "Playing")
        publish(next)
        // The notification carries no artwork; the script fills it in when allowed.
        if next.artworkURL == nil { refresh() }
    }

    private func publish(_ state: NowPlaying?) {
        guard state != last else { return }
        last = state
        onChange?(state)
    }

    enum Answer {
        case playing(NowPlaying)
        case stopped
        case unavailable
    }

    static let script = """
    tell application id "com.spotify.client"
        set s to player state as string
        if s is "stopped" then return "stopped"
        set t to current track
        set u to ""
        try
            set u to artwork url of t
        end try
        return s & tab & (id of t) & tab & (name of t) & tab & (artist of t) & tab & (album of t) & tab & u
    end tell
    """

    static func query() -> Answer {
        var error: NSDictionary?
        guard let output = NSAppleScript(source: script)?.executeAndReturnError(&error).stringValue else {
            // -1743 means the user has not allowed Window to read Spotify; notifications still work without it.
            Debug.log("spotify script failed: \(error?[NSAppleScript.errorNumber] ?? "?") \(error?[NSAppleScript.errorMessage] ?? "")")
            return .unavailable
        }
        Debug.log("spotify script: \(output.replacingOccurrences(of: "\t", with: " | "))")
        return parse(output)
    }

    static func parse(_ output: String) -> Answer {
        if output == "stopped" { return .stopped }
        let fields = output.components(separatedBy: "\t")
        guard fields.count >= 6, !fields[1].isEmpty, !fields[1].hasPrefix("spotify:ad:") else { return .unavailable }
        return .playing(NowPlaying(uri: fields[1], title: fields[2], artist: fields[3], album: fields[4],
                                   artworkURL: URL(string: fields[5]).flatMap { $0.scheme == "https" ? $0 : nil },
                                   isPlaying: fields[0] == "playing"))
    }
}
