import CoreGraphics
import Foundation
import simd

/// The one place the song's colour enters the room: the lamp.
public enum CoverPalette {
    /// The cover's most present strong hue, lifted into lamplight.
    /// A black-and-white cover leaves the lamp at plain incandescent.
    public static func lampColor(for image: CGImage) -> SIMD3<Double> {
        let side = 32
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { return LampColor.incandescent }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)

        let bins = 36
        var weight = [Double](repeating: 0, count: bins)
        var sumA = [Double](repeating: 0, count: bins)
        var sumB = [Double](repeating: 0, count: bins)
        var sumC = [Double](repeating: 0, count: bins)
        var total = 0.0
        for i in 0..<(side * side) {
            let rgb = SIMD3(Double(pixels[i * 4]), Double(pixels[i * 4 + 1]), Double(pixels[i * 4 + 2])) / 255
            let lab = oklab(fromLinear: linear(rgb))
            let chroma = (lab.y * lab.y + lab.z * lab.z).squareRoot()
            total += 1
            guard chroma > 0.02 else { continue }
            // Strong, mid-light colour counts most; near-black and near-white say little about the cover's hue.
            let lightness = max(0, 1 - abs(lab.x - 0.62) * 1.6)
            let w = pow(chroma, 1.3) * lightness
            var hue = atan2(lab.z, lab.y)
            if hue < 0 { hue += 2 * .pi }
            let bin = min(Int(hue / (2 * .pi) * Double(bins)), bins - 1)
            weight[bin] += w
            sumA[bin] += lab.y * w
            sumB[bin] += lab.z * w
            sumC[bin] += chroma * w
        }
        // Neighbouring bins vote together, so a hue split across a boundary still wins.
        var best = -1
        var bestScore = 0.0
        for i in 0..<bins {
            let score = weight[i] + 0.5 * (weight[(i + 1) % bins] + weight[(i + bins - 1) % bins])
            if score > bestScore { bestScore = score; best = i }
        }
        guard best >= 0 else { return LampColor.incandescent }
        var a = 0.0, b = 0.0, c = 0.0, w = 0.0
        for offset in -1...1 {
            let j = (best + offset + bins) % bins
            a += sumA[j]; b += sumB[j]; c += sumC[j]; w += weight[j]
        }
        guard w > 0 else { return LampColor.incandescent }
        let hue = atan2(b / w, a / w)
        let chroma = c / w
        // How much of the cover carries that hue at all decides how strongly the lamp takes it.
        let presence = min(bestScore / total / 0.012, 1)
        let strength = smoothstep(0.035, 0.13, chroma) * (0.35 + 0.5 * presence)

        let lampChroma = min(chroma, 0.14) * 0.9
        let tinted = linear(fromOklab: SIMD3(0.8, lampChroma * cos(hue), lampChroma * sin(hue)))
        let tint = normalizedLuminance(simd_max(tinted, .zero))
        let mixed = LampColor.incandescent * (1 - strength) + tint * strength
        return normalizedLuminance(mixed)
    }

    static func normalizedLuminance(_ c: SIMD3<Double>) -> SIMD3<Double> {
        let l = 0.2126 * c.x + 0.7152 * c.y + 0.0722 * c.z
        return l > 1e-6 ? c / l : LampColor.incandescent
    }

    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    static func linear(_ srgb: SIMD3<Double>) -> SIMD3<Double> {
        func f(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return SIMD3(f(srgb.x), f(srgb.y), f(srgb.z))
    }

    static func oklab(fromLinear c: SIMD3<Double>) -> SIMD3<Double> {
        let l = cbrt(0.4122214708 * c.x + 0.5363325363 * c.y + 0.0514459929 * c.z)
        let m = cbrt(0.2119034982 * c.x + 0.6806995451 * c.y + 0.1073969566 * c.z)
        let s = cbrt(0.0883024619 * c.x + 0.2817188376 * c.y + 0.6299787005 * c.z)
        return SIMD3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                     1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                     0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    static func linear(fromOklab lab: SIMD3<Double>) -> SIMD3<Double> {
        let l = pow(lab.x + 0.3963377774 * lab.y + 0.2158037573 * lab.z, 3)
        let m = pow(lab.x - 0.1055613458 * lab.y - 0.0638541728 * lab.z, 3)
        let s = pow(lab.x - 0.0894841775 * lab.y - 1.2914855480 * lab.z, 3)
        return SIMD3(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                     -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                     -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }
}
