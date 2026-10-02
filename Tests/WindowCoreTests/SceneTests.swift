import CoreGraphics
import Foundation
import Metal
import Testing
@testable import WindowCore

@Suite struct LayoutTests {
    static let screens: [(CGSize, Double)] = [
        (CGSize(width: 2560, height: 1440), 2),
        (CGSize(width: 1512, height: 982), 2),
        (CGSize(width: 1440, height: 900), 1),
        (CGSize(width: 1080, height: 1920), 2)
    ]

    @Test(arguments: screens.indices)
    func roomFitsTheScreen(_ index: Int) {
        let (size, scale) = Self.screens[index]
        let layout = RoomLayout.make(screenSize: size, scale: scale, safeTop: 25, safeBottom: 70)
        let screen = CGRect(origin: .zero, size: size)
        #expect(screen.contains(layout.glassRect))
        #expect(screen.contains(layout.objectsRect))
        // The lamp and the sleeve fall inside the sill's layer.
        #expect(layout.objectsRect.contains(layout.project(layout.lampCentre)))
        #expect(layout.objectsRect.contains(layout.project(SIMD3(layout.sleeveCentreX, layout.openingBottom + 0.1, layout.sleeveBaseZ))))
        // The glass sits inside the opening seen on the wall.
        let topLeft = layout.project(SIMD3(layout.openingLeft, layout.openingTop, layout.wallDistance))
        let bottomRight = layout.project(SIMD3(layout.openingRight, layout.openingBottom, layout.wallDistance))
        #expect(layout.glassRect.minX > topLeft.x && layout.glassRect.maxX < bottomRight.x)
        let rects = layout.layerRects
        #expect(rects.glass.width > 0 && rects.objects.height > 0)
        #expect(rects.room.width == Int(size.width * scale))
    }

    @Test func pixelRectsCoverFractionalRectangles() {
        let rect = PixelRect(covering: CGRect(x: 10.3, y: 4.6, width: 100.2, height: 50.1), scale: 2)
        #expect(rect == PixelRect(x: 20, y: 9, width: 201, height: 101))
    }
}

@Suite struct RendererTests {
    @Test func uniformsMatchTheShaderLayout() {
        // 36 float4 fields and one float4x4, as declared in Room.metal.
        #expect(MemoryLayout<FrameUniforms>.stride == 36 * 16 + 64)
        #expect(MemoryLayout<FrameUniforms>.offset(of: \.timing) == 35 * 16)
        #expect(MemoryLayout<FrameUniforms>.offset(of: \.stars) == 36 * 16)
    }

    @Test func shaderCompilesAndAFrameRenders() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let renderer = try RoomRenderer()
        let layout = RoomLayout.make(screenSize: CGSize(width: 640, height: 400), scale: 1)
        let surface = try RoomSurface(layout: layout, renderer: renderer)
        var inputs = SceneInputs(date: Date(timeIntervalSince1970: 1_790_000_000), place: Coordinate(latitude: 1.3, longitude: 103.8),
                                 facing: .pi * 1.5, atmosphere: .calm)
        inputs.sleevePose = 0
        let frame = FrameUniforms.make(layout: layout, inputs: inputs)
        let buffer = try #require(renderer.queue.makeCommandBuffer())
        renderer.encodeSkyTable(frame, into: buffer)
        renderer.encodeOutdoor(frame, surface: surface, into: buffer)
        buffer.commit()
        buffer.waitUntilCompleted()
        #expect(buffer.status == .completed)
        let light = try #require(surface.measuredWindowLight)
        #expect(light.x > 0 && light.y > 0 && light.z > 0)
    }
}

@Suite struct SceneDriverTests {
    @Test func theSleeveStandsAndLiesDownOverAboutASecond() {
        let driver = SceneDriver(place: Coordinate(latitude: 1.3, longitude: 103.8), facing: 0, landscapeSeed: 1)
        var now = Date()
        driver.advance(to: now)
        #expect(driver.sillPose == 1)
        driver.setStanding(true)
        for _ in 0..<40 { now += 0.05; driver.advance(to: now) }
        #expect(driver.sillPose < 0.001)
        #expect(!driver.isSillMoving)
        driver.setStanding(false)
        for _ in 0..<30 { now += 0.05; driver.advance(to: now) }
        #expect(abs(driver.sillPose - 1) < 0.001)
    }

    @Test func lightningOnlyComesWithThunder() {
        var calm = Lightning()
        var stormy = Lightning()
        var seenFlash = false
        for step in 0..<6000 {
            let t = Double(step) * 0.02
            calm.advance(clock: t, thunder: 0)
            stormy.advance(clock: t, thunder: 1)
            #expect(calm.flash(at: t) == 0)
            if stormy.flash(at: t) > 0.1 { seenFlash = true }
        }
        #expect(seenFlash)
    }

    @Test func theFallSettlesAndTheLiftEases() {
        #expect(SceneDriver.fall(0) == 0)
        #expect(abs(SceneDriver.fall(1) - 1) < 1e-9)
        #expect(SceneDriver.lift(0.5) == 0.5)
    }
}
