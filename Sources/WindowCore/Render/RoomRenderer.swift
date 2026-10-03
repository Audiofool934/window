import AppKit
import CoreGraphics
import CoreText
import Foundation
import Metal
import simd

public enum RenderError: Error, CustomStringConvertible {
    case noDevice
    case shaderMissing
    case resource(String)

    public var description: String {
        switch self {
        case .noDevice: return "No Metal device is available."
        case .shaderMissing: return "Room.metal was not found in the app or package resources."
        case .resource(let what): return "Could not create \(what)."
        }
    }
}

/// Vertex for everything on the sill. Mirrors `ObjectVertex` in Room.metal.
struct ObjectVertex {
    var position: SIMD4<Float>
    var normal: SIMD4<Float>
    var uv: SIMD4<Float>
}

/// What the sill shows this frame.
public struct SillState: Equatable, Sendable {
    /// 0 standing against the glass, 1 face down.
    public var pose: Double = 1
    public var title: String = ""
    public var artist: String = ""
    public var showLabel: Bool = true
    /// Only one display holds the record; the others show the window.
    public var showsSleeve: Bool = true

    public init(pose: Double = 1, title: String = "", artist: String = "", showLabel: Bool = true, showsSleeve: Bool = true) {
        self.pose = pose
        self.title = title
        self.artist = artist
        self.showLabel = showLabel
        self.showsSleeve = showsSleeve
    }
}

/// Draws the room. One renderer is shared by every display; each display owns a `RoomSurface`.
public final class RoomRenderer {
    public let device: MTLDevice
    public let queue: MTLCommandQueue
    public static let pixelFormat = MTLPixelFormat.bgra8Unorm
    static let objectSamples = 4

    private let skyTablePipeline: MTLRenderPipelineState
    private let outdoorPipeline: MTLRenderPipelineState
    private let glassPipeline: MTLRenderPipelineState
    private let roomPipeline: MTLRenderPipelineState
    private let sleevePipeline: MTLRenderPipelineState
    private let shadowPipeline: MTLRenderPipelineState
    private let labelPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private let skyTable: MTLTexture

    private(set) var cover: MTLTexture
    private(set) var previousCover: MTLTexture
    private let blank: MTLTexture

    public init(device: MTLDevice? = nil) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else { throw RenderError.noDevice }
        guard let queue = device.makeCommandQueue() else { throw RenderError.resource("a command queue") }
        self.device = device
        self.queue = queue
        let library = try device.makeLibrary(source: try Self.shaderSource(), options: MTLCompileOptions())

