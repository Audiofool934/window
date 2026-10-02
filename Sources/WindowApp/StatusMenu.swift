import AppKit
import ServiceManagement
import WindowCore

/// The menu bar item: one switch, a glance at what is playing and what is outside, and a few settings.
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private unowned let app: AppDelegate

    init(app: AppDelegate) {
        self.app = app
        super.init()
        item.button?.image = MenuBarIcon.make()
        item.button?.setAccessibilityLabel("Window")
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        refresh()
    }

    func refresh() {
        item.button?.appearsDisabled = !app.room.isOn
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let on = app.room.isOn
        menu.addItem(action(on ? "Turn Off" : "Turn On", #selector(toggle)))
        menu.addItem(.separator())

        if let playing = app.music.nowPlaying, playing.isPlaying {
            menu.addItem(note("\(playing.title) · \(playing.artist)"))
        } else {
            menu.addItem(note("Nothing playing"))
        }
        if let problem = app.music.accountProblem { menu.addItem(note(problem)) }
        if let weather = app.weather.latest {
            menu.addItem(note("Outside: \(weather.summary)"))
        }
        if let place = app.place {
            let lat = String(format: "%.1f°%@", abs(place.latitude), place.latitude >= 0 ? "N" : "S")
            let lon = String(format: "%.1f°%@", abs(place.longitude), place.longitude >= 0 ? "E" : "W")
            let origin = app.placeOrigin == .timeZone ? " (from time zone)" : ""
            menu.addItem(note("\(lat) \(lon)\(origin)"))
        }
        menu.addItem(.separator())

        let title = action("Show Title", #selector(toggleTitle))
        title.state = app.settings.showTitle ? .on : .off
        menu.addItem(title)

        let faces = NSMenuItem(title: "Window Faces", action: nil, keyEquivalent: "")
        let facesMenu = NSMenu()
        let automatic = action("Automatically (\(AppDelegate.compassName(app.automaticFacing)))", #selector(setFacing(_:)))
        automatic.representedObject = nil
        automatic.state = app.settings.facing == nil ? .on : .off
        facesMenu.addItem(automatic)
        facesMenu.addItem(.separator())
        for (index, name) in AppDelegate.compass.enumerated() {
            let degrees = Double(index) * 45
            let choice = action(name, #selector(setFacing(_:)))
            choice.representedObject = degrees
            choice.state = app.settings.facing == degrees ? .on : .off
            facesMenu.addItem(choice)
        }
        faces.submenu = facesMenu
        menu.addItem(faces)

        let music = NSMenuItem(title: "Music", action: nil, keyEquivalent: "")
        let musicMenu = NSMenu()
        let mac = action("Spotify on This Mac", #selector(useMac))
        mac.state = app.music.source == .mac ? .on : .off
        musicMenu.addItem(mac)
        let account = action("Spotify Account, Any Device", #selector(useAccount))
        account.state = app.music.source == .account ? .on : .off
        account.isEnabled = app.isAccountConnected
        musicMenu.addItem(account)
        musicMenu.addItem(.separator())
        if app.isAccountConnected {
            musicMenu.addItem(action("Disconnect Spotify Account", #selector(disconnect)))
        } else {
            musicMenu.addItem(action("Connect Spotify Account…", #selector(connect)))
        }
        music.submenu = musicMenu
        menu.addItem(music)
        menu.addItem(.separator())

        let login = action("Open at Login", #selector(toggleLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        let quit = action("Quit Window", #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    private func note(_ text: String) -> NSMenuItem {
        let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc private func toggle() { app.room.isOn ? app.turnOff() : app.turnOn() }
    @objc private func toggleTitle() { app.setShowTitle(!app.settings.showTitle) }
    @objc private func setFacing(_ sender: NSMenuItem) { app.setFacing(sender.representedObject as? Double) }
    @objc private func useMac() { app.setSource(.mac) }
    @objc private func useAccount() { app.setSource(.account) }
    @objc private func connect() { app.showSpotifySetup() }
    @objc private func disconnect() { app.disconnectAccount() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Window could not change its login item."
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}

enum MenuBarIcon {
    /// A small window with a sill, as a template so it follows the menu bar's appearance.
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let frame = NSBezierPath(roundedRect: NSRect(x: 3.5, y: 4.6, width: 11, height: 10.6), xRadius: 1.1, yRadius: 1.1)
            frame.lineWidth = 1.4
            frame.stroke()
            let bars = NSBezierPath()
            bars.move(to: NSPoint(x: 9, y: 4.6))
            bars.line(to: NSPoint(x: 9, y: 15.2))
            bars.move(to: NSPoint(x: 3.5, y: 11.6))
            bars.line(to: NSPoint(x: 14.5, y: 11.6))
            bars.lineWidth = 1.1
            bars.stroke()
            let sill = NSBezierPath()
            sill.move(to: NSPoint(x: 2, y: 2.9))
            sill.line(to: NSPoint(x: 16, y: 2.9))
            sill.lineWidth = 1.4
            sill.lineCapStyle = .round
            sill.stroke()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Window"
        return image
    }
}
