import AppKit
import Metal
import simd
import WindowCore

/// Turns the room on and off, keeps one window per display, and draws each frame.
final class RoomController {
    /// How often the view outside is rendered; the glass crossfades in between.
    static let outdoorInterval: CFTimeInterval = 0.5
    /// WINDOW_FPS pins the frame rate, for measuring.
    static let forcedFrameRate = ProcessInfo.processInfo.environment["WINDOW_FPS"].flatMap(Float.init)
    /// WINDOW_SNAPSHOT_FRAME picks which frame the debug snapshot captures.
    static let snapshotFrame = ProcessInfo.processInfo.environment["WINDOW_SNAPSHOT_FRAME"].flatMap(Int.init) ?? 90
    let renderer: RoomRenderer
    let driver: SceneDriver
    var sill = SillState()
    private(set) var isOn = false
    private var windows: [RoomWindow] = []
    private var views: [RoomView] = []
    private var activity: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    /// With WINDOW_DEBUG set, a line a second of what drawing actually costs.
    private let stats: FrameStats? = ProcessInfo.processInfo.environment["WINDOW_DEBUG"] != nil ? FrameStats() : nil

    init(renderer: RoomRenderer, driver: SceneDriver) {
        self.renderer = renderer
        self.driver = driver
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            self?.rebuildIfNeeded()
        }
    }

    func turnOn() {
        guard !isOn else { return }
        isOn = true
        // Drawing continues behind other windows, as the room promises, so keep App Nap away while it is on.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Drawing the window on the desktop")
        build()
    }

    func turnOff() {
        guard isOn else { return }
        isOn = false
        tearDown()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }

    /// Something changed that the room and the sill must show at once.
    func setNeedsRoomDraw() {
        views.forEach { $0.roomNeedsDraw = true }
    }

    private var screenSignature: [String] = []

    private func signature() -> [String] {
        NSScreen.screens.map { "\($0.displayID) \($0.frame) \($0.visibleFrame) \($0.backingScaleFactor)" }
    }

    private func rebuildIfNeeded() {
        guard isOn, signature() != screenSignature else { return }
        tearDown()
        build()
    }

    private func build() {
        screenSignature = signature()
        let primary = NSScreen.screens.first?.displayID
        for screen in NSScreen.screens {
            let frame = screen.frame
            let visible = screen.visibleFrame
            let layout = RoomLayout.make(screenSize: frame.size, scale: screen.backingScaleFactor,
                                         safeTop: frame.maxY - visible.maxY, safeBottom: visible.minY - frame.minY)
            let window = RoomWindow(screen: screen)
            guard let view = try? RoomView(frame: CGRect(origin: .zero, size: frame.size), layout: layout,
                                           renderer: renderer, showsSleeve: screen.displayID == primary) else { continue }
            view.onFrame = { [weak self] view in self?.draw(view) }
            window.contentView = view
            window.orderFront(nil)
            windows.append(window)
            views.append(view)
        }
    }

    private func tearDown() {
        views.forEach { $0.stop() }
        for window in windows {
            window.orderOut(nil)
            // Let go of the view, its layers, and their textures now rather than whenever AppKit releases the window.
            window.contentView = nil
            window.close()
        }
        views.removeAll()
        windows.removeAll()
    }

    private func draw(_ view: RoomView) {
        let now = Date()
        let media = CACurrentMediaTime()
        driver.advance(to: now)
        let dt = min(max(media - view.lastFrameTime, 0), 0.5)
        view.lastFrameTime = media

        // Light through the glass, from the last finished outdoor frame.
        if let measured = view.surface.measuredWindowLight {
            if view.adaptedLuminance == nil {
                view.windowLight = measured
                view.adaptedLuminance = luminance(measured)
            } else {
                view.windowLight += (measured - view.windowLight) * (1 - exp(-dt / 0.12))
                // The eye adapts over seconds, so a lightning flash stays a flash.
                let target = luminance(measured)
                view.adaptedLuminance! += (target - view.adaptedLuminance!) * (1 - exp(-dt / 2.5))
            }
        }
        let inputs = driver.inputs(at: now, windowLight: view.windowLight, adaptedLuminance: view.adaptedLuminance)
        var frame = FrameUniforms.make(layout: view.layout, inputs: inputs)
        guard let buffer = renderer.queue.makeCommandBuffer() else { return }
        // Cloud drifts slowly, so the view outside is rendered a few times a second and the glass crossfades
        // between the last two renders. Lightning needs every frame while it lasts.
        let flashing = inputs.flash > 0.005
        var renderedOutdoor = false
        if view.frameCount == 0 {
            renderedOutdoor = true
            renderer.encodeSkyTable(frame, into: buffer)
            renderer.encodeOutdoor(frame, surface: view.surface, time: media - Self.outdoorInterval, into: buffer)
            renderer.encodeOutdoor(frame, surface: view.surface, time: media, into: buffer)
        } else if flashing || media - view.surface.outdoorTime >= Self.outdoorInterval {
            renderedOutdoor = true
            renderer.encodeSkyTable(frame, into: buffer)
            renderer.encodeOutdoor(frame, surface: view.surface, time: media, into: buffer)
        }
        let blend = flashing ? 1 : min(max((media - view.surface.outdoorTime) / Self.outdoorInterval, 0), 1)
        frame.timing.x = Float(blend)
        if let glass = view.glassLayer.nextDrawable() {
            renderer.encodeGlass(frame, surface: view.surface, target: glass.texture, origin: view.rects.glass.origin, into: buffer)
            buffer.present(glass)
        }
        // The room and the sill change slowly. Redraw them only when their light visibly changes or something on them moves,
        // so a steady day or night costs the window server almost nothing.
        let signature = RoomSignature(frame: frame)
        let changed = !(view.lastSignature?.isClose(to: signature) ?? false)
        let forced = view.roomNeedsDraw || view.frameCount < 3 || inputs.flash > 0.005
        // The full-screen room follows slow changes, such as the lamp easing to a new colour, at most twelve times a second.
        let drawRoom = forced || (changed && media - view.lastRoomDraw >= 1.0 / 12)
        // The sill is small, so it follows the sleeve's movement every frame.
        let drawObjects = drawRoom || driver.isSillMoving
        if drawRoom || drawObjects {
            var sill = self.sill
            sill.pose = driver.sillPose
            sill.showsSleeve = view.showsSleeve
            if drawRoom, let room = view.roomLayer.nextDrawable() {
                renderer.encodeRoom(frame, target: room.texture, origin: view.rects.room.origin, into: buffer)
                buffer.present(room)
                view.lastSignature = signature
                view.lastRoomDraw = media
                view.roomNeedsDraw = false
                stats?.roomDraws += 1
            }
            if let objects = view.objectsLayer.nextDrawable() {
                renderer.encodeObjects(frame, surface: view.surface, sill: sill, target: objects.texture,
                                       origin: view.rects.objects.origin, into: buffer)
                buffer.present(objects)
            }
        }
        if let stats {
            if renderedOutdoor { stats.outdoorRenders += 1 }
            stats.frames += 1
            let withOutdoor = renderedOutdoor
            buffer.addCompletedHandler { done in stats.addGPU(done.gpuEndTime - done.gpuStartTime, outdoor: withOutdoor) }
            stats.reportIfDue(fps: driver.needsFastFrames ? 24 : 10)
        }
        buffer.commit()
        view.frameCount += 1
        if view.frameCount == Self.snapshotFrame, let directory = ProcessInfo.processInfo.environment["WINDOW_SNAPSHOT"] {
            var sill = self.sill
            sill.pose = driver.sillPose
            sill.showsSleeve = view.showsSleeve
            DebugSnapshot.write(view: view, frame: frame, sill: sill, renderer: renderer,
                                to: URL(fileURLWithPath: directory).appendingPathComponent("display-\(view.window.map { ($0 as? RoomWindow)?.displayID ?? 0 } ?? 0).png"))
        }
        // Falling rain and snow need film rate; drifting cloud looks the same at ten frames a second.
        // Low Power Mode halves both.
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        view.setFrameRate(Self.forcedFrameRate ?? (driver.needsFastFrames ? 24 : 10) / (lowPower ? 2 : 1))
    }

    private func luminance(_ c: SIMD3<Double>) -> Double {
        0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
    }
}

