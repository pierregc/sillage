import Foundation
import Testing

@testable import SillageCUDA
@testable import SillageCore
@testable import SillageRender

#if canImport(simd)
    import simd
#endif

/// A flight's frames drawn from inside a galaxy on CUDA (#347), on the CPU target at small
/// sizes: what `InsideRenderTests` holds the Metal renderer to (#297), through the same shared
/// functions of `Shaders`, and that a frame which asks for none of it draws to the bit what it
/// drew before the engine's passes held it.
@Suite("CUDA renderer, inside a galaxy")
struct CUDAInsideTests {
    /// A renderer over `positions`, all old stars of one galaxy with a kernel of 50 pc, and the
    /// linear light its particle passes leave.
    private struct Stage {
        let renderer: CUDARenderer
        let width = 160
        let height = 90

        init(
            _ positions: [SIMD3<Float>], maximumKernel: Float = 24, supersample: Int = 1,
            largeCapacity: Int = 0
        ) throws {
            var system = ParticleSystem()
            for position in positions {
                system.append(
                    position: position, velocity: .zero, galaxy: 0, radius: 1, population: 0.5,
                    luminosity: 1, component: .star)
            }
            let scene = SceneConfig.isolatedDisk(particleCount: positions.count)
            renderer = try CUDARenderer(
                context: CUDAContext(), particles: system,
                settings: RenderSettings(
                    width: width, height: height, supersample: supersample,
                    // A fifth of a unit a particle, however many there are.
                    brightness: 2e-7 * Float(positions.count),
                    dustStrength: 0, starCount: 0, smoothingScale: 1, minimumKernel: 1,
                    maximumKernel: maximumKernel, bloomIntensity: 0, stretch: 0, saturation: 1,
                    spikeArms: 0, skyLevel: 0, noiseLevel: 0),
                largeSplatCapacity: largeCapacity, laceTexels: CUDARenderTests.laceTexels)
            renderer.setDiskFrames(DiskFrame.make(scene: scene, centers: [.zero], time: 0, strength: 0))
        }

        /// The light as RGB, pixel by pixel, after a frame through `camera`.
        func light(_ camera: Camera) throws -> [SIMD3<Float>] {
            try renderer.render(camera: camera)
            return try lastLight()
        }

        func lastLight() throws -> [SIMD3<Float>] {
            let values = try renderer.target(.light)
            return stride(from: 0, to: values.count, by: 4).map {
                SIMD3(values[$0], values[$0 + 1], values[$0 + 2])
            }
        }

        func picture(_ cameras: [Camera]) throws -> [UInt8] {
            [UInt8](try renderer.picture(cameras: cameras, format: .rgba))
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

    @Test func theUniformsLieWhereTheKernelsReadThem() {
        #expect(MemoryLayout<InsideSplatUniforms>.stride == 368)
        #expect(MemoryLayout<InsideSplatUniforms>.offset(of: \.inside) == 192)
        #expect(MemoryLayout<InsideUniforms>.stride == 176 && MemoryLayout<InsideUniforms>.alignment == 16)
        #expect(MemoryLayout<InsideUniforms>.offset(of: \.slabKnots) == 64)
        #expect(MemoryLayout<InsideUniforms>.offset(of: \.slabEnd) == 80)
        #expect(MemoryLayout<InsideUniforms>.offset(of: \.starCount) == 140)
        #expect(MemoryLayout<InsideUniforms>.offset(of: \.projectionY) == 148)
        #expect(MemoryLayout<InsideUniforms>.offset(of: \.starTail) == 160)
        #expect(MemoryLayout<InsideUniforms>.offset(of: \.dustTrim) == 172)
    }

    /// With nothing in the near field, a frame set to the inside of a galaxy is the frame every
    /// export draws to a level, the web, the column and the widths included.
    @Test func farFromEverythingTheFrameIsTheExports() throws {
        let scene = SceneConfig.isolatedDisk(particleCount: 20_000)
        let stage = CUDARenderTests.Stage(
            scene: scene, particles: RestrictedSolver.sampleParticles(for: scene),
            camera: Camera.framing(radius: 30, elevation: 0.9), time: 3)
        var settings = CUDARenderTests.settings(320, 180, dust: 0.6, web: 1, column: 8)
        settings.youngWidth = 3
        settings.noiseLevel = 0
        let renderer = try CUDARenderTests.renderer(stage, settings)
        try renderer.render(camera: stage.camera)
        let light = try renderer.fixedTarget(.light)
        let dust = try renderer.fixedTarget(.dust)
        let plain = [UInt8](try renderer.picture(camera: stage.camera, format: .rgba))
        #expect(light.contains { $0 > 0 } && dust.contains { $0 > 0 })

        renderer.inside = Self.inside(60)
        try renderer.render(camera: stage.camera)
        #expect(renderer.starsDrawn == 0)
        let lit = try renderer.fixedTarget(.light)
        let sums = [light, lit].map { $0.reduce(0.0) { $0 + Double($1) } }
        #expect(abs(sums[1] / sums[0] - 1) < 0.01, "\(sums[1] / sums[0])")
        renderer.setGrain(frame: 0)
        let within = [UInt8](try renderer.picture(camera: stage.camera, format: .rgba))
        let most = zip(plain, within).map { abs(Int($0) - Int($1)) }.max() ?? 0
        #expect(plain.contains { $0 > 40 } && most <= 1, "\(most) levels apart")
    }

    /// A particle brought to the eye through the near plane: its light goes down to nothing
    /// without a step, and nothing turns to infinity or to a NaN with the eye on it.
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

        // With its stars, the same bounds; and a picture comes out of each.
        stage.renderer.inside = Self.inside(0.05)
        for distance in distances {
            let light = try stage.light(camera(distance))
            #expect(light.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }, "\(distance)")
            #expect(try stage.picture([camera(distance)]).count == stage.width * stage.height * 4)
        }
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
            settings.starSize = 96  // 8 pixels of the 180 lines drawn: sizes are of a frame 2160 high
            settings.starColours = 0
            // No star held under white, nor drawn around its rank's share.
            settings.starPeak = 1000
            settings.starTail = 0
        }
        stage.renderer.inside = starred
        let first = try stage.light(view)
        #expect(stage.renderer.starsDrawn == 400 * 128)
        let bits = try stage.renderer.fixedTarget(.light)
        try stage.renderer.render(camera: view)
        #expect(try stage.renderer.fixedTarget(.light) == bits)
        #expect(try stage.picture([view]) == stage.picture([view]))

