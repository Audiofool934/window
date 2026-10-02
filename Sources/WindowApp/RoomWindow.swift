import AppKit
import Metal
import QuartzCore
import WindowCore

/// One per display: above the wallpaper, below the desktop icons, on every Space, and never in the way of a click.
final class RoomWindow: NSWindow {
    let displayID: CGDirectDisplayID

    init(screen: NSScreen) {
        displayID = screen.displayID
        super.init(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        ignoresMouseEvents = true
        isOpaque = true
        backgroundColor = .black
        hasShadow = false
        isReleasedWhenClosed = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        canHide = false
        setFrame(screen.frame, display: false)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    deinit { Debug.log("room window released") }

    /// A borderless window may cover the menu bar; the default would push it below.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Holds the three layers of one display: the room, the glass, and the objects on the sill.
/// Only the glass redraws every frame; the room and the sill redraw when something on them changes.
final class RoomView: NSView {
    let layout: RoomLayout
    let surface: RoomSurface
    let rects: LayerRects
    let showsSleeve: Bool
    let roomLayer = CAMetalLayer()
    let glassLayer = CAMetalLayer()
    let objectsLayer = CAMetalLayer()
    var onFrame: ((RoomView) -> Void)?
    private var link: CADisplayLink?

    // Light through this display's glass, eased: quickly for lighting, slowly for the eye's adaptation.
    var windowLight = SIMD3<Double>(repeating: 0.3)
    var adaptedLuminance: Double?
    var lastSignature: RoomSignature?
    var lastRoomDraw: CFTimeInterval = 0
    var lastFrameTime = CACurrentMediaTime()
    var roomNeedsDraw = true
    var frameCount = 0

    init(frame: NSRect, layout: RoomLayout, renderer: RoomRenderer, showsSleeve: Bool) throws {
        self.layout = layout
        self.showsSleeve = showsSleeve
        surface = try RoomSurface(layout: layout, renderer: renderer)
        rects = layout.layerRects
        super.init(frame: frame)
        let host = CALayer()
        host.backgroundColor = NSColor.black.cgColor
        layer = host
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        for (metal, rect, opaque) in [(roomLayer, rects.room, true), (glassLayer, rects.glass, true), (objectsLayer, rects.objects, false)] {
            metal.device = renderer.device
            metal.pixelFormat = RoomRenderer.pixelFormat
            metal.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            metal.framebufferOnly = true
            metal.isOpaque = opaque
            metal.contentsScale = layout.scale
            // The full-screen room changes rarely, so two drawables are enough and save tens of megabytes on a 5K display.
            metal.maximumDrawableCount = metal === glassLayer ? 3 : 2
            metal.drawableSize = CGSize(width: rect.width, height: rect.height)
            // Layer space starts at the bottom left; the layout starts at the top left.
            let points = rect.points(scale: layout.scale)
            metal.frame = CGRect(x: points.minX, y: frame.height - points.maxY, width: points.width, height: points.height)
            metal.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "frame": NSNull()]
            host.addSublayer(metal)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit { Debug.log("room view released") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        link?.invalidate()
        link = nil
        guard window != nil else { return }
        let link = displayLink(target: self, selector: #selector(step))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 30, preferred: 10)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    @objc private func step(_ link: CADisplayLink) {
        onFrame?(self)
    }

    func setFrameRate(_ fps: Float) {
        guard let link, link.preferredFrameRateRange.preferred != fps else { return }
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(5, fps), maximum: max(24, fps), preferred: fps)
    }

    func stop() {
        link?.invalidate()
        link = nil
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