/// The few numbers that decide how the room and the sill look, to tell when they need drawing again.
struct RoomSignature {
    var exposure: SIMD2<Float>
    var light: SIMD4<Float>
    var lamp: SIMD4<Float>

    init(frame: FrameUniforms) {
        exposure = SIMD2(frame.exposure.x, frame.exposure.y)
        light = frame.windowLight
        lamp = frame.lampColor
    }

    func isClose(to other: RoomSignature) -> Bool {
        func near(_ a: Float, _ b: Float) -> Bool { abs(a - b) <= max(abs(a), abs(b)) * 0.012 + 1e-6 }
        return near(exposure.x, other.exposure.x) && near(exposure.y, other.exposure.y)
            && near(light.x, other.light.x) && near(light.y, other.light.y) && near(light.z, other.light.z)
            && simd_distance(lamp, other.lamp) < 0.003
    }
}

/// Counts frames and GPU time, printed once a second when WINDOW_DEBUG is set.
final class FrameStats {
    var frames = 0
    var outdoorRenders = 0
    var roomDraws = 0
    private var gpu = 0.0
    private var glassOnly = 0.0
    private var glassOnlyFrames = 0
    private let lock = NSLock()
    private var since = CACurrentMediaTime()

    func addGPU(_ seconds: Double, outdoor: Bool) {
        lock.lock()
        gpu += seconds
        if !outdoor {
            glassOnly += seconds
            glassOnlyFrames += 1
        }
        lock.unlock()
    }

    func reportIfDue(fps: Int) {
        let now = CACurrentMediaTime()
        guard now - since >= 1 else { return }
        lock.lock()
        let busy = gpu
        let glassAverage = glassOnlyFrames > 0 ? glassOnly / Double(glassOnlyFrames) : 0
        gpu = 0
        glassOnly = 0
        glassOnlyFrames = 0
        lock.unlock()
        let line = String(format: "frames %d  outdoor %d  room %d  gpu %.1f ms/s  glass-only frame %.2f ms  target %d fps",
                          frames, outdoorRenders, roomDraws, busy * 1000 / (now - since), glassAverage * 1000, fps)
        FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
        frames = 0
        outdoorRenders = 0
        roomDraws = 0
        since = now
    }
}
