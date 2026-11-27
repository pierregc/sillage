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

        init(
            _ positions: [SIMD3<Float>], maximumKernel: Float = 24, supersample: Int = 1,
            component: ParticleComponent = .star, glow: Float = 0,
            dust: Float = 1e-3, smoothing: Float = 1, first: Float = 1, bloom: Float = 0
        ) throws {
            var system = ParticleSystem()
            for (index, position) in positions.enumerated() {
                system.append(
                    position: position, velocity: .zero, galaxy: 0, radius: 1, population: 0.5,
                    luminosity: index == 0 ? first : 1, component: component)
            }
            let scene = SceneConfig.isolatedDisk(particleCount: positions.count)
            var settings = RenderSettings(
                width: width, height: height, supersample: supersample,
                // A fifth of a unit a particle, however many there are.
                brightness: 2e-7 * Float(positions.count),
                dustStrength: component == .dust ? dust : 0, starCount: 0, smoothingScale: smoothing,
                minimumKernel: 1,
                maximumKernel: maximumKernel, bloomIntensity: bloom, stretch: 0, saturation: 1,
                spikeArms: 0, skyLevel: 0, noiseLevel: 0)
            settings.dustGlow = glow
            renderer = try Renderer(particles: system, settings: settings)
            let field = try SmoothingField(device: renderer.device, particleCount: positions.count)
            renderer.setSmoothing(field.buffer)
            renderer.setDiskFrames(DiskFrame.make(scene: scene, centers: [.zero], time: 0, strength: 0))
        }

        /// The light as RGB, pixel by pixel, after a frame through `camera`.
        func light(_ camera: Camera) throws -> [SIMD3<Float>] {
            _ = renderer.render(camera: camera)
            #expect(renderer.insideFailure == nil)
            let file = try #require(renderer.particleTargets()?.target.first { $0.name == "light.f16" })
            let halves = file.bytes.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
            return stride(from: 0, to: halves.count, by: 4).map {
                SIMD3(Float(halves[$0]), Float(halves[$0 + 1]), Float(halves[$0 + 2]))
            }
        }

        /// The dust's column, all four slabs, pixel by pixel, after a frame through `camera`.
        func dust(_ camera: Camera) throws -> [Float] {
            _ = renderer.render(camera: camera)
            #expect(renderer.insideFailure == nil)
            let file = try #require(renderer.particleTargets()?.target.first { $0.name == "dust.f16" })
            let halves = file.bytes.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
            return stride(from: 0, to: halves.count, by: 4).map {
                Float(halves[$0]) + Float(halves[$0 + 1]) + Float(halves[$0 + 2]) + Float(halves[$0 + 3])
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
        #expect(MemoryLayout<InsideUniforms>.stride == 240 && MemoryLayout<InsideUniforms>.alignment == 16)
        #expect(MemoryLayout<InsideSplatUniforms>.offset(of: \.inside) == 192)
        #expect(MemoryLayout<InsideUniforms>.offset(of: \.slabKnots) == 64)
        #expect(MemoryLayout<InsideUniforms>.offset(of: \.slabEnd) == 80)
        #expect(MemoryLayout<InsideUniforms>.offset(of: \.starCount) == 140)
        #expect(MemoryLayout<InsideUniforms>.offset(of: \.projectionY) == 148)
        #expect(MemoryLayout<InsideUniforms>.offset(of: \.starTail) == 160)
        #expect(MemoryLayout<InsideUniforms>.offset(of: \.dustFine) == 164)
        #expect(MemoryLayout<InsideUniforms>.offset(of: \.dustThin) == 172)
        #expect(MemoryLayout<InsideUniforms>.offset(of: \.webOnly) == 176)
        #expect(MemoryLayout<InsideUniforms>.offset(of: \.neighbours) == 204)
        #expect(MemoryLayout<InsideUniforms>.offset(of: \.loneWidest) == 216)
        #expect(MemoryLayout<InsideUniforms>.offset(of: \.lonePoints) == 220)
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
        #expect(renderer.starsDrawn == 0)
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
            settings.starSize = 96  // 8 pixels of the 180 lines drawn: sizes are of a frame 2160 high
            settings.starColours = 0
            // No star held under white, nor drawn around its rank's share.
            settings.starPeak = 1000
            settings.starTail = 0
        }
        stage.renderer.inside = starred
        let first = try stage.light(view)
        #expect(stage.renderer.starsDrawn == 400 * 128)
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
        // Drawn around their ranks' shares, the same light on the whole; held under white, less.
        var drawn = starred
        drawn.settings.starTail = 1.5
        stage.renderer.inside = drawn
        let tail = Self.total(try stage.light(view)) / Self.total(splats)
        #expect(abs(tail - 1) < 0.1, "with the tail \(tail)")
        drawn.settings.starPeak = 0.5
        stage.renderer.inside = drawn
        #expect(Self.total(try stage.light(view)) < 0.9 * Self.total(first))

        // Past the field's far edge, the stars change nothing.
        let far = camera(12)
        stage.renderer.inside = starred
        let beyond = try stage.light(far)
        #expect(stage.renderer.starsDrawn == 0)
        stage.renderer.inside = Self.inside(0.8) { $0.stars = 0 }
        #expect(try stage.light(far) == beyond)
    }

    /// The near dust (#356): shaped finer than its grains, the same from one drawing to the next,
    /// its column kept on the whole; trimmed once the eye is inside; past the near field as it was.
    @Test func theNearDustIsShapedFinerThanItsGrainsAndKeepsItsColumn() throws {
        var generator = SeededGenerator(seed: 9)
        let positions = (0..<600).map { _ in
            SIMD3<Float>(generator.uniform() - 0.5, generator.uniform() - 0.5, generator.uniform() - 0.5)
                * 0.6
        }
        let stage = try Stage(positions, maximumKernel: 64, supersample: 2, component: .dust)
        let view = camera(0.8)
        func spread(_ column: [Float]) -> (total: Double, contrast: Double) {
            let lit = column.filter { $0 > 0 }
            let mean = lit.reduce(0) { $0 + Double($1) } / Double(max(lit.count, 1))
            let variance = lit.reduce(0) { $0 + pow(Double($1) - mean, 2) } / Double(max(lit.count, 1))
            return (column.reduce(0) { $0 + Double($1) }, variance.squareRoot() / max(mean, 1e-12))
        }
        stage.renderer.inside = Self.inside(0.8) { settings in
            settings.dustFine = 0
            settings.dustInside = 1
        }
        let plain = spread(try stage.dust(view))
        let shaping = Self.inside(0.8) { $0.dustInside = 1 }
        stage.renderer.inside = shaping
        let first = try stage.dust(view)
        #expect(try stage.dust(view) == first)
        let shaped = spread(first)
        #expect(abs(shaped.total / plain.total - 1) < 0.2, "\(shaped.total / plain.total) of \(plain.total)")
        #expect(shaped.contrast > 1.3 * plain.contrast, "\(shaped.contrast) against \(plain.contrast)")
        // Inside, the trim; past `dustWithin`, none.
        stage.renderer.inside = Self.inside(0.1) { $0.dustFine = 0 }
        let trimmed = spread(try stage.dust(view)).total / plain.total
        #expect(abs(trimmed - 0.3) < 0.01, "\(trimmed)")
        stage.renderer.inside = Self.inside(5) { $0.dustFine = 0 }
        #expect(abs(spread(try stage.dust(view)).total / plain.total - 1) < 1e-3)
        // Past the near field's far edge the noise changes nothing.
        let far = camera(12)
        stage.renderer.inside = shaping
        let beyond = try stage.dust(far)
        stage.renderer.inside = Self.inside(0.8) { settings in
            settings.dustFine = 0
            settings.dustInside = 1
        }
        #expect(try stage.dust(far) == beyond)
    }

    /// A near grain's glow spreads into a haze: its light kept, its peak lower, a share of it
    /// taken away by `glowFade`; at 1 the haze draws the grains as they were.
    @Test func aNearGrainsGlowSpreadsIntoAHaze() throws {
        var generator = SeededGenerator(seed: 5)
        let positions = (0..<400).map { _ in
            SIMD3<Float>(generator.uniform() - 0.5, generator.uniform() - 0.5, generator.uniform() - 0.5)
                * 0.6
        }
        let stage = try Stage(positions, maximumKernel: 16, component: .dust, glow: 2, dust: 0.5)
        let view = camera(1.5)
        func drawn(_ change: @escaping (inout InsideSettings) -> Void) throws
            -> (total: Double, peak: Float)
        {
            stage.renderer.inside = Self.inside(1.5) { settings in
                settings.dustFine = 0
                settings.dustInside = 1
                change(&settings)
            }
            let light = try stage.light(view)
            return (Self.total(light), light.map { $0.x }.max() ?? 0)
        }
        let grains = try drawn { _ in }
        #expect(try drawn { $0.glowHaze = 1 }.total == grains.total)
        let haze = try drawn { $0.glowHaze = 4 }
        let faded = try drawn { settings in
            settings.glowHaze = 4
            settings.glowFade = 0.5
        }
        #expect(grains.peak > 0)
        #expect(abs(haze.total / grains.total - 1) < 0.15, "\(haze.total / grains.total)")
        #expect(haze.peak < 0.5 * grains.peak, "\(haze.peak) against \(grains.peak)")
        #expect(abs(faded.total / haze.total - 0.5) < 0.05, "\(faded.total / haze.total)")
        var faulty = InsideSettings()
        faulty.glowHaze = 0.5
        #expect(faulty.fault?.contains("glowHaze") == true)
        faulty = InsideSettings()
        faulty.glowFade = 2
        #expect(faulty.fault?.contains("glowFade") == true)
    }

    /// A kernel that shows alone is widened until it covers its neighbours in projection
    /// (docs/notes/lone-kernels.md): a sparse sheet across the line of sight, past the near field,
    /// every particle a disk of its own, is drawn even, its light kept, its stars and the glow of
    /// its grains alike. Without `neighbours` the frame is the one it was, and stars whose kernels
    /// are under the size asked stay as they were, where a grain's glow is widened at any size.
    @Test func aLoneKernelWidensToCoverItsNeighbours() throws {
        var generator = SeededGenerator(seed: 11)
        // 12 kpc from the eye, 12 pixels a kiloparsec: a particle every 6 pixels or so.
        let positions = (0..<120).map { _ in
            SIMD3<Float>((generator.uniform() - 0.5) * 8, 0, (generator.uniform() - 0.5) * 4)
        }
        let view = camera(12)
        for (component, glow) in [(ParticleComponent.star, Float(0)), (.dust, 2)] {
            let stage = try Stage(
                positions, maximumKernel: 16, component: component, glow: glow, dust: 0.5, smoothing: 5)
            func drawn(_ change: @escaping (inout InsideSettings) -> Void) throws -> [SIMD3<Float>] {
                stage.renderer.inside = Self.inside(12) { settings in
                    settings.loneWidest = 512
                    change(&settings)
                }
                return try stage.light(view)
            }
            // The total, the peak, and how uneven the middle of the sheet is: its light's
            // deviation over its mean.
            func measured(_ light: [SIMD3<Float>]) -> (total: Double, peak: Float, uneven: Double) {
                var values: [Double] = []
                for y in 30..<60 {
                    for x in 50..<110 { values.append(Double(light[y * stage.width + x].x)) }
                }
                let mean = values.reduce(0, +) / Double(values.count)
                let spread = (values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count))
                    .squareRoot()
                return (Self.total(light), light.map { $0.x }.max() ?? 0, spread / max(mean, 1e-12))
            }
            let plain = try drawn { _ in }
            let alone = measured(plain)
            #expect(alone.peak > 0 && alone.uneven > 1, "\(component): \(alone)")
            let merged = measured(try drawn { $0.neighbours = 8 })
            #expect(abs(merged.total / alone.total - 1) < 0.03, "\(component): \(merged.total / alone.total)")
            #expect(merged.uneven < 0.4 * alone.uneven, "\(component): \(merged.uneven), \(alone.uneven)")
            #expect(merged.peak < 0.5 * alone.peak, "\(component): \(merged.peak), \(alone.peak)")
            // A frame 90 high: these kernels are 70 pixels of one 2160 high.
            let points = try drawn { settings in
                settings.neighbours = 8
                settings.loneFrom = 200
                settings.loneFull = 400
            }
            #expect((points == plain) == (component == .star))
        }
        var faulty = InsideSettings()
        faulty.neighbours = -1
        #expect(faulty.fault?.contains("neighbours") == true)
        faulty = InsideSettings()
        faulty.loneFrom = 20
        #expect(faulty.fault?.contains("loneFrom") == true)
        faulty = InsideSettings()
        faulty.loneWidest = 2
        #expect(faulty.fault?.contains("loneWidest") == true)
    }

    /// A star brighter than its neighbours stands that much higher over them at the same width,
    /// so it is widened to cover as many times more of them; and with `lonePoints` the stars
    /// that show alone are points, the bright ones first, where without it they are a haze.
    @Test func aLoneStarIsAHazeOrAPointByItsLight() throws {
        var generator = SeededGenerator(seed: 11)
        var positions = (0..<120).map { _ in
            SIMD3<Float>((generator.uniform() - 0.5) * 8, 0, (generator.uniform() - 0.5) * 4)
        }
        positions[0] = .zero
        let view = camera(12)
        func drawn(first: Float, _ change: @escaping (inout InsideSettings) -> Void) throws
            -> (peak: Float, lit: Int)
        {
            let stage = try Stage(positions, maximumKernel: 16, smoothing: 5, first: first)
            stage.renderer.inside = Self.inside(12) { settings in
                settings.loneWidest = 512
                settings.starPeak = 1000
                change(&settings)
            }
            let light = try stage.light(view).map { $0.x }
            let peak = light.max() ?? 0
            return (peak, light.filter { $0 > 0.1 * peak }.count)
        }
        let even = try drawn(first: 1) { $0.neighbours = 8 }
        let one = try drawn(first: 16) { $0.neighbours = 8 }
        let alone = try drawn(first: 16) { _ in }
        #expect(even.peak > 0 && alone.peak > 8 * even.peak, "\(alone.peak), \(even.peak)")
        #expect(one.peak < 4 * even.peak, "\(one.peak) against \(even.peak)")
        let plain = try drawn(first: 1) { _ in }
        let points = try drawn(first: 1) { settings in
            settings.neighbours = 8
            settings.lonePoints = 1
        }
        #expect(points.peak > 2 * plain.peak, "\(points.peak) against \(plain.peak)")
        #expect(
            points.lit < plain.lit / 2 && even.lit > 2 * plain.lit,
            "\(points.lit), \(plain.lit), \(even.lit)")
        var faulty = InsideSettings()
        faulty.lonePoints = 1.5
        #expect(faulty.fault?.contains("lonePoints") == true)
    }

    /// The point stars bloom by `starBloom` (#510): at 0 a near star throws no halo, the frame
    /// the one drawn with no bloom at all, and at 1 the frame is the one drawn without it.
    @Test func aNearStarBloomsByItsShare() throws {
        var generator = SeededGenerator(seed: 5)
        let positions = (0..<60).map { _ in
            SIMD3<Float>((generator.uniform() - 0.5) * 2, 0, (generator.uniform() - 0.5) * 1)
        }
        let view = camera(1.5)
        func picture(_ change: @escaping (inout InsideSettings) -> Void) throws -> [UInt8] {
            let stage = try Stage(positions, maximumKernel: 4, supersample: 2, bloom: 0.5)
            stage.renderer.inside = Self.inside(1.5) { settings in
                settings.starPeak = 1000
                change(&settings)
            }
            let pixels = stage.renderer.render(camera: view)
            #expect(stage.renderer.insideFailure == nil)
            return pixels
        }
        func lit(_ pixels: [UInt8]) -> Int {
            stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0 + 1] > 8 }.count
        }
        let plain = try picture { _ in }
        let whole = try picture { $0.starBloom = 1 }
        let none = try picture { $0.starBloom = 0 }
        let bare = try Stage(positions, maximumKernel: 4, supersample: 2)
        bare.renderer.inside = Self.inside(1.5) { $0.starPeak = 1000 }
        #expect(whole == plain)
        #expect(none == bare.renderer.render(camera: view))
        #expect(lit(none) < lit(plain), "\(lit(none)) against \(lit(plain))")
        var faulty = InsideSettings()
        faulty.starBloom = 1.5
        #expect(faulty.fault?.contains("starBloom") == true)
        faulty = InsideSettings()
        faulty.heldLengths = -1
        #expect(faulty.fault?.contains("heldLengths") == true)
    }

    /// A near grain carries its structure with it (#394): the grains and the eye moved together
    /// through their galaxy's frame, as a disk's matter and a camera that follows it move while
    /// time runs, draw the same dust.
    @Test func aNearGrainCarriesItsStructureWithIt() throws {
        var generator = SeededGenerator(seed: 9)
        let positions = (0..<600).map { _ in
            SIMD3<Float>(generator.uniform() - 0.5, generator.uniform() - 0.5, generator.uniform() - 0.5)
                * 0.6
        }
        // A sixth of a cell of the noise, which is another structure altogether in a field that stands still.
        let moved = SIMD3<Float>(0.013, -0.007, 0.004)
        func column(_ shift: SIMD3<Float>) throws -> [Float] {
            let stage = try Stage(
                positions.map { $0 + shift }, maximumKernel: 64, supersample: 2, component: .dust)
            stage.renderer.inside = Self.inside(0.8) { $0.dustInside = 1 }
            return try stage.dust(
                Camera(eye: SIMD3(0, -0.8, 0) + shift, target: SIMD3(0, 100, 0) + shift, near: 0.001))
        }
        let first = try column(.zero)
        let second = try column(moved)
        let total = first.reduce(0) { $0 + Double($1) }
        let change = zip(first, second).reduce(0) { $0 + Double(abs($1.0 - $1.1)) } / total
        #expect(total > 0)
        #expect(change < 0.01, "\(change) of the column changed")
    }

    /// Two disks one behind the other, their grains spread over the same slabs (#399): each
    /// galaxy's dust is multiplied by its own web, so the frame's dust is the sum of what each
    /// disk draws alone. With one carrier for both, the web of the later galaxy served both.
    @Test func twoDisksOneBehindTheOtherEachKeepTheirOwnWeb() throws {
        var generator = SeededGenerator(seed: 11)
        // Face on, 3 and 4 kpc from the eye, half over each other across the frame.
        let centres = [SIMD3<Float>(-0.4, 0, 0), SIMD3<Float>(0.4, 1, 0)]
        let grains = centres.map { centre in
            (0..<500).map { _ in
                let radius = 1.2 * generator.uniform().squareRoot()
                let angle = 2 * Float.pi * generator.uniform()
                let height = 0.02 * (generator.uniform() - 0.5)
                return centre + SIMD3(radius * cos(angle), height, radius * sin(angle))
            }
        }
        let frames = centres.enumerated().map { index, centre in
            DiskFrame(
                center: SIMD4(centre, 1), axisU: SIMD4(1, 0, 0, 2), axisV: SIMD4(0, 0, 1, 0),
                pattern: SIMD4(0, 0, 0, Float(index) * 37.4 + 5.1), tint: .zero,
                web: SIMD4(1, 10, Float(index) * 0.618, 0.1))
        }
        // A disk left out keeps its particles where they are, as stars without light, so that
        // the other's grains are drawn with the same kernels in every frame.
        func column(_ galaxies: [Int]) throws -> [Float] {
            var system = ParticleSystem()
            for galaxy in 0..<2 {
                for position in grains[galaxy] {
                    system.append(
                        position: position, velocity: .zero, galaxy: UInt32(galaxy), radius: 1,
                        population: 0.5, luminosity: galaxies.contains(galaxy) ? 1 : 0,
                        component: galaxies.contains(galaxy) ? .dust : .star)
                }
            }
            var settings = RenderSettings(
                width: 160, height: 90, supersample: 2, brightness: 2e-4, dustStrength: 1e-3,
                starCount: 0, smoothingScale: 1, minimumKernel: 1, maximumKernel: 64, bloomIntensity: 0,
                stretch: 0, saturation: 1, spikeArms: 0, skyLevel: 0, noiseLevel: 0)
            settings.dustWeb = 1
            settings.columnSmoothing = 0
            let renderer = try Renderer(particles: system, settings: settings)
            let field = try SmoothingField(device: renderer.device, particleCount: system.count)
            field.update(from: renderer.positions)
            renderer.setSmoothing(field.buffer)
            renderer.setDiskFrames(frames)
            // The eye within the slabs' near distance of matter: the slabs are laid from it, soft.
            renderer.inside = Self.inside(0.1) { settings in
                settings.dustFine = 0
                settings.dustInside = 1
            }
            _ = renderer.render(camera: Camera(eye: SIMD3(0, -3, 0), target: SIMD3(0, 100, 0), near: 0.001))
            #expect(renderer.insideFailure == nil)
            let file = try #require(renderer.particleTargets()?.target.first { $0.name == "dust.f16" })
            let halves = file.bytes.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
            return stride(from: 0, to: halves.count, by: 4).map {
                Float(halves[$0]) + Float(halves[$0 + 1]) + Float(halves[$0 + 2]) + Float(halves[$0 + 3])
            }
        }
        let both = try column([0, 1])
        let first = try column([0])
        let second = try column([1])
        let total = both.reduce(0) { $0 + Double($1) }
        var apart = 0.0
        var shared = 0
        for index in both.indices {
            apart += Double(abs(both[index] - first[index] - second[index]))
            if first[index] > 0 && second[index] > 0 { shared += 1 }
        }
        #expect(total > 0 && shared > 500, "\(shared) pixels hold both disks")
        #expect(apart / total < 0.01, "\(apart / total) of the dust is not its own disk's")
    }

    /// A particle whose kernel covers more of the frame than `nearFrom` stands for more stars, as
    /// the square of its size up to `nearStars`, and they carry the same light (#357).
    @Test func aNearParticleBreaksIntoMoreStars() throws {
        let stage = try Stage([.zero], maximumKernel: 64, supersample: 2)
        func drawn(nearFrom: Float, nearStars: Int = 16_384) throws -> (stars: Int, light: Double) {
            stage.renderer.inside = Self.inside(0.8) { settings in
                settings.starFrom = 0.001
                settings.starFull = 0.002
                settings.nearFrom = nearFrom
                settings.nearStars = nearStars
                settings.starTail = 0
                settings.starColours = 0
            }
            let light = try stage.light(camera(1))
            return (stage.renderer.starsDrawn, Self.total(light))
        }
        // 50 pc at 1 kpc is a few of the 180 lines drawn: far under a third of them.
        let far = try drawn(nearFrom: 0.3)
        #expect(far.stars == 128)
        // Half the size to grow from, four times the stars.
        let (some, more) = (try drawn(nearFrom: 0.02), try drawn(nearFrom: 0.01))
        #expect(some.stars > 128 && more.stars < 16_384, "\(some.stars) \(more.stars)")
        #expect(abs(Double(more.stars) / Double(some.stars) - 4) < 0.1, "\(some.stars) \(more.stars)")
        // No more than allowed, and every count the light of the one particle.
        let held = try drawn(nearFrom: 0.01, nearStars: 1024)
        #expect(held.stars == 1024)
        for light in [some.light, more.light, held.light] {
            #expect(abs(light / far.light - 1) < 0.05, "\(light) against \(far.light)")
        }
    }

    /// A star narrower than a pixel lays all of its light on the pixels it touches, wherever it
    /// falls among them (#357): the light of a frame does not flicker as the stars slide across
    /// the pixel grid.
    @Test func aSmallStarKeepsItsLightAnywhereOnThePixels() throws {
        let stage = try Stage([.zero], maximumKernel: 64)
        var totals: [Double] = []
        for step in 0..<8 {
            stage.renderer.inside = Self.inside(0.5) { settings in
                settings.stars = 1
                settings.starTail = 0
                settings.starFrom = 0.001
                settings.starFull = 0.002
                settings.starSpread = 0.0001
                settings.starSize = 18  // 0.75 of the 90 lines drawn
                settings.starColours = 0
            }
            // An eighth of a pixel further across each time: 1 kpc away, 1 pixel is 7 pc.
            let shift = Float(step) * 0.007 / 8
            let view = Camera(eye: SIMD3(shift, -1, 0), target: SIMD3(shift, 100, 0), near: 0.001)
            let light = try stage.light(view)
            #expect(light.filter { $0.x > 0 }.count <= 4)
            totals.append(Self.total(light))
        }
        let (low, high) = (totals.min() ?? 0, totals.max() ?? 0)
        #expect(low > 0 && high / low < 1.01, "\(totals)")
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
        let single = stage.renderer.render(camera: a)
        let thrice = stage.renderer.render(cameras: [a, a, a, a])
        #expect((zip(thrice, single).map { abs(Int($0) - Int($1)) }.max() ?? 9) <= 1)
        let other = stage.renderer.render(camera: b)
        let both = stage.renderer.render(cameras: [a, b, b])
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
        let point = try stage.light(from)
        _ = stage.renderer.render(cameras: [from, to])
        let file = try #require(
            stage.renderer.particleTargets()?.target.first { $0.name == "light.f16" })
        let halves = file.bytes.withUnsafeBytes { Array($0.bindMemory(to: Float16.self)) }
        let streak = stride(from: 0, to: halves.count, by: 4).map { Float(halves[$0]) }
        let (still, moving) = (point.map(\.x), streak)
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
}
