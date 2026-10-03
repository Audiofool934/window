import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers
import WindowCore

// Renders the room offscreen, layer by layer, and composites the layers the way Core Animation will.
//
//   window-lab --out room.png [--size 2560x1440] [--scale 2] [--date 2026-10-02T13:00:00Z]
//              [--lat 1.35 --lon 103.8] [--facing 270] [--weather rain] [--cover cover.jpg]
//              [--title T --artist A] [--pose 0] [--no-label] [--crop x,y,w,h] [--time 12.5] [--opening 1] [--growth 0]

struct Options {
    var out = "room.png"
    var size = CGSize(width: 2560, height: 1440)
    var scale = 2.0
    var date = Date()
    var lat = 1.35
    var lon = 103.82
    var facing: Double?
    var weather = "fair"
    var cover: String?
    var title = ""
    var artist = ""
    var pose = 1.0
    var showLabel = true
    var crop: CGRect?
    var time = 12.0
    var wet: Double?
    var flash = 0.0
    var temperature: Double?
    var safeBottom = 70.0
    var seed = 3.0
    /// A WeatherReport as JSON, such as the app's cached report.
    var reportFile: String?
    var timing = false
    var sleeveScale = 1.0
    /// 0 is a closed wall, 1 the designed window, and larger keeps growing until the screen is full.
    var opening = 1.0
    /// 0 is a bare wall. 1 is moss, stems, and a little growth around the frame.
    var growth = 0.0
}

func parse() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    func next() -> String {
        guard !args.isEmpty else { fatalError("missing value") }
        return args.removeFirst()
    }
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "--out": o.out = next()
        case "--size":
            let p = next().split(separator: "x").compactMap { Double($0) }
            o.size = CGSize(width: p[0], height: p[1])
        case "--scale": o.scale = Double(next())!
        case "--date":
            let f = ISO8601DateFormatter()
            o.date = f.date(from: next())!
        case "--lat": o.lat = Double(next())!
        case "--lon": o.lon = Double(next())!
        case "--facing": o.facing = Double(next())!
        case "--weather": o.weather = next()
        case "--cover": o.cover = next()
        case "--title": o.title = next()
        case "--artist": o.artist = next()
        case "--pose": o.pose = Double(next())!
        case "--no-label": o.showLabel = false
        case "--crop":
            let p = next().split(separator: ",").compactMap { Double($0) }
            o.crop = CGRect(x: p[0], y: p[1], width: p[2], height: p[3])
        case "--time": o.time = Double(next())!
        case "--wet": o.wet = Double(next())!
        case "--flash": o.flash = Double(next())!
        case "--temp": o.temperature = Double(next())!
        case "--dock": o.safeBottom = Double(next())!
        case "--seed": o.seed = Double(next())!
        case "--report": o.reportFile = next()
        case "--timing": o.timing = true
        case "--sleeve-scale": o.sleeveScale = Double(next())!
        case "--opening": o.opening = Double(next())!
        case "--growth": o.growth = Double(next())!
        default: fatalError("unknown option \(a)")
        }
    }
    return o
}

func report(for preset: String, temperature: Double?, date: Date) -> WeatherReport {
    func make(_ code: Int, _ low: Double, _ mid: Double, _ high: Double, visibility: Double = 24000,
              precipitation: Double = 0, temp: Double = 27, wind: Double = 11) -> WeatherReport {
        WeatherReport(observedAt: date, temperature: temperature ?? temp, humidity: 80, weatherCode: code,
                      precipitation: precipitation, cloudCover: max(low, mid, high), cloudCoverLow: low,
                      cloudCoverMid: mid, cloudCoverHigh: high, visibility: visibility, windSpeed: wind,
                      windDirection: 240, snowDepth: 0)
    }
    switch preset {
    case "clear": return make(0, 0, 3, 8)
    case "fair": return make(1, 22, 12, 35)
    case "partly": return make(2, 45, 30, 40)
    case "cirrus": return make(1, 0, 5, 75)
    case "overcast": return make(3, 96, 70, 40)
    case "drizzle": return make(53, 90, 60, 30, visibility: 9000, precipitation: 0.2)
    case "rain": return make(63, 100, 80, 50, visibility: 7000, precipitation: 1.2)
    case "heavy": return make(65, 100, 90, 60, visibility: 3000, precipitation: 3)
    case "storm": return make(95, 100, 90, 80, visibility: 4000, precipitation: 2.5, wind: 24)
    case "snow":
        var r = make(73, 100, 70, 40, visibility: 2500, precipitation: 0.6, temp: -3)
        r.snowDepth = 0.08
        return r
    case "fog": return make(45, 20, 10, 10, visibility: 220, temp: 9)
    case "haze": return make(1, 15, 10, 30, visibility: 5000)
    case "frost":
        var r = make(0, 0, 5, 10, temp: -12)
        r.snowDepth = 0.15
        return r
    default: fatalError("unknown weather \(preset)")
    }
}