        func pipeline(_ vertex: String, _ fragment: String, format: MTLPixelFormat = RoomRenderer.pixelFormat,
                      samples: Int = 1, blended: Bool = false) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = format
            d.rasterSampleCount = samples
            if blended {
                // Everything on the sill is premultiplied, so glare can add light where alpha is zero.
                let c = d.colorAttachments[0]!
                c.isBlendingEnabled = true
                c.sourceRGBBlendFactor = .one
                c.sourceAlphaBlendFactor = .one
                c.destinationRGBBlendFactor = .oneMinusSourceAlpha
                c.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: d)
        }
        skyTablePipeline = try pipeline("fullscreenVertex", "skyTableFragment", format: .rgba16Float)
        outdoorPipeline = try pipeline("fullscreenVertex", "outdoorFragment", format: .rgba16Float)
        glassPipeline = try pipeline("fullscreenVertex", "glassFragment")
        roomPipeline = try pipeline("fullscreenVertex", "roomFragment")
        sleevePipeline = try pipeline("objectVertex", "sleeveFragment", samples: Self.objectSamples, blended: true)
        shadowPipeline = try pipeline("objectVertex", "shadowFragment", samples: Self.objectSamples, blended: true)
        labelPipeline = try pipeline("objectVertex", "labelFragment", samples: Self.objectSamples, blended: true)
        compositePipeline = try pipeline("compositeVertex", "compositeFragment", blended: true)

        let table = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: 256, height: 128, mipmapped: false)
        table.usage = [.renderTarget, .shaderRead]
        table.storageMode = .private
        guard let skyTable = device.makeTexture(descriptor: table) else { throw RenderError.resource("the sky table") }
        self.skyTable = skyTable

        // A plain grey card until a cover arrives.
        let blankDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: 1, height: 1, mipmapped: false)
        guard let blank = device.makeTexture(descriptor: blankDescriptor) else { throw RenderError.resource("a blank texture") }
        var grey: [UInt8] = [150, 146, 138, 255]
        blank.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &grey, bytesPerRow: 4)
        self.blank = blank
        cover = blank
        previousCover = blank
    }

    static func shaderSource() throws -> String {
        if let url = Bundle.main.url(forResource: "Room", withExtension: "metal") {
            return try String(contentsOf: url, encoding: .utf8)
        }
        if let url = Bundle.module.url(forResource: "Room", withExtension: "metal") {
            return try String(contentsOf: url, encoding: .utf8)
        }
        throw RenderError.shaderMissing
    }

    // MARK: Covers

    /// Swaps in a new cover; the old one stays for the crossfade.
    public func setCover(_ image: CGImage?) {
        previousCover = cover
        if let image, let texture = try? makeCoverTexture(image) {
            cover = texture
        } else {
            cover = blank
        }
    }

    private func makeCoverTexture(_ image: CGImage) throws -> MTLTexture {
        let size = 512
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw RenderError.resource("a cover context")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm_srgb, width: size, height: size, mipmapped: true)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor), let data = context.data else {
            throw RenderError.resource("a cover texture")
        }
        texture.replace(region: MTLRegionMake2D(0, 0, size, size), mipmapLevel: 0, withBytes: data, bytesPerRow: size * 4)
        if let buffer = queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder() {
            blit.generateMipmaps(for: texture)
            blit.endEncoding()
            buffer.commit()
        }
        return texture
    }

    // MARK: Passes

    /// The scattering table depends only on where the sun and moon are, so it is cheap to redo every frame.
    public func encodeSkyTable(_ frame: FrameUniforms, into buffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = skyTable
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var f = frame
        encoder.setRenderPipelineState(skyTablePipeline)
        encoder.setFragmentBytes(&f, length: MemoryLayout<FrameUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// The view outside at reduced resolution, plus its mean for lighting the room.
    /// `time` is the caller's clock, used to crossfade from the previous render.
    public func encodeOutdoor(_ frame: FrameUniforms, surface: RoomSurface, time: Double = 0, into buffer: MTLCommandBuffer) {
        let (texture, readback) = surface.advanceOutdoor(at: time)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var f = frame
        encoder.setRenderPipelineState(outdoorPipeline)
        encoder.setFragmentBytes(&f, length: MemoryLayout<FrameUniforms>.stride, index: 0)
        encoder.setFragmentTexture(skyTable, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        guard let blit = buffer.makeBlitCommandEncoder() else { return }
        blit.generateMipmaps(for: texture)
        let last = texture.mipmapLevelCount - 1
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: last, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                  sourceSize: MTLSize(width: 1, height: 1, depth: 1), to: readback, destinationOffset: 0,
                  destinationBytesPerRow: 8, destinationBytesPerImage: 8)
        blit.endEncoding()
        buffer.addCompletedHandler { [weak surface] _ in surface?.takeReadback(readback) }
    }

    public func encodeGlass(_ frame: FrameUniforms, surface: RoomSurface, target: MTLTexture, origin: SIMD2<Float>,
                            scissor: MTLScissorRect? = nil, into buffer: MTLCommandBuffer) {
        encodeFullscreen(glassPipeline, frame: frame, target: target, origin: origin,
                         textures: [surface.latestOutdoor, surface.previousOutdoor],
                         clear: scissor != nil, scissor: scissor, into: buffer)
    }

    public func encodeRoom(_ frame: FrameUniforms, target: MTLTexture, origin: SIMD2<Float>, into buffer: MTLCommandBuffer) {
        encodeFullscreen(roomPipeline, frame: frame, target: target, origin: origin, textures: [], into: buffer)
    }

    private func encodeFullscreen(_ pipeline: MTLRenderPipelineState, frame: FrameUniforms, target: MTLTexture, origin: SIMD2<Float>,
                                  textures: [MTLTexture], clear: Bool = false, scissor: MTLScissorRect? = nil,
                                  into buffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = clear ? .clear : .dontCare
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var f = frame
        f.layer = SIMD4(origin.x, origin.y, Float(target.width), Float(target.height))
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&f, length: MemoryLayout<FrameUniforms>.stride, index: 0)
        for (i, texture) in textures.enumerated() { encoder.setFragmentTexture(texture, index: i) }
        if let scissor {
            var rect = scissor
            if rect.x < 0 { rect.width += rect.x; rect.x = 0 }
            if rect.y < 0 { rect.height += rect.y; rect.y = 0 }
            if rect.x + rect.width > target.width { rect.width = target.width - rect.x }
            if rect.y + rect.height > target.height { rect.height = target.height - rect.y }
            if rect.width > 0, rect.height > 0 {
                encoder.setScissorRect(rect)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            }
        } else {
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
        encoder.endEncoding()
    }

    /// The sleeve, its shadow, and the label, over a transparent layer. A sleeve that has laid down is not drawn.
    public func encodeObjects(_ frame: FrameUniforms, surface: RoomSurface, sill: SillState, target: MTLTexture,
                              origin: SIMD2<Float>, into buffer: MTLCommandBuffer) {
        guard let multisample = surface.multisampleTarget(width: target.width, height: target.height) else { return }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = multisample
        pass.colorAttachments[0].resolveTexture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .multisampleResolve
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var f = frame
        f.layer = SIMD4(origin.x, origin.y, Float(target.width), Float(target.height))
        // The sill, lamp, and sleeve follow the opening so a centred window keeps its ledge.
        let layout = surface.layout.following(openingScale: Double(frame.timing.w))

        func draw(_ pipeline: MTLRenderPipelineState, _ vertices: [ObjectVertex], textures: [MTLTexture] = []) {
            guard !vertices.isEmpty else { return }
            encoder.setRenderPipelineState(pipeline)
            vertices.withUnsafeBytes { bytes in
                if bytes.count <= 4096 {
                    encoder.setVertexBytes(bytes.baseAddress!, length: bytes.count, index: 0)
                } else if let b = device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count) {
                    encoder.setVertexBuffer(b, offset: 0, index: 0)
                }
            }
            encoder.setVertexBytes(&f, length: MemoryLayout<FrameUniforms>.stride, index: 1)
            encoder.setFragmentBytes(&f, length: MemoryLayout<FrameUniforms>.stride, index: 0)
            for (i, t) in textures.enumerated() { encoder.setFragmentTexture(t, index: i) }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        }

        draw(shadowPipeline, SillGeometry.shadows(layout: layout, pose: sill.pose, sleeve: sill.showsSleeve))
        if sill.showsSleeve, SillGeometry.sleevePresence(sill.pose) > 0.02 {
            draw(sleevePipeline, SillGeometry.sleeve(layout: layout, pose: sill.pose), textures: [cover, previousCover])
        }
        if sill.showsSleeve, sill.showLabel, frame.misc.z > 0.001, let label = surface.label(title: sill.title, artist: sill.artist, device: device) {
            draw(labelPipeline, SillGeometry.labelQuad(layout: layout, size: label.size, ink: Float(surface.labelInk(frame: frame))),
                 textures: [label.texture])
        }
        encoder.endEncoding()
    }
}

