import AppKit
import WindowCore

/// Turns "now playing" into the sill: the sleeve stands while something plays, and leaves when it stops.
/// Nothing else in the room hears the music.
final class MusicController {
    /// A pause this short is not the end of the song.
    static let pauseGrace: TimeInterval = 12

    var onChange: (() -> Void)?
    /// The account stopped working and the Mac app took over.
    var onAccountLost: (() -> Void)?
    private(set) var nowPlaying: NowPlaying?
    private(set) var source: MusicSource = .mac
    private(set) var accountProblem: String?
    let local = SpotifyLocalSource()
    private var web: SpotifyWebSource?
    private let artwork = ArtworkLoader()
    private var coverURL: URL?
    private var graceTimer: Timer?
    private var loadingURI: String?
    private var running = false
    private let renderer: RoomRenderer
    private let driver: SceneDriver
    private let room: RoomController

    init(renderer: RoomRenderer, driver: SceneDriver, room: RoomController) {
        self.renderer = renderer
        self.driver = driver
        self.room = room
    }

    func use(_ newSource: MusicSource, clientID: String?) {
        let wasRunning = running
        stop()
        source = newSource
        accountProblem = nil
        web = nil
        if newSource == .account, let clientID {
            let web = SpotifyWebSource(account: SpotifyAccount(clientID: clientID))
            web.onChange = { [weak self] state in self?.handle(state) }
            web.onFailure = { [weak self] _ in
                // The account no longer answers, for example after access was revoked: fall back to the Mac app.
                guard let self else { return }
                self.use(.mac, clientID: nil)
                self.accountProblem = "Spotify account disconnected"
                self.onAccountLost?()
                self.onChange?()
            }
            self.web = web
            // The local app still hints when something changes, so the account is asked at once.
            local.onChange = nil
            local.onHint = { [weak web] in web?.refresh() }
        } else {
            source = .mac
            local.onChange = { [weak self] state in self?.handle(state) }
            local.onHint = nil
        }
        if wasRunning { start() }
    }

    func start() {
        running = true
        // WINDOW_DEMO_TRACK plays a pretend track instead of reading Spotify, for checking the sill without touching playback.
        let environment = ProcessInfo.processInfo.environment
        if let uri = environment["WINDOW_DEMO_TRACK"] {
            let demo = NowPlaying(uri: uri, title: environment["WINDOW_DEMO_TITLE"] ?? "Demo", artist: environment["WINDOW_DEMO_ARTIST"] ?? "Window",
                                  isPlaying: true)
            Timer.scheduledTimer(withTimeInterval: 1, repeats: false) { [weak self] _ in self?.handle(demo) }
            return
        }
        local.start()
        web?.start()
    }

    func stop() {
        running = false
        local.stop()
        web?.stop()
        graceTimer?.invalidate()
        graceTimer = nil
    }

    private func handle(_ state: NowPlaying?) {
        Debug.log("now playing: \(state.map { "\($0.isPlaying ? "playing" : "paused") \($0.title) / \($0.artist)" } ?? "nothing")")
        nowPlaying = state
        onChange?()
        guard let state, state.isPlaying else {
            // Paused or gone: wait a little before laying the sleeve down, in case it resumes.
            if graceTimer == nil, driver.standing {
                graceTimer = Timer.scheduledTimer(withTimeInterval: Self.pauseGrace, repeats: false) { [weak self] _ in
                    self?.graceTimer = nil
                    self?.layDown()
                }
            }
            return
        }
        graceTimer?.invalidate()
        graceTimer = nil
        room.sill.title = state.title
        room.sill.artist = state.artist
        load(state)
    }

    private func load(_ state: NowPlaying) {
        let uri = state.uri
        loadingURI = uri
        Task { [weak self] in
            guard let self else { return }
            let result = await self.artwork.image(for: state)
            await MainActor.run {
                guard self.loadingURI == uri, self.nowPlaying?.uri == uri, self.nowPlaying?.isPlaying == true else { return }
                if let result {
                    if result.url != self.coverURL {
                        self.renderer.setCover(result.image)
                        self.coverURL = result.url
                        self.driver.coverChanged(crossfade: self.driver.standing)
                    }
                } else if self.coverURL != nil {
                    // No art for this one, such as a local file: a plain sleeve, not the last song's cover.
                    self.renderer.setCover(nil)
                    self.coverURL = nil
                    self.driver.coverChanged(crossfade: self.driver.standing)
                }
                self.driver.setStanding(true)
                self.room.setNeedsRoomDraw()
            }
        }
    }

    private func layDown() {
        driver.setStanding(false)
        room.setNeedsRoomDraw()
    }
}