func makeTarget(_ device: MTLDevice, _ rect: PixelRect) -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: RoomRenderer.pixelFormat, width: rect.width, height: rect.height, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]
    d.storageMode = .shared
    return device.makeTexture(descriptor: d)!
}

func image(from texture: MTLTexture) -> CGImage {
    let w = texture.width, h = texture.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    texture.getBytes(&bytes, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                   space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info, provider: provider,
                   decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
}

func loadImage(_ path: String) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
}

let o = parse()
let renderer = try RoomRenderer()
var layout = RoomLayout.make(screenSize: o.size, scale: o.scale, safeTop: 25, safeBottom: o.safeBottom)
if o.sleeveScale != 1 {
    // A larger sleeve still has to lean on the glass, so its foot moves into the room.
    let grown = layout.sleeveSize * (o.sleeveScale - 1)
    layout.sleeveSize *= o.sleeveScale
    layout.sleeveBaseZ -= grown * sin(layout.sleeveLean)
}
let shown = min(max(o.opening, 0), layout.maxOpeningScale)
let glassCapacity = layout.glassRect(openingScale: max(shown, 1))
let surface = try RoomSurface(layout: layout, glass: glassCapacity, renderer: renderer)
let place = Coordinate(latitude: o.lat, longitude: o.lon)
let facingDegrees = o.facing ?? WindowDefaults.facingDegrees(latitude: o.lat)
let weather: WeatherReport
if let file = o.reportFile {
    weather = try JSONDecoder().decode(WeatherReport.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
} else {
    weather = report(for: o.weather, temperature: o.temperature, date: o.date)
}
let atmosphere = Atmosphere(weather)

var inputs = SceneInputs(date: o.date, place: place, facing: facingDegrees * .pi / 180, atmosphere: atmosphere)
inputs.time = o.time
inputs.flash = o.flash
inputs.wetness = o.wet ?? min(atmosphere.rain * 1.2, 1)
inputs.landscapeSeed = o.seed
inputs.cloudShift = [SIMD2(3.1, 1.7), SIMD2(-2.2, 4.4), SIMD2(7.5, -3.3)]
inputs.morph = 2.5
inputs.sleevePose = o.pose
inputs.growth = min(max(o.growth, 0), 1)
if let path = o.cover, let cover = loadImage(path) {
    renderer.setCover(cover)
    renderer.setCover(cover)
    inputs.lampColor = CoverPalette.lampColor(for: cover)
    inputs.hasCover = true
}
// As in the app, the label shows only while the sleeve stands.
inputs.labelAlpha = (o.showLabel && o.pose < 0.5 && !(o.title.isEmpty && o.artist.isEmpty)) ? 1 : 0
let sill = SillState(pose: o.pose, title: o.title, artist: o.artist, showLabel: o.showLabel)

// First pass: measure the light through the glass, as the app does from the previous frame.
// The eye adapts to the scene without the flash, which only lasts a moment.
let flash = inputs.flash
inputs.flash = 0
func makeFrame() -> FrameUniforms {
    FrameUniforms.make(layout: layout, inputs: inputs, openingScale: shown, glassRect: glassCapacity)
}
var frame = makeFrame()
if let buffer = renderer.queue.makeCommandBuffer() {
    renderer.encodeSkyTable(frame, into: buffer)
    renderer.encodeOutdoor(frame, surface: surface, into: buffer)
    buffer.commit()
    buffer.waitUntilCompleted()
}
if let measured = surface.measuredWindowLight {
    inputs.windowLight = measured
    inputs.adaptedLuminance = 0.2126 * measured.x + 0.7152 * measured.y + 0.0722 * measured.z
}
inputs.flash = flash
if flash > 0, let buffer = renderer.queue.makeCommandBuffer() {
    frame = makeFrame()
    renderer.encodeSkyTable(frame, into: buffer)
    renderer.encodeOutdoor(frame, surface: surface, into: buffer)
    buffer.commit()
    buffer.waitUntilCompleted()
    if let measured = surface.measuredWindowLight { inputs.windowLight = measured }
}
frame = makeFrame()

var rects = layout.layerRects
if glassCapacity.width > 1, glassCapacity.height > 1 {
    rects.glass = PixelRect(covering: glassCapacity, scale: layout.scale)
}
let roomTarget = makeTarget(renderer.device, rects.room)
let glassTarget = makeTarget(renderer.device, rects.glass)
let objectsTarget = makeTarget(renderer.device, rects.objects)
let start = Date()
if let buffer = renderer.queue.makeCommandBuffer() {
    renderer.encodeSkyTable(frame, into: buffer)
    renderer.encodeOutdoor(frame, surface: surface, into: buffer)
    renderer.encodeRoom(frame, target: roomTarget, origin: rects.room.origin, into: buffer)
    renderer.encodeGlass(frame, surface: surface, target: glassTarget, origin: rects.glass.origin, into: buffer)
    renderer.encodeObjects(frame, surface: surface, sill: sill, target: objectsTarget, origin: rects.objects.origin, into: buffer)
    buffer.commit()
    buffer.waitUntilCompleted()
    if let error = buffer.error { print("GPU error: \(error)") }
    let gpu = buffer.gpuEndTime - buffer.gpuStartTime
    print(String(format: "gpu %.2f ms, wall %.1f ms", gpu * 1000, Date().timeIntervalSince(start) * 1000))
}

// Each pass alone, to see what the continuous part of a frame costs on the GPU.
if o.timing {
    func time(_ name: String, _ encode: (MTLCommandBuffer) -> Void) {
        var samples: [Double] = []
        for _ in 0..<12 {
            let buffer = renderer.queue.makeCommandBuffer()!
            encode(buffer)
            buffer.commit()
            buffer.waitUntilCompleted()
            samples.append((buffer.gpuEndTime - buffer.gpuStartTime) * 1000)
        }
        samples.sort()
        print(String(format: "%-8@ median %.2f ms", name as NSString, samples[samples.count / 2]))
    }
    time("sky") { renderer.encodeSkyTable(frame, into: $0) }
    time("outdoor") { renderer.encodeOutdoor(frame, surface: surface, into: $0) }
    time("glass") { renderer.encodeGlass(frame, surface: surface, target: glassTarget, origin: rects.glass.origin, into: $0) }
    time("room") { renderer.encodeRoom(frame, target: roomTarget, origin: rects.room.origin, into: $0) }
    time("objects") { renderer.encodeObjects(frame, surface: surface, sill: sill, target: objectsTarget, origin: rects.objects.origin, into: $0) }
}

// Composite like CALayer: room, then glass, then the objects with premultiplied alpha.
let composite = makeTarget(renderer.device, rects.room)
if let buffer = renderer.queue.makeCommandBuffer() {
    renderer.encodeComposite([(roomTarget, rects.room), (glassTarget, rects.glass), (objectsTarget, rects.objects)],
                             into: composite, buffer: buffer)
    buffer.commit()
    buffer.waitUntilCompleted()
}
var result = image(from: composite)
if let crop = o.crop, let cropped = result.cropping(to: crop) { result = cropped }

let url = URL(fileURLWithPath: o.out)
let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, result, nil)
CGImageDestinationFinalize(destination)

let sun = Astronomy.sun(at: o.date, for: place)
let moon = Astronomy.moon(at: o.date, for: place)
let lit = Astronomy.moonIllumination(sun: sun.vector, moon: moon.position.vector)
print(String(format: "sun alt %.1f az %.1f | moon alt %.1f az %.1f lit %.2f | facing %.0f | window light %.4f %.4f %.4f | lamp %.2f %.2f %.2f",
             sun.altitude * 180 / .pi, sun.azimuth * 180 / .pi, moon.position.altitude * 180 / .pi,
             moon.position.azimuth * 180 / .pi, lit, facingDegrees, inputs.windowLight.x, inputs.windowLight.y,
             inputs.windowLight.z, inputs.lampColor.x, inputs.lampColor.y, inputs.lampColor.z))
print("wrote \(o.out)")