extension RoomRenderer {
    /// Places finished layers onto one texture with premultiplied alpha, the way Core Animation stacks them.
    public func encodeComposite(_ layers: [(texture: MTLTexture, rect: PixelRect)], into target: MTLTexture, buffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(compositePipeline)
        let w = Float(target.width), h = Float(target.height)
        for layer in layers {
            let r = layer.rect
            var ndc = SIMD4<Float>(Float(r.x) / w * 2 - 1, 1 - Float(r.y + r.height) / h * 2,
                                   Float(r.x + r.width) / w * 2 - 1, 1 - Float(r.y) / h * 2)
            encoder.setVertexBytes(&ndc, length: 16, index: 0)
            encoder.setFragmentTexture(layer.texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
    }
}

/// Per-display resources: the low-resolution view outside, the label, and the measured window light.
public final class RoomSurface {
    public let layout: RoomLayout
    /// The two most recent renders of the view outside; the glass crossfades between them.
    private let outdoorTextures: [MTLTexture]
    private let readbacks: [MTLBuffer]
    private var latestIndex = 0
    /// When the latest outdoor render was made, in the caller's clock.
    public private(set) var outdoorTime: Double = -.infinity
    private let lock = NSLock()
    private var measured: SIMD3<Double>?
    private var multisample: MTLTexture?
    private var labelCache: (key: String, texture: MTLTexture, size: CGSize)?
    private let device: MTLDevice

    public init(layout: RoomLayout, glass: CGRect? = nil, renderer: RoomRenderer) throws {
        self.layout = layout
        device = renderer.device
        let glass = (glass?.isNull == false && (glass?.width ?? 0) > 1) ? glass! : layout.glassRect
        // Half resolution is plenty for sky and cloud; stars, rain, and frames are drawn at full size on top.
        let width = max(Int((glass.width * layout.scale / 2).rounded()), 8)
        let height = max(Int((glass.height * layout.scale / 2).rounded()), 8)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: true)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        var textures: [MTLTexture] = []
        var buffers: [MTLBuffer] = []
        for _ in 0..<2 {
            guard let texture = renderer.device.makeTexture(descriptor: descriptor),
                  let buffer = renderer.device.makeBuffer(length: 8, options: .storageModeShared) else {
                throw RenderError.resource("the outdoor texture")
            }
            textures.append(texture)
            buffers.append(buffer)
        }
        outdoorTextures = textures
        readbacks = buffers
    }

    var latestOutdoor: MTLTexture { outdoorTextures[latestIndex] }
    var previousOutdoor: MTLTexture { outdoorTextures[1 - latestIndex] }

    /// Picks the older texture to render the next view into, and makes it the latest.
    func advanceOutdoor(at time: Double) -> (texture: MTLTexture, readback: MTLBuffer) {
        latestIndex = 1 - latestIndex
        outdoorTime = time
        return (outdoorTextures[latestIndex], readbacks[latestIndex])
    }

    /// Mean radiance of the last outdoor frame, once one has finished.
    public var measuredWindowLight: SIMD3<Double>? {
        lock.lock(); defer { lock.unlock() }
        return measured
    }

    func takeReadback(_ readback: MTLBuffer) {
        let halves = readback.contents().bindMemory(to: Float16.self, capacity: 4)
        let value = SIMD3(Double(halves[0]), Double(halves[1]), Double(halves[2]))
        guard value.x.isFinite, value.y.isFinite, value.z.isFinite else { return }
        lock.lock()
        measured = value
        lock.unlock()
    }

    func multisampleTarget(width: Int, height: Int) -> MTLTexture? {
        if let multisample, multisample.width == width, multisample.height == height { return multisample }
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: RoomRenderer.pixelFormat, width: width, height: height, mipmapped: false)
        d.textureType = .type2DMultisample
        d.sampleCount = RoomRenderer.objectSamples
        d.usage = [.renderTarget]
        d.storageMode = .memoryless
        multisample = device.makeTexture(descriptor: d)
        return multisample
    }

