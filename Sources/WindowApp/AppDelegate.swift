import AppKit
import WindowCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let compass = ["North", "North-East", "East", "South-East", "South", "South-West", "West", "North-West"]

    let settings = Settings()
    private(set) var room: RoomController!
    private(set) var music: MusicController!
    private(set) var weather = WeatherService()
    private(set) var place: Coordinate?
    private(set) var placeOrigin: LocationProvider.Origin = .timeZone
    private var renderer: RoomRenderer!
    private var driver: SceneDriver!
    private let location = LocationProvider()
    private var menu: StatusMenu!
    private var setupWindow: NSWindow?
    private var placeWindow: NSWindow?
    private var hasWeather = false
    private var wakeObserver: NSObjectProtocol?
    private var toggleSource: DispatchSourceSignal?
    private let agents = AgentActivity()

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            renderer = try RoomRenderer()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Window cannot draw on this Mac."
            alert.informativeText = String(describing: error)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        let fallback = LocationProvider.timeZoneCoordinate() ?? Coordinate(latitude: 51.5, longitude: 0)
        let chosen = settings.placeMode == .chosen ? settings.chosenPlace : nil
        let start = chosen ?? fallback
        driver = SceneDriver(place: start, facing: 0, landscapeSeed: settings.landscapeSeed)
        room = RoomController(renderer: renderer, driver: driver)
        music = MusicController(renderer: renderer, driver: driver, room: room)
        setShowTitle(settings.showTitle)
        driver.openingAmount = settings.openingAmount
        placeChanged(start, chosen == nil ? .timeZone : .chosen)

        location.onUpdate = { [weak self] place, origin in
            // A fix that was already in flight must not overwrite a place just chosen on the map.
            guard let self, self.settings.placeMode != .chosen else { return }
            self.placeChanged(place, origin)
        }
        weather.onUpdate = { [weak self] report in
            guard let self else { return }
            // The first report sets the sky at once; later ones ease in, as weather does.
            self.driver.setWeather(report, immediately: !self.hasWeather)
            self.hasWeather = true
        }
        music.onChange = { [weak self] in self?.menu.refresh() }
        music.onAccountLost = { [weak self] in self?.settings.source = .mac }
        // An account whose token is gone cannot answer, so start from the Mac app instead.
        if settings.source == .account && !isAccountConnected { settings.source = .mac }
        music.use(settings.source, clientID: settings.clientID)
        menu = StatusMenu(app: self)
        if let fixed = ProcessInfo.processInfo.environment["WINDOW_OPENING"].flatMap(Double.init) {
            driver.setOpeningOverride(fixed)
        }
        if let saved = settings.savedGrowthState {
            driver.setGrowth(Opening.growth(for: saved), immediately: true)
        }
        // Local logs only. The opening stays put. The wall eases toward the last day of use.
        agents.start { [weak self] tokens in
            DispatchQueue.main.async {
                guard let self else { return }
                let holding = self.settings.savedGrowthState ?? 0
                let state = Opening.state(tokens: tokens, holding: holding)
                let firstLook = self.settings.savedGrowthState == nil
                self.settings.savedGrowthState = state
                self.driver.setGrowth(Opening.growth(for: state), immediately: firstLook || !self.room.isOn)
                Debug.log(String(format: "growth %d from %.0f tokens over the last day", state, tokens))
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                                         queue: .main) { [weak self] _ in
            self?.weather.refreshIfStale()
            self?.music.local.refresh()
        }
        if settings.isOn { turnOn() }
        // With WINDOW_DEBUG set, SIGUSR1 flips the switch, so the on and off states can be checked from a terminal.
        if Debug.enabled {
            signal(SIGUSR1, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                self.room.isOn ? self.turnOff() : self.turnOn()
                Debug.log("switched \(self.room.isOn ? "on" : "off")")
            }
            source.resume()
            toggleSource = source
        }
    }

    func turnOn() {
        room.turnOn()
        if settings.placeMode == .chosen, let chosen = settings.chosenPlace {
            location.stop()
            placeChanged(chosen, .chosen)
        } else {
            location.start()
        }
        weather.start()
        music.start()
        settings.isOn = true
        menu.refresh()
    }

    /// Closes the windows and stops drawing, asking, and listening.
    func turnOff() {
        room.turnOff()
        location.stop()
        weather.stop()
        music.stop()
        settings.isOn = false
        menu.refresh()
    }

    private func placeChanged(_ newPlace: Coordinate, _ origin: LocationProvider.Origin) {
        place = newPlace
        placeOrigin = origin
        driver.place = newPlace
        driver.facing = facingDegrees * .pi / 180
        weather.setPlace(newPlace)
    }

    var automaticFacing: Double {
        WindowDefaults.facingDegrees(latitude: place?.latitude ?? 0)
    }

    private var facingDegrees: Double { settings.facing ?? automaticFacing }

    static func compassName(_ degrees: Double) -> String {
        compass[Int((degrees / 45).rounded()) % 8]
    }

    func setFacing(_ degrees: Double?) {
        settings.facing = degrees
        driver.facing = facingDegrees * .pi / 180
        room.setNeedsRoomDraw()
    }

    func setOpeningAmount(_ amount: Double) {
        let clamped = min(max(amount, 0), 1)
        settings.openingAmount = clamped
        driver.openingAmount = clamped
        room.setNeedsRoomDraw()
    }

    func setShowTitle(_ show: Bool) {
        settings.showTitle = show
        driver.showLabel = show
        room.sill.showLabel = show
        room.setNeedsRoomDraw()
    }

    var isAccountConnected: Bool {
        settings.clientID.map { SpotifyAccount(clientID: $0).isConnected } ?? false
    }

    func setSource(_ source: MusicSource) {
        settings.source = source
        music.use(source, clientID: settings.clientID)
        menu.refresh()
    }

    func useThisMac() {
        settings.placeMode = .automatic
        if room.isOn { location.start() }
        menu.refresh()
    }

    func useChosenPlace(_ place: Coordinate) {
        let rounded = place.cityLevel
        settings.chosenPlace = rounded
        settings.placeMode = .chosen
        location.stop()
        placeChanged(rounded, .chosen)
        menu.refresh()
    }

    func showPlacePicker() {
        if let placeWindow, placeWindow.isVisible {
            placeWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let start = settings.chosenPlace ?? place ?? LocationProvider.timeZoneCoordinate() ?? Coordinate(latitude: 51.5, longitude: 0)
        let window = PlacePickerWindow.make(coordinate: start, usePlace: { [weak self] place in
            self?.useChosenPlace(place)
        }, useThisMac: { [weak self] in
            self?.useThisMac()
        })
        placeWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func showSpotifySetup() {
        if let setupWindow, setupWindow.isVisible {
            setupWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = SpotifySetupWindow.make(clientID: settings.clientID ?? "") { [weak self] clientID in
            try await SpotifyAccount(clientID: clientID).connect()
            await self?.accountConnected(clientID)
        }
        setupWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @MainActor private func accountConnected(_ clientID: String) {
        settings.clientID = clientID
        setSource(.account)
    }

    func disconnectAccount() {
        if let clientID = settings.clientID { SpotifyAccount(clientID: clientID).disconnect() }
        setSource(.mac)
    }
}
