import CoreGraphics
import Foundation

/// A rectangle on whole device pixels, so layers line up exactly with what the shaders assume.
public struct PixelRect: Equatable, Sendable {
    public var x: Int
    public var y: Int
    public var width: Int
    public var height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// The smallest pixel-aligned rectangle covering `rect` (in points).
    public init(covering rect: CGRect, scale: Double) {
        let x0 = Int((Double(rect.minX) * scale).rounded(.down))
        let y0 = Int((Double(rect.minY) * scale).rounded(.down))
        let x1 = Int((Double(rect.maxX) * scale).rounded(.up))
        let y1 = Int((Double(rect.maxY) * scale).rounded(.up))
        self.init(x: x0, y: y0, width: max(x1 - x0, 1), height: max(y1 - y0, 1))
    }

    public var origin: SIMD2<Float> { SIMD2(Float(x), Float(y)) }

    /// In points, top-left origin.
    public func points(scale: Double) -> CGRect {
        CGRect(x: Double(x) / scale, y: Double(y) / scale, width: Double(width) / scale, height: Double(height) / scale)
    }
}

public struct LayerRects: Equatable, Sendable {
    public var room: PixelRect
    public var glass: PixelRect
    public var objects: PixelRect
}

extension RoomLayout {
    public var layerRects: LayerRects {
        let full = PixelRect(x: 0, y: 0, width: Int((Double(screenSize.width) * scale).rounded()),
                             height: Int((Double(screenSize.height) * scale).rounded()))
        return LayerRects(room: full,
                          glass: PixelRect(covering: glassRect, scale: scale),
                          objects: PixelRect(covering: objectsRect, scale: scale))
    }
}
