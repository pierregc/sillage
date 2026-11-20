import Foundation
import Metal
import SillageCore
import Testing

@testable import SillageRender

#if canImport(simd)
    import simd
#endif

@Suite("Inside a galaxy, drawn")
struct InsideRenderTests {
    /// A renderer over `positions`, all old stars of one galaxy with a kernel of 50 pc, and the
    /// linear light its particle passes leave.
    private struct Stage {
        let renderer: Renderer
        let width = 160
        let height = 90

        init(_ positions: [SIMD3<Float>], maximumKernel: Float = 24, supersample: Int = 1) throws {
            var system = ParticleSystem()
            for position in positions {
                system.append(
                    position: position, velocity: .zero, galaxy: 0, radius: 1, population: 0.5,
                    luminosity: 1, component: .star)
            }
            let scene = SceneConfig.isolatedDisk(particleCount: positions.count)
            renderer = try Renderer(
                particles: system,
                settings: RenderSettings(
                    width: width, height: height, supersample: supersample,
                    // A fifth of a unit a particle, however many there are.
                    brightness: 2e-7 * Float(positions.count),
                    dustStrength: 0, starCount: 0, smoothingScale: 1, minimumKernel: 1,
                    maximumKernel: maximumKernel, bloomIntensity: 0, stretch: 0, saturation: 1,
                    spikeArms: 0, skyLevel: 0, noiseLevel: 0))
            let field = try SmoothingField(device: renderer.device, particleCount: positions.count)
            renderer.setSmoothing(field.buffer)
            renderer.setDiskFrames(DiskFrame.make(scene: scene, centers: [.zero], time: 0, strength: 0))
        }

        /// The light as RGB, pixel by pixel, after a frame through `camera`.
        func light(_ camera: Camera) throws -> [SIMD3<Float>] {
            _ = renderer.render(camera: camera)
            let file = try #require(renderer.particleTargets()?.target.first { $0.name == "light.f16" })
            let halves = file.bytes.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
            return stride(from: 0, to: halves.count, by: 4).map {
                SIMD3(Float(halves[$0]), Float(halves[$0 + 1]), Float(halves[$0 + 2]))
            }
        }
    }

    private static func total(_ light: [SIMD3<Float>]) -> Double {
        light.reduce(0) { $0 + Double($1.x + $1.y + $1.z) }
    }

    private static func inside(_ nearness: Float, _ change: (inout InsideSettings) -> Void = { _ in })
        -> InsideFrame
    {
        var settings = InsideSettings()
        change(&settings)
        return InsideFrame(settings: settings, nearness: nearness)
    }

    private func camera(_ distance: Float) -> Camera {
        Camera(eye: SIMD3(0, -distance, 0), target: SIMD3(0, 100, 0), near: 0.001)
    }

    @Test func theUniformsLieWhereTheShaderReadsThem() {
        #expect(MemoryLayout<SplatUniforms>.stride == 192)
        #expect(MemoryLayout<InsideUniforms>.stride == 96 && MemoryLayout<InsideUniforms>.alignment == 16)
        #expect(MemoryLayout<InsideSplatUniforms>.offset(of: \.inside) == 192)
        #expect(MemoryLayout<InsideUniforms>.offset(of: \.slabEnd) == 16)
        #expect(MemoryLayout<InsideUniforms>.offset(of: \.starCount) == 76)
        #expect(MemoryLayout<InsideUniforms>.offset(of: \.projectionY) == 84)
    }

    /// With nothing in the near field, a frame set to the inside of a galaxy is the frame every
    /// export draws.
    @Test func farFromEverythingTheFrameIsTheExports() throws {
        let scene = SceneConfig.isolatedDisk(particleCount: 20_000)
        let particles = RestrictedSolver.sampleParticles(for: scene)
        var settings = RenderSettings(
            width: 320, height: 180, supersample: 2, brightness: 0.12, dustStrength: 0.6,
            starCount: 200, noiseLevel: 0)
        settings.dustWeb = 1
        settings.youngWidth = 3
        let renderer = try Renderer(particles: particles, settings: settings)
        let field = try SmoothingField(device: renderer.device, particleCount: particles.visibleCount)
        field.update(from: renderer.positions)
        renderer.setSmoothing(field.buffer)
        renderer.time = 3
        renderer.setDiskFrames(DiskFrame.make(scene: scene, centers: [.zero], time: 3, strength: 1))
        var camera = Camera.framing(radius: 30, elevation: 0.9)
        let plain = renderer.render(camera: camera)
        camera.near = 0.001
        renderer.inside = Self.inside(60)
        let within = renderer.render(camera: camera)
        #expect(renderer.insideFailure == nil)
        #expect(renderer.starParticles == 0)
        let most = zip(plain, within).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(plain.contains { $0 > 40 } && most <= 1, "\(most) levels apart")
    }

