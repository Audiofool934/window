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

    @Test func theOpeningClosesOntoTheSillAndGrowsWithoutLeavingTheScreen() {
        let layout = RoomLayout.make(screenSize: CGSize(width: 1440, height: 900), scale: 2, safeTop: 25, safeBottom: 70)
        let centre = (layout.openingBottom + layout.openingTop) / 2
        let shut = layout.openingEdges(scale: 0)
        #expect(shut.left == shut.right)
        #expect(shut.top == shut.bottom)
        #expect(abs(shut.bottom - centre) < 1e-9)
        #expect(layout.glassRect(openingScale: 0).isNull)
        let designed = layout.openingEdges(scale: 1)
        #expect(abs((designed.right - designed.left) - 1.8) < 1e-9)
        #expect(abs((designed.top - designed.bottom) - 1.3) < 1e-9)
        #expect(designed.bottom == layout.openingBottom)
        let wide = layout.openingEdges(scale: 2)
        #expect(wide.right - wide.left > 3.5)
        #expect(abs((wide.bottom + wide.top) / 2 - centre) < 1e-9)
        #expect(wide.bottom < layout.openingBottom)
        #expect(layout.maxOpeningScale >= 1)
        let hole = layout.openingRect(openingScale: layout.maxOpeningScale)
        #expect(abs(hole.midX - layout.screenSize.width / 2) < 0.5)
        #expect(abs(hole.midY - layout.screenSize.height / 2) < 0.5)
        #expect(abs(hole.height - layout.screenSize.height * RoomLayout.maxFill) < 1)
        let designedRect = layout.openingRect(openingScale: 1)
        #expect(abs(designedRect.midX - hole.midX) < 0.5)
        #expect(abs(designedRect.midY - hole.midY) < 0.5)
        let placed = layout.following(openingScale: layout.maxOpeningScale)
        let bottom = layout.openingEdges(scale: layout.maxOpeningScale).bottom
        #expect(abs(placed.openingBottom - bottom) < 1e-9)
        #expect(abs(placed.lampCentre.y - bottom - 0.155) < 1e-9)
        let frame = FrameUniforms.make(layout: layout, inputs: SceneInputs(date: Date(timeIntervalSince1970: 0),
                                                                            place: Coordinate(latitude: 0, longitude: 0),
                                                                            facing: 0, atmosphere: .calm),
                                       openingScale: layout.maxOpeningScale)
        #expect(abs(Double(frame.lamp.y) - (bottom + 0.155)) < 1e-3)
    }

    @Test func theSizeControlRunsFromTheDesignedWindowToTheLargest() {
        let layout = RoomLayout.make(screenSize: CGSize(width: 1440, height: 900), scale: 2, safeTop: 25, safeBottom: 70)
        let full = layout.largestFittedOpening()
        #expect(full > 1)
        #expect(abs(layout.openingScale(amount: 0) - 1) < 1e-9)
        #expect(abs(layout.openingScale(amount: 1) - full) < 1e-9)
        #expect(abs(layout.openingScale(amount: 0.5) - (1 + full) / 2) < 1e-9)
        #expect(layout.openingScale(amount: -2) == 1)
        #expect(layout.openingScale(amount: 4) == full)
        let small = layout.openingRect(openingScale: layout.openingScale(amount: 0))
        let large = layout.openingRect(openingScale: full)
        #expect(abs(small.midX - large.midX) < 0.5)
        #expect(abs(small.midY - large.midY) < 0.5)
        #expect(small.width < large.width - 1)
    }

    @Test func aTallScreenFillsAcrossAndStaysCentred() {
        let layout = RoomLayout.make(screenSize: CGSize(width: 1080, height: 1920), scale: 2, safeTop: 25, safeBottom: 70)
        let hole = layout.openingRect(openingScale: layout.maxOpeningScale)
        #expect(abs(hole.midX - layout.screenSize.width / 2) < 0.5)
        #expect(abs(hole.midY - layout.screenSize.height / 2) < 0.5)
        #expect(abs(hole.width - layout.screenSize.width * RoomLayout.maxFill) < 1)
        #expect(hole.height < layout.screenSize.height - 1)
    }

    @Test func aShutWallKeepsEnoughDaylightToStayVisible() {
        let layout = RoomLayout.make(screenSize: CGSize(width: 1440, height: 900), scale: 2)
        var inputs = SceneInputs(date: Date(timeIntervalSince1970: 1_790_000_000),
                                 place: Coordinate(latitude: 1.3, longitude: 103.8),
                                 facing: .pi * 1.5, atmosphere: .calm)
        inputs.windowLight = SIMD3(1.6, 1.8, 2.1)
        inputs.adaptedLuminance = 1.8
        let shut = FrameUniforms.make(layout: layout, inputs: inputs, openingScale: 0)
        let floor = FrameUniforms.make(layout: layout, inputs: inputs, openingScale: Opening.lightFloor)
        let open = FrameUniforms.make(layout: layout, inputs: inputs, openingScale: 1)
        #expect(abs(Double(shut.exposure.y) - Double(floor.exposure.y)) < 1e-4)
        #expect(open.exposure.y < shut.exposure.y)
        #expect(Opening.lightOpenness(0) == Opening.lightFloor)
        #expect(Opening.lightOpenness(1) == 1)
        #expect(Opening.lightOpenness(2.4) == 1)
    }

    @Test func pixelRectsCoverFractionalRectangles() {
        let rect = PixelRect(covering: CGRect(x: 10.3, y: 4.6, width: 100.2, height: 50.1), scale: 2)
        #expect(rect == PixelRect(x: 20, y: 9, width: 201, height: 101))
    }
}

