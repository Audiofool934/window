import AppKit
import ImageIO
import Metal
import UniformTypeIdentifiers
import WindowCore

/// With WINDOW_SNAPSHOT set to a folder, writes each display's live room to a PNG, layered as the window server does.
enum DebugSnapshot {
    static func write(view: RoomView, frame: FrameUniforms, sill: SillState, renderer: RoomRenderer, to url: URL) {
        let device = renderer.device
        func target(_ rect: PixelRect) -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: RoomRenderer.pixelFormat, width: rect.width,
                                                             height: rect.height, mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .shared
            return device.makeTexture(descriptor: d)
        }
        let rects = view.rects
        guard let room = target(rects.room), let glass = target(rects.glass), let objects = target(rects.objects),
              let composite = target(rects.room), let buffer = renderer.queue.makeCommandBuffer() else { return }
        renderer.encodeRoom(frame, target: room, origin: rects.room.origin, into: buffer)
        renderer.encodeGlass(frame, surface: view.surface, target: glass, origin: rects.glass.origin, into: buffer)
        renderer.encodeObjects(frame, surface: view.surface, sill: sill, target: objects, origin: rects.objects.origin, into: buffer)
        renderer.encodeComposite([(room, rects.room), (glass, rects.glass), (objects, rects.objects)], into: composite, buffer: buffer)
        buffer.addCompletedHandler { _ in
            let w = composite.width, h = composite.height
            var bytes = [UInt8](repeating: 0, count: w * h * 4)
            composite.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
            let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            guard let provider = CGDataProvider(data: Data(bytes) as CFData),
                  let image = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                                      decode: nil, shouldInterpolate: false, intent: .defaultIntent),
                  let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
        buffer.commit()
    }
}