        stage.renderer.inside = Self.inside(0.8) { $0.stars = 0 }
        let splats = try stage.light(view)
        #expect(stage.renderer.starsDrawn == 0)
        #expect(first != splats)
        // Each star stands a little nearer or farther than its particle, and lands on few
        // pixels: the totals agree within a few per cent, not to the bit.
        let ratio = Self.total(first) / Self.total(splats)
        #expect(abs(ratio - 1) < 0.1, "stars over splats \(ratio)")

        // Past the field's far edge, the stars change nothing.
        let far = camera(12)
        stage.renderer.inside = starred
        let beyond = try stage.light(far)
        #expect(stage.renderer.starsDrawn == 0)
        stage.renderer.inside = Self.inside(0.8) { $0.stars = 0 }
        #expect(try stage.light(far) == beyond)
    }

    /// The stars' points set aside and drawn a block each, the second way for large splats,
    /// lay the bits their own threads lay: streaks are the widest points a frame has.
    @Test func bothWaysLayTheSameStars() throws {
        var generator = SeededGenerator(seed: 7)
        let positions = (0..<60).map { _ in
            SIMD3<Float>(generator.uniform() - 0.5, generator.uniform() - 0.5, generator.uniform() - 0.5)
                * 0.4
        }
        let starred = Self.inside(0.8) { settings in
            settings.stars = 16
            settings.starFrom = 0.001
            settings.starFull = 0.002
            settings.starSize = 72  // 3 pixels of the 90 lines drawn
        }
        let (from, to) = (camera(1), Camera(eye: SIMD3(0.1, -1, 0), target: SIMD3(0.1, 100, 0), near: 0.001))
        func light(largeCapacity: Int) throws -> (bits: [UInt64], aside: Int) {
            let stage = try Stage(positions, maximumKernel: 64, largeCapacity: largeCapacity)
            stage.renderer.largeSplatPixels = largeCapacity > 0 ? 16 : 0
            stage.renderer.inside = starred
            _ = try stage.picture([from, to])
            return (try stage.renderer.fixedTarget(.light), stage.renderer.largeSplatCount)
        }
        let first = try light(largeCapacity: 0)
        let second = try light(largeCapacity: 4096)
        #expect(first.bits.contains { $0 > 0 } && second.aside > 0)
        #expect(first.bits == second.bits)
    }