@Suite struct RendererTests {
    @Test func uniformsMatchTheShaderLayout() {
        // 37 float4 fields and one float4x4, as declared in Room.metal.
        #expect(MemoryLayout<FrameUniforms>.stride == 37 * 16 + 64)
        #expect(MemoryLayout<FrameUniforms>.offset(of: \.timing) == 35 * 16)
        #expect(MemoryLayout<FrameUniforms>.offset(of: \.occupation) == 36 * 16)
        #expect(MemoryLayout<FrameUniforms>.offset(of: \.stars) == 37 * 16)
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

    @Test func aClosedAndAWideOpeningBothRender() throws {
        guard MTLCreateSystemDefaultDevice() != nil else { return }
        let renderer = try RoomRenderer()
        let layout = RoomLayout.make(screenSize: CGSize(width: 640, height: 400), scale: 1)
        let surface = try RoomSurface(layout: layout, renderer: renderer)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: RoomRenderer.pixelFormat, width: 64, height: 64, mipmapped: false)
        descriptor.usage = [.renderTarget]
        descriptor.storageMode = .private
        let target = try #require(renderer.device.makeTexture(descriptor: descriptor))
        let inputs = SceneInputs(date: Date(timeIntervalSince1970: 1_790_000_000), place: Coordinate(latitude: 1.3, longitude: 103.8),
                                 facing: .pi * 1.5, atmosphere: .calm)
        for scale in [0.0, 2.0] {
            let frame = FrameUniforms.make(layout: layout, inputs: inputs, openingScale: scale)
            let buffer = try #require(renderer.queue.makeCommandBuffer())
            renderer.encodeSkyTable(frame, into: buffer)
            renderer.encodeOutdoor(frame, surface: surface, into: buffer)
            renderer.encodeRoom(frame, target: target, origin: .zero, into: buffer)
            buffer.commit()
            buffer.waitUntilCompleted()
            #expect(buffer.status == .completed)
        }
    }
}

@Suite struct SceneDriverTests {
    @Test func aLaidDownSleeveLeavesTheSill() {
        let layout = RoomLayout.make(screenSize: CGSize(width: 1440, height: 900), scale: 2, safeTop: 25, safeBottom: 70)
        #expect(SillGeometry.sleevePresence(0) == 1)
        #expect(SillGeometry.sleevePresence(0.5) == 0)
        #expect(SillGeometry.sleevePresence(1) == 0)
        #expect(SillGeometry.sleevePresence(1.02) == 0)
        #expect(!SillGeometry.sleeve(layout: layout, pose: 0).isEmpty)
        #expect(SillGeometry.sleeve(layout: layout, pose: 0.5).isEmpty)
        #expect(SillGeometry.sleeve(layout: layout, pose: 1).isEmpty)
        #expect(!SillGeometry.shadows(layout: layout, pose: 0).isEmpty)
        #expect(SillGeometry.shadows(layout: layout, pose: 1).isEmpty)
    }

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

    @Test func growthEasesAndCanBeSetAtOnce() {
        let driver = SceneDriver(place: Coordinate(latitude: 1.3, longitude: 103.8), facing: 0, landscapeSeed: 1)
        var now = Date()
        driver.advance(to: now)
        driver.setGrowth(1)
        #expect(driver.growth == 0)
        // Each step is capped at half a second, so eighty steps are forty seconds of easing.
        for _ in 0..<80 { now += 1; driver.advance(to: now) }
        #expect(driver.growth > 0.22)
        #expect(driver.growth < 0.36)
        driver.setGrowth(1, immediately: true)
        #expect(driver.growth == 1)
        driver.setGrowth(-1, immediately: true)
        #expect(driver.growth == 0)
    }

    @Test func growthReachesTheFrameWithoutMovingTheOpening() {
        let layout = RoomLayout.make(screenSize: CGSize(width: 800, height: 600), scale: 1)
        var inputs = SceneInputs(date: Date(timeIntervalSince1970: 1_790_000_000),
                                 place: Coordinate(latitude: 1.3, longitude: 103.8),
                                 facing: 0, atmosphere: .calm)
        inputs.growth = 0.4
        let frame = FrameUniforms.make(layout: layout, inputs: inputs)
        #expect(abs(Double(frame.timing.w) - 1) < 1e-5)
        #expect(abs(Double(frame.occupation.x) - 0.4) < 1e-5)
        inputs.growth = 4
        let full = FrameUniforms.make(layout: layout, inputs: inputs)
        #expect(full.occupation.x == 1)
    }

    @Test func theFallSettlesAndTheLiftEases() {
        #expect(SceneDriver.fall(0) == 0)
        #expect(abs(SceneDriver.fall(1) - 1) < 1e-9)
        #expect(SceneDriver.lift(0.5) == 0.5)
    }
}