    /// The label is set once per title in the room's own small type.
    func label(title: String, artist: String, device: MTLDevice) -> (texture: MTLTexture, size: CGSize)? {
        guard !title.isEmpty || !artist.isEmpty else { return nil }
        let key = "\(title)\u{1F}\(artist)\u{1F}\(layout.scale)"
        if let cache = labelCache, cache.key == key { return (cache.texture, cache.size) }
        guard let made = LabelTypesetter.render(title: title, artist: artist, scale: layout.scale, device: device) else { return nil }
        labelCache = (key, made.texture, made.size)
        return made
    }

    /// Ink that reads against the wall under the sill: dark on a lit wall, pale on a dark one.
    /// The wall there is lit by daylight bounced around the room, and by the same even fill the shader uses at night.
    func labelInk(frame: FrameUniforms) -> Double {
        // Luminance of roomFill's colour, times the 0.18 in Room.metal. Keep the two together.
        let fill = 0.964 * Double(frame.exposure.w) * 0.18
        let bounce = Double(frame.windowLight.w) * 0.16 + fill
        let wall = Lighting.displayValue(bounce * 0.6 * 0.7, exposure: Double(frame.exposure.y))
        return wall > 0.42 ? max(wall - 0.36, 0.05) : min(wall + 0.42, 0.74)
    }
}