    /// A particle brought to the eye through the near plane: its light goes down to nothing
    /// without a step, no pixel passes what a half float carries however near it comes, and
    /// nothing turns to infinity or to a NaN with the eye on it.
    @Test func aParticleFadesThroughTheNearPlane() throws {
        let stage = try Stage([.zero])
        stage.renderer.inside = Self.inside(0.05) { $0.stars = 0 }
        // The kernel is 50 pc: the fade runs over the last 150 pc.
        let distances: [Float] = [
            0.4, 0.2, 0.15, 0.12, 0.09, 0.06, 0.03, 0.01, 0.003, 0.0015, 0.001, 0.0005, 0,
        ]
        var totals: [Double] = []
        for distance in distances {
            let light = try stage.light(camera(distance))
            #expect(light.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }, "\(distance)")
            #expect((light.map { max($0.x, $0.y, $0.z) }.max() ?? 0) <= 60_000, "\(distance)")
            totals.append(Self.total(light))
        }
        #expect(totals[0] > 0)
        for index in 2..<totals.count {
            #expect(totals[index] <= totals[index - 1] * 1.001, "\(distances[index]) kpc")
        }
        // Linear in the distance left, so a tenth of it left is about a tenth of the light.
        #expect(abs(totals[7] / totals[4] - (0.01 - 0.001) / (0.09 - 0.001)) < 0.03)
        #expect(totals[10] == 0 && totals[12] == 0)

        // With its stars, the same bounds; and its light is theirs, on a few pixels each.
        stage.renderer.inside = Self.inside(0.05)
        for distance in distances {
            let light = try stage.light(camera(distance))
            #expect(light.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }, "\(distance)")
            let pixels = stage.renderer.render(camera: camera(distance))
            #expect(pixels.count == stage.width * stage.height * 4)
        }
        #expect(stage.renderer.insideFailure == nil)
    }

    /// Without the law a capped kernel keeps all its light and the frame flares as the eye
    /// nears it; with it, it keeps its surface brightness.
    @Test func aCappedKernelKeepsItsSurfaceBrightness() throws {
        let stage = try Stage([.zero])
        func peak(_ distance: Float) throws -> Float {
            try stage.light(camera(distance)).map(\.x).max() ?? 0
        }
        // 50 pc at 200 pc is 36 pixels and at 50 pc 145, both over the ceiling of 24.
        stage.renderer.inside = nil
        let flare = try (peak(0.2), peak(0.05))
        #expect(flare.1 > 10 * flare.0, "\(flare)")
        stage.renderer.inside = Self.inside(0.05) { settings in
            settings.stars = 0
            settings.fade = 0
        }
        let held = try (peak(0.2), peak(0.05))
        #expect(held.1 < 1.3 * held.0 && held.1 > 0.7 * held.0, "\(held)")
        #expect(held.0 < flare.0)
    }

    /// The stars of a particle are the same from one drawing to the next; they carry its light;
    /// and past the near field there are none.
    @Test func pointStarsAreStableCarryTheLightAndStayInTheNearField() throws {
        var generator = SeededGenerator(seed: 5)
        let positions = (0..<400).map { _ in
            SIMD3<Float>(generator.uniform() - 0.5, generator.uniform() - 0.5, generator.uniform() - 0.5)
                * 0.4
        }
        let stage = try Stage(positions, maximumKernel: 64, supersample: 2)
        let view = camera(1)
        // All of the light to the stars, the kernels still under their ceiling: 50 pc at 1 kpc
        // is 7 pixels of the 128 allowed.
        let starred = Self.inside(0.8) { settings in
            settings.starFrom = 0.001
            settings.starFull = 0.002
            settings.starSize = 4
            settings.starColours = 0
        }
        stage.renderer.inside = starred
        let first = try stage.light(view)
        #expect(stage.renderer.starParticles == 400)
        let again = try stage.light(view)
        #expect(first == again)
        #expect(stage.renderer.render(camera: view) == stage.renderer.render(camera: view))

        stage.renderer.inside = Self.inside(0.8) { $0.stars = 0 }
        let splats = try stage.light(view)
        #expect(first != splats)
        // Each star stands a little nearer or farther than its particle, and lands on few
        // pixels: the totals agree within a few per cent, not to the bit.
        let ratio = Self.total(first) / Self.total(splats)
        #expect(abs(ratio - 1) < 0.1, "stars over splats \(ratio)")

        // Past the field's far edge, the stars change nothing.
        let far = camera(12)
        stage.renderer.inside = starred
        let beyond = try stage.light(far)
        #expect(stage.renderer.starParticles == 0)
        stage.renderer.inside = Self.inside(0.8) { $0.stars = 0 }
        #expect(try stage.light(far) == beyond)
    }

    /// A frame averaged from several renders is the mean of them: of one camera, the frame
    /// itself; of two, the light of both at half each.
    @Test func aFrameIsTheMeanOfItsRenders() throws {
        var generator = SeededGenerator(seed: 9)
        let positions = (0..<300).map { _ in
            SIMD3<Float>(generator.uniform() - 0.5, generator.uniform() * 0.2, generator.uniform() - 0.5) * 2
        }
        let stage = try Stage(positions)
        stage.renderer.inside = Self.inside(1) { settings in
            settings.stars = 16
            settings.starColours = 0
        }
        let (a, b) = (camera(3), Camera(eye: SIMD3(0.4, -3, 0), target: SIMD3(0.4, 100, 0), near: 0.001))
        let single = stage.renderer.render(camera: a)
        let thrice = stage.renderer.render(cameras: [a, a, a])
        #expect((zip(thrice, single).map { abs(Int($0) - Int($1)) }.max() ?? 9) <= 1)
        let other = stage.renderer.render(camera: b)
        let both = stage.renderer.render(cameras: [a, b])
        #expect(both != single && both != other)
        // The light of every pixel lies between the two renders', so its picture does too.
        func level(_ pixels: [UInt8], _ at: Int) -> Int {
            Int(pixels[at]) + Int(pixels[at + 1]) + Int(pixels[at + 2])
        }
        var (lit, outside) = (0, 0)
        for at in stride(from: 0, to: both.count, by: 4) {
            let (low, high) = (
                min(level(single, at), level(other, at)), max(level(single, at), level(other, at))
            )
            if high > 0 { lit += 1 }
            if level(both, at) < low - 3 || level(both, at) > high + 3 { outside += 1 }
        }
        #expect(lit > 100 && outside == 0, "\(outside) of \(lit)")
    }
}