    /// A frame through several cameras is the mean of a render through each but the last: of
    /// one camera again and again, the frame itself; of two, the light of both at half each.
    @Test func aFrameIsTheMeanOfItsRenders() throws {
        var generator = SeededGenerator(seed: 9)
        let positions = (0..<300).map { _ in
            SIMD3<Float>(generator.uniform() - 0.5, generator.uniform() * 0.2, generator.uniform() - 0.5) * 2
        }
        let stage = try Stage(positions)
        stage.renderer.inside = Self.inside(1) { $0.stars = 0 }
        let (a, b) = (camera(3), Camera(eye: SIMD3(0.4, -3, 0), target: SIMD3(0.4, 100, 0), near: 0.001))
        let single = try stage.picture([a])
        let thrice = try stage.picture([a, a, a, a])
        #expect((zip(thrice, single).map { abs(Int($0) - Int($1)) }.max() ?? 9) <= 1)
        let other = try stage.picture([b])
        let both = try stage.picture([a, b, b])
        #expect(both != single && both != other)
        // Before the tone curve the mean is exact: the resolved light of the two renders at
        // half each is half the sum of the light each leaves alone.
        func resolved(_ cameras: [Camera]) throws -> [Float] {
            _ = try stage.picture(cameras)
            return try stage.renderer.postImage(.resolved)
        }
        let (alone, apart, mean) = (try resolved([a]), try resolved([b]), try resolved([a, b, b]))
        var worst: Float = 0
        for index in mean.indices where index % 4 != 3 {
            worst = max(worst, abs(mean[index] - 0.5 * (alone[index] + apart[index])))
        }
        #expect(mean.contains { $0 > 0 } && worst <= 1e-6 * (mean.max() ?? 1), "\(worst)")
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

    /// While the shutter is open a point star is the streak it leaves from one camera to the
    /// next: the same light on more pixels, unbroken from the star's first place to its last.
    @Test func aPointStarIsTheStreakItLeaves() throws {
        let stage = try Stage([.zero], maximumKernel: 64)
        stage.renderer.inside = Self.inside(0.5) { settings in
            settings.stars = 1
            settings.starFrom = 0.001
            settings.starFull = 0.002
            settings.starSpread = 0.01
            settings.starSize = 72  // 3 pixels of the 90 lines drawn
            settings.starColours = 0
        }
        let from = camera(1)
        // The camera slides 150 pc across a star a kiloparsec away: about 22 pixels of 160.
        let to = Camera(eye: SIMD3(0.15, -1, 0), target: SIMD3(0.15, 100, 0), near: 0.001)
        let still = try stage.light(from).map(\.x)
        _ = try stage.picture([from, to])
        let moving = try stage.lastLight().map(\.x)
        let lit = (still.filter { $0 > 0 }.count, moving.filter { $0 > 0 }.count)
        #expect(lit.0 >= 4 && lit.1 > 4 * lit.0, "\(lit)")
        let totals = (still.reduce(0, +), moving.reduce(0, +))
        #expect(abs(totals.1 / totals.0 - 1) < 0.15, "\(totals)")
        // Along the row through its middle, no gap between its two ends.
        let row = stage.height / 2
        let columns = (0..<stage.width).filter { moving[row * stage.width + $0] > 0 }
        let (first, last) = (try #require(columns.first), try #require(columns.last))
        #expect(last - first >= 18 && columns.count == last - first + 1, "\(columns)")
    }

    /// A frame drawn in parts, or from a plan made without its camera, is drawn as every frame
    /// was, as Metal draws a canvas's slices.
    @Test func aFrameDrawnInPartsLeavesTheInsideOut() throws {
        let stage = try Stage([.zero], maximumKernel: 64)
        let view = camera(0.2)
        let plain = try stage.light(view)
        stage.renderer.inside = Self.inside(0.05)
        #expect(try stage.light(view) != plain)
        try stage.renderer.draw(camera: view, particles: 0..<1)
        try stage.renderer.finish()
        #expect(try stage.lastLight() == plain)
        try stage.renderer.draw(stage.renderer.plan(camera: view))
        try stage.renderer.finish()
        #expect(try stage.lastLight() == plain)
    }

    /// Metal's frames of the fixture's flight from inside its disk (#369), within the tolerance
    /// `sillage-cuda check` holds them to.
    @Test(arguments: [2.0, 3.5])
    func theInsideFramesAreMetalsWithinTheTolerance(seconds: Double) throws {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Fixtures/engines")
        let measure = try CUDAEngineCheck.insideMeasure(
            seconds: seconds, context: CUDAContext(), fixtures: fixtures
        ).measure
        let tolerance = CUDAEngineCheck.insideTolerance
        print("CUDAINSIDE", seconds, "s:", measure)
        #expect(measure.psnr >= tolerance.psnr, "\(measure)")
        #expect(measure.largest <= tolerance.largest, "\(measure)")
        #expect(measure.overEight <= tolerance.overEight, "\(measure)")
        #expect(abs(measure.meanA - measure.meanB) < tolerance.mean, "the exposure moved")
    }
}