/// Typesets the title and artist into a coverage mask.
enum LabelTypesetter {
    static func render(title: String, artist: String, scale: Double, device: MTLDevice) -> (texture: MTLTexture, size: CGSize)? {
        let titleFont = CTFontCreateWithFontDescriptor(serifDescriptor(size: 11.5), 11.5, nil)
        let artistFont = CTFontCreateUIFontForLanguage(.system, 8.5, nil) ?? CTFontCreateWithName("Helvetica" as CFString, 8.5, nil)
        let titleLine = CTLineCreateWithAttributedString(NSAttributedString(string: title, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: titleFont,
            kCTForegroundColorFromContextAttributeName as NSAttributedString.Key: true
        ]))
        let artistLine = CTLineCreateWithAttributedString(NSAttributedString(string: artist.uppercased(), attributes: [
            kCTFontAttributeName as NSAttributedString.Key: artistFont,
            kCTKernAttributeName as NSAttributedString.Key: 1.1,
            kCTForegroundColorFromContextAttributeName as NSAttributedString.Key: true
        ]))
        let maxWidth = 260.0
        let titleWidth = min(CTLineGetTypographicBounds(titleLine, nil, nil, nil), maxWidth)
        let artistWidth = min(CTLineGetTypographicBounds(artistLine, nil, nil, nil), maxWidth)
        let width = ceil(max(titleWidth, artistWidth) + 4)
        let height = 30.0
        let pw = Int(width * scale), ph = Int(height * scale)
        guard pw > 0, ph > 0,
              let context = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: pw,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        context.setFillColor(gray: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: pw, height: ph))
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(gray: 1, alpha: 1)
        context.setShouldSmoothFonts(false)
        func draw(_ line: CTLine, lineWidth: Double, baseline: Double) {
            let truncated = lineWidth >= maxWidth
                ? CTLineCreateTruncatedLine(line, maxWidth, .end, CTLineCreateWithAttributedString(NSAttributedString(string: "…"))) ?? line
                : line
            context.textPosition = CGPoint(x: (width - lineWidth) / 2, y: baseline)
            CTLineDraw(truncated, context)
        }
        draw(titleLine, lineWidth: titleWidth, baseline: 16.5)
        draw(artistLine, lineWidth: artistWidth, baseline: 3.5)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: pw, height: ph, mipmapped: false)
        descriptor.usage = [.shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor), let data = context.data else { return nil }
        // Bitmap memory runs top row first, which is the order the quad samples it in.
        texture.replace(region: MTLRegionMake2D(0, 0, pw, ph), mipmapLevel: 0, withBytes: data, bytesPerRow: pw)
        return (texture, CGSize(width: width, height: height))
    }

    /// New York, the system serif.
    static func serifDescriptor(size: CGFloat) -> CTFontDescriptor {
        let system = NSFont.systemFont(ofSize: size).fontDescriptor
        return (system.withDesign(.serif) ?? system) as CTFontDescriptor
    }
}

