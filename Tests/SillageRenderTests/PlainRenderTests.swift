import Foundation
import Metal
import SillageCore
import Testing

@testable import SillageRender
#if canImport(simd)
    import simd
#endif

@Suite("Plain render and auto camera")
struct PlainRenderTests {
    @Test func plainPointsKeepEachGalaxyInItsOwnTintOnBlack() throws {
        var scene = SceneConfig.merger(particleCount: 20_000)
        scene.galaxies[0].color = SIMD3(1, 0, 0)
        scene.galaxies[1].color = SIMD3(0, 0, 1)
        let particles = RestrictedSolver.sampleParticles(for: scene)
        let renderer = try Renderer(
            particles: particles,
            settings: RenderSettings(
                width: 320, height: 180, supersample: 1, brightness: 0.12, starCount: 0,
                minimumKernel: 1.5, maximumKernel: 1.5, bloomIntensity: 0, spikeArms: 0,
                skyLevel: 0, noiseLevel: 0, plain: true))
        renderer.setDiskFrames(
            DiskFrame.make(
                scene: scene, centers: scene.galaxies.map(\.position), time: 0, strength: 0))
        let pixels = renderer.render(camera: Camera.framing(radius: 80))

        var red = 0
        var blue = 0
        var other = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            let (r, g, b) = (pixels[offset], pixels[offset + 1], pixels[offset + 2])
            if g > 0 { other += 1 }
            if r > 0 { red += 1 }
            if b > 0 { blue += 1 }
        }
        #expect(red > 100 && blue > 100)
        #expect(other == 0)
        #expect(pixels[0] == 0 && pixels[1] == 0 && pixels[2] == 0)
    }

    @Test func aSlicedSplatDrawsTheSamePicture() throws {
        let scene = SceneConfig.merger(particleCount: 20_000)
        let particles = RestrictedSolver.sampleParticles(for: scene)
        let renderer = try Renderer(
            particles: particles,
            settings: RenderSettings(
                width: 320, height: 180, supersample: 2, brightness: 0.12, dustStrength: 0.5,
                starCount: 300, bloomIntensity: 0.3, spikeArms: 4, noiseLevel: 0))
        renderer.setDiskFrames(
            DiskFrame.make(
                scene: scene, centers: scene.galaxies.map(\.position), time: 0, strength: 1))
        let camera = Camera.framing(radius: 80)
        let whole = renderer.render(camera: camera)
        let sliced = renderer.render(camera: camera, slice: 3_000)
        #expect(whole.contains { $0 > 0 })
        #expect(sliced == whole)
    }

    /// The dust web changes how the dust is drawn and nothing else: with no dust, no web.
    @Test func theDustWebMovesOnlyTheDust() throws {
        let scene = SceneConfig.isolatedDisk(particleCount: 20_000)
        let particles = RestrictedSolver.sampleParticles(for: scene)
        func draw(dust: Float, web: Float) throws -> [UInt8] {
            var settings = RenderSettings(
                width: 320, height: 180, supersample: 2, brightness: 0.12, dustStrength: dust,
                starCount: 0, noiseLevel: 0)
            settings.dustWeb = web
            let renderer = try Renderer(particles: particles, settings: settings)
            renderer.time = 3
            renderer.setDiskFrames(
                DiskFrame.make(scene: scene, centers: [.zero], time: 3, strength: 1))
            return renderer.render(camera: Camera.framing(radius: 20, elevation: 1.2))
        }
        #expect(try draw(dust: 0.6, web: 1) != draw(dust: 0.6, web: 0))
        #expect(try draw(dust: 0, web: 1) == draw(dust: 0, web: 0))
    }

    /// Cut into slices, each pass of dust hands its own carrier to the web, and the sum is the
    /// same web up to the rounding of the attachments in between.
    @Test func aSlicedSplatDrawsTheSameWeb() throws {
        let scene = SceneConfig.isolatedDisk(particleCount: 20_000)
        let particles = RestrictedSolver.sampleParticles(for: scene)
        var settings = RenderSettings(
            width: 320, height: 180, supersample: 2, brightness: 0.12, dustStrength: 0.8,
            starCount: 0, noiseLevel: 0)
        settings.dustWeb = 1
        let renderer = try Renderer(particles: particles, settings: settings)
        renderer.time = 3
        renderer.setDiskFrames(DiskFrame.make(scene: scene, centers: [.zero], time: 3, strength: 1))
        let camera = Camera.framing(radius: 20, elevation: 1.2)
        let whole = renderer.render(camera: camera)
        let sliced = renderer.render(camera: camera, slice: 3_000)
        let gaps = zip(whole, sliced).map { abs(Int($0) - Int($1)) }
        #expect(whole.contains { $0 > 0 })
        #expect(gaps.max() ?? 0 <= 3)
        #expect(Double(gaps.reduce(0, +)) / Double(max(gaps.count, 1)) < 0.05)
    }

    /// The baked lace tiles: across its edges it changes no more than between neighbours inside
    /// it. And its mean is the spike's lace's, so the bake moved no exposure.
    @Test func theBakedLaceTilesAndKeepsTheSpikesMean() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let library = try ShaderCache.library(Shaders.source, on: device)
        let (texture, mean) = try DustWeb.lace(library: library, device: device)
        #expect(abs(mean * 1.8366 - 1) < 0.01)
        let side = texture.width
        let bytes = side * side * 2
        let buffer = try #require(device.makeBuffer(length: bytes, options: .storageModeShared))
        let commands = try #require(device.makeCommandQueue()?.makeCommandBuffer())
        let blit = try #require(commands.makeBlitCommandEncoder())
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: side, height: side, depth: 1), to: buffer,
            destinationOffset: 0, destinationBytesPerRow: side * 2, destinationBytesPerImage: bytes)
        blit.endEncoding()
        commands.commit()
        commands.waitUntilCompleted()
        let texels = buffer.contents().bindMemory(to: Float16.self, capacity: side * side)
        func at(_ x: Int, _ y: Int) -> Double { Double(texels[y * side + x]) }
        var inside = 0.0
        var across = 0.0
        for line in stride(from: 0, to: side, by: 16) {
            for step in 0..<(side - 1) {
                inside += abs(at(step + 1, line) - at(step, line)) + abs(at(line, step + 1) - at(line, step))
            }
            across += abs(at(0, line) - at(side - 1, line)) + abs(at(line, 0) - at(line, side - 1))
        }
        #expect(across / Double(side / 16) < 2 * inside / Double(side / 16 * (side - 1)))
    }

    @Test func theAutoCameraHoldsEveryGalaxyAtEveryFrame() {
        var camera = AutoCamera()
        let margins: [Float] = [10, 6, 8]
        for frame in 0..<400 {
            let t = Float(frame) / 400
            let centres = [
                SIMD3<Float>(-60 + 120 * t, 0, 0),
                SIMD3<Float>(60 - 140 * t * t, 30 * t, 5),
                SIMD3<Float>(0, -80 * (1 - t), 0),
            ]
            let framed = camera.frame(centres: centres, margins: margins)
            for (centre, margin) in zip(centres, margins) {
                #expect(simd_distance(centre, framed.center) + margin <= framed.radius + 1e-3)
            }
        }
    }

    @Test func theAutoCameraEasesInsteadOfJumping() {
        var camera = AutoCamera()
        _ = camera.frame(centres: [SIMD3(-20, 0, 0), SIMD3(20, 0, 0)], margins: [5])
        let before = camera.frame(centres: [SIMD3(-20, 0, 0), SIMD3(20, 0, 0)], margins: [5])
        let after = camera.frame(centres: [SIMD3(-20, 0, 0), SIMD3(30, 0, 0)], margins: [5])
        #expect(simd_distance(before.center, after.center) < 6)
    }
}
