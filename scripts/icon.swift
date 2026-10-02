import AppKit
import CoreGraphics

// Draws the app icon: a night window with its glazing bars and a lit globe on the sill.
// Usage: swift scripts/icon.swift <output.iconset>

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func draw(size: Int) -> Data {
    let s = CGFloat(size)
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: s / 1024, y: s / 1024)
    func colour(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: space, components: [r, g, b, a])! }

    // The tile: a dark wall, warm at the bottom where the lamp is.
    let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 186, cornerHeight: 186, transform: nil)
    context.addPath(tile)
    context.clip()
    let wall = CGGradient(colorsSpace: space, colors: [colour(0.16, 0.13, 0.12), colour(0.07, 0.07, 0.08)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(wall, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])

    // The glass: a deep evening sky with a pale band at the horizon.
    let glass = CGRect(x: 262, y: 330, width: 500, height: 430)
    context.saveGState()
    context.clip(to: glass)
    let sky = CGGradient(colorsSpace: space, colors: [colour(0.83, 0.55, 0.5), colour(0.33, 0.31, 0.52), colour(0.11, 0.13, 0.26)] as CFArray,
                         locations: [0, 0.35, 1])!
    context.drawLinearGradient(sky, start: CGPoint(x: 512, y: 330), end: CGPoint(x: 512, y: 760), options: [])
    // A low treeline.
    context.setFillColor(colour(0.05, 0.05, 0.08))
    context.beginPath()
    context.move(to: CGPoint(x: 262, y: 330))
    var x: CGFloat = 262
    var i = 0
    while x <= 772 {
        let bump: CGFloat = [10, 22, 15, 28, 12, 20, 9, 25][i % 8]
        context.addLine(to: CGPoint(x: x, y: 362 + bump))
        x += 22
        i += 1
    }
    context.addLine(to: CGPoint(x: 762, y: 330))
    context.fillPath()
    context.restoreGState()

    // The reveal and the frame.
    context.setStrokeColor(colour(0.03, 0.03, 0.035))
    context.setLineWidth(26)
    context.stroke(glass.insetBy(dx: -13, dy: -13))
    context.setLineWidth(16)
    context.move(to: CGPoint(x: 512, y: 330)); context.addLine(to: CGPoint(x: 512, y: 760))
    context.move(to: CGPoint(x: 262, y: 630)); context.addLine(to: CGPoint(x: 762, y: 630))
    context.strokePath()

    // The sill.
    context.setFillColor(colour(0.55, 0.47, 0.42))
    context.fill(CGRect(x: 214, y: 286, width: 596, height: 32))

    // The globe and its glow.
    let lamp = CGPoint(x: 660, y: 370)
    let glow = CGGradient(colorsSpace: space, colors: [colour(1.0, 0.78, 0.6, 0.55), colour(1.0, 0.7, 0.5, 0)] as CFArray, locations: [0, 1])!
    context.drawRadialGradient(glow, startCenter: lamp, startRadius: 0, endCenter: lamp, endRadius: 190, options: [])
    context.setFillColor(colour(0.07, 0.06, 0.06))
    context.fill(CGRect(x: lamp.x - 22, y: 318, width: 44, height: 22))
    let globe = CGGradient(colorsSpace: space, colors: [colour(1.0, 0.97, 0.92), colour(1.0, 0.8, 0.66)] as CFArray, locations: [0, 1])!
    context.saveGState()
    context.addEllipse(in: CGRect(x: lamp.x - 46, y: lamp.y - 30, width: 92, height: 92))
    context.clip()
    context.drawRadialGradient(globe, startCenter: CGPoint(x: lamp.x, y: lamp.y + 8), startRadius: 0,
                               endCenter: CGPoint(x: lamp.x, y: lamp.y + 16), endRadius: 52, options: [.drawsAfterEndLocation])
    context.restoreGState()

    // A record sleeve leaning on the glass.
    context.setFillColor(colour(0.78, 0.36, 0.28))
    context.fill(CGRect(x: 330, y: 318, width: 112, height: 112))
    context.setFillColor(colour(0.93, 0.85, 0.7))
    context.fillEllipse(in: CGRect(x: 368, y: 356, width: 36, height: 36))

    let image = context.makeImage()!
    let rep = NSBitmapImageRep(cgImage: image)
    return rep.representation(using: .png, properties: [:])!
}

for (name, size) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                     ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try! draw(size: size).write(to: output.appendingPathComponent("icon_\(name).png"))
}