/// Geometry for the objects on the sill, built on the CPU in world or screen coordinates.
enum SillGeometry {
    static func sleeveTransform(layout: RoomLayout, pose: Double) -> (SIMD3<Double>) -> SIMD3<Double> {
        let p = min(max(pose, 0), 1)
        let theta = -layout.sleeveLean + (Double.pi / 2 + layout.sleeveLean) * p
        let baseZ = layout.sleeveBaseZ + (layout.glassDepth - 0.012 - layout.sleeveBaseZ) * p
        let base = SIMD3(layout.sleeveCentreX, layout.openingBottom, baseZ)
        let yaw = layout.sleeveYaw
        return { local in
            // Tip about the bottom edge, then turn toward the room.
            let y = local.y * cos(theta) + local.z * sin(theta)
            let z = -local.y * sin(theta) + local.z * cos(theta)
            let x = local.x
            let rx = x * cos(yaw) - z * sin(yaw)
            let rz = x * sin(yaw) + z * cos(yaw)
            return base + SIMD3(rx, y, rz)
        }
    }

    /// 1 while the sleeve stands, falling to 0 as it lies down. The same curve as `sleevePresence` in Room.metal.
    static func sleevePresence(_ pose: Double) -> Double {
        let p = min(max(pose, 0), 1)
        let t = min(max(p / 0.40, 0), 1)
        return 1 - t * t * (3 - 2 * t)
    }

    static func sleeve(layout: RoomLayout, pose: Double) -> [ObjectVertex] {
        guard sleevePresence(pose) > 0.02 else { return [] }
        let w = layout.sleeveSize
        let d = layout.sleeveThickness
        let t = sleeveTransform(layout: layout, pose: pose)
        let h = w / 2
        // Lifted a hair off the sill so the face-down card does not fight with it.
        let lift = SIMD3<Double>(0, 0.0012, 0)
        func corner(_ x: Double, _ y: Double, _ z: Double) -> SIMD3<Double> { t(SIMD3(x, y, z)) + lift }
        struct Face { var corners: [SIMD3<Double>]; var uvs: [SIMD2<Double>]; var kind: Float }
        let faces = [
            // Front, the printed cover, facing the room while it stands.
            Face(corners: [corner(-h, w, 0), corner(h, w, 0), corner(h, 0, 0), corner(-h, 0, 0)],
                 uvs: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)], kind: 0),
            Face(corners: [corner(h, w, d), corner(-h, w, d), corner(-h, 0, d), corner(h, 0, d)],
                 uvs: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)], kind: 1),
            Face(corners: [corner(-h, w, d), corner(-h, w, 0), corner(-h, 0, 0), corner(-h, 0, d)],
                 uvs: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)], kind: 2),
            Face(corners: [corner(h, w, 0), corner(h, w, d), corner(h, 0, d), corner(h, 0, 0)],
                 uvs: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)], kind: 2),
            Face(corners: [corner(-h, w, d), corner(h, w, d), corner(h, w, 0), corner(-h, w, 0)],
                 uvs: [SIMD2(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)], kind: 2)
        ]
        var vertices: [ObjectVertex] = []
        for face in faces {
            let c = face.corners
            let normal = simd_normalize(simd_cross(c[1] - c[0], c[3] - c[0]))
            let centre = (c[0] + c[1] + c[2] + c[3]) / 4
            // Only faces turned toward the eye, which sits at the origin.
            guard simd_dot(normal, centre) < 0 else { continue }
            for i in [0, 1, 2, 0, 2, 3] {
                vertices.append(ObjectVertex(
                    position: SIMD4(Float(c[i].x), Float(c[i].y), Float(c[i].z), 0),
                    normal: SIMD4(Float(normal.x), Float(normal.y), Float(normal.z), face.kind),
                    uv: SIMD4(Float(face.uvs[i].x), Float(face.uvs[i].y), 0, 0)))
            }
        }
        return vertices
    }

    /// A soft contact shadow under the sleeve while it is up. A laid-down sleeve leaves none.
    static func shadows(layout: RoomLayout, pose: Double, sleeve: Bool = true) -> [ObjectVertex] {
        var vertices: [ObjectVertex] = []
        let y = layout.openingBottom + 0.0006
        func quad(centre: SIMD2<Double>, half: SIMD2<Double>, margin: Double, yaw: Double, strength: Double) {
            let outer = half + SIMD2(repeating: margin)
            let solid = SIMD2(half.x / outer.x, half.y / outer.y)
            let corners: [SIMD2<Double>] = [SIMD2(-1, -1), SIMD2(1, -1), SIMD2(1, 1), SIMD2(-1, 1)]
            func world(_ c: SIMD2<Double>) -> SIMD3<Double> {
                let lx = c.x * outer.x, lz = c.y * outer.y
                return SIMD3(centre.x + lx * cos(yaw) - lz * sin(yaw), y, centre.y + lx * sin(yaw) + lz * cos(yaw))
            }
            for i in [0, 1, 2, 0, 2, 3] {
                let p = world(corners[i])
                vertices.append(ObjectVertex(
                    position: SIMD4(Float(p.x), Float(p.y), Float(p.z), 0),
                    normal: SIMD4(Float(strength), 0, 0, 0),
                    uv: SIMD4(Float(corners[i].x), Float(corners[i].y), Float(solid.x), Float(solid.y))))
            }
        }
        if sleeve {
            let p = min(max(pose, 0), 1)
            let presence = sleevePresence(p)
            if presence > 0.02 {
                let t = sleeveTransform(layout: layout, pose: pose)
                let a = t(SIMD3(0, 0, 0)), b = t(SIMD3(0, 0.001 + layout.sleeveSize * p, 0))
                let centre = (a + b) / 2
                let depthHalf = layout.sleeveThickness + abs(b.z - a.z) / 2
                quad(centre: SIMD2(centre.x, centre.z), half: SIMD2(layout.sleeveSize / 2, depthHalf), margin: 0.018 + 0.012 * p,
                     yaw: layout.sleeveYaw, strength: (0.5 - 0.15 * p) * presence)
            }
        }
        return vertices
    }

    static func screenQuad(_ rect: CGRect, scale: Double, extra: SIMD2<Float> = .zero, normal: SIMD4<Float> = .zero) -> [ObjectVertex] {
        let x0 = Float(rect.minX * scale), y0 = Float(rect.minY * scale)
        let x1 = Float(rect.maxX * scale), y1 = Float(rect.maxY * scale)
        let corners: [(Float, Float, Float, Float)] = [(x0, y0, 0, 0), (x1, y0, 1, 0), (x1, y1, 1, 1), (x0, y1, 0, 1)]
        return [0, 1, 2, 0, 2, 3].map { i in
            let c = corners[i]
            return ObjectVertex(position: SIMD4(c.0, c.1, 0, 1), normal: normal, uv: SIMD4(c.2, c.3, extra.x, extra.y))
        }
    }

    static func labelQuad(layout: RoomLayout, size: CGSize, ink: Float) -> [ObjectVertex] {
        let anchor = layout.labelAnchor
        let rect = CGRect(x: (anchor.x - size.width / 2).rounded(), y: (anchor.y - size.height / 2).rounded(),
                          width: size.width, height: size.height)
        return screenQuad(rect, scale: layout.scale, extra: SIMD2(ink, 1))
    }
}
