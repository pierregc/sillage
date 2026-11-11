import Foundation
import Testing

@testable import SillageCUDA
@testable import SillageCore
@testable import SillageRender

#if canImport(simd)
    import simd
#endif

private let onAGPU = CUDAContext.runsEveryKernel
private let needsAGPU: Comment = "needs an NVIDIA GPU and libsillagecuda.a: #283 runs it"

/// The renderer's particle passes on CUDA (#276), drawn here on the CPU target at small sizes:
/// the same frame plan as the Metal renderer, the shared functions of `Shaders`, and the
/// accumulation in fixed point. Against Metal's own targets the comparison is
/// `CUDARenderChecks`, which needs the files of the `assets/cuda-checks` branch.
@Suite("CUDA renderer")
struct CUDARenderTests {
    /// A small lace: the web's pattern is coarser, the passes are the same.
    static let laceTexels = 256

    struct Stage {
        var scene: SceneConfig
        var particles: ParticleSystem
        var camera: Camera
        var time: Float = 0

        static func merger(_ count: Int = 12_000) -> Stage {
            let scene = SceneConfig.merger(particleCount: count)
            return Stage(
                scene: scene, particles: RestrictedSolver.sampleParticles(for: scene),
                camera: Camera.framing(radius: 80))
        }

        static func disk(_ count: Int = 12_000) -> Stage {
            let scene = SceneConfig.isolatedDisk(particleCount: count)
            return Stage(
                scene: scene, particles: RestrictedSolver.sampleParticles(for: scene),
                camera: Camera.framing(radius: 20, elevation: 1.2), time: 3)
        }
    }

    static func settings(
        _ width: Int = 160, _ height: Int = 90, dust: Float = 0.5, stars: Int = 200, web: Float = 0,
        column: Float = 0
    ) -> RenderSettings {
        var settings = RenderSettings(
            width: width, height: height, supersample: 2, brightness: 0.12, dustStrength: dust,
            starCount: stars)
        settings.dustWeb = web
        settings.columnSmoothing = column
        return settings
    }

    /// A renderer over a stage's particles, with the smoothing lengths the tree gives them.
    static func renderer(
        _ stage: Stage, _ settings: RenderSettings, largeCapacity: Int = 0
    ) throws -> CUDARenderer {
        let context = try CUDAContext()
        let renderer = try CUDARenderer(
            context: context, particles: stage.particles, settings: settings,
            largeSplatCapacity: largeCapacity, laceTexels: laceTexels)
        let drawn = renderer.drawnCount
        let builder = try CUDATreeBuilder(
            context: context, count: stage.particles.count, leafCapacity: 24,
            nodeCapacity: stage.particles.count / 4 + 1024)
        try builder.buildCells(positions: renderer.positions)
        let lengths = try context.makeBuffer(length: stage.particles.count * 4)
        try builder.buildSmoothing(into: lengths, drawn: drawn)
        try renderer.setSmoothing(lengths)
        renderer.time = stage.time
        renderer.setDiskFrames(
            DiskFrame.make(
                scene: stage.scene, centers: stage.scene.galaxies.map(\.position), time: stage.time,
                strength: 1))
        return renderer
    }

    static func total(_ values: [Float], channel: Int, of channels: Int = 4) -> Double {
        stride(from: channel, to: values.count, by: channels).reduce(0.0) { $0 + Double(values[$1]) }
    }

    // MARK: - The same bits

    @Test func aFrameDrawnTwiceIsTheSameToTheBit() throws {
        let stage = Stage.merger()
        let settings = Self.settings()
        let first = try Self.renderer(stage, settings)
        try first.render(camera: stage.camera)
        let light = try first.fixedTarget(.light)
        let dust = try first.fixedTarget(.dust)
        #expect(light.contains { $0 > 0 } && dust.contains { $0 > 0 })

        try first.render(camera: stage.camera)
        #expect(try first.fixedTarget(.light) == light)
        #expect(try first.fixedTarget(.dust) == dust)

        let second = try Self.renderer(stage, settings)
        try second.render(camera: stage.camera)
        #expect(try second.fixedTarget(.light) == light)
        #expect(try second.fixedTarget(.dust) == dust)
        #expect(try second.target(.light) == first.target(.light))
    }

    /// Integer atomics that saturate do not care in what order the threads add: five threads
    /// drawing each pass at once leave the bits one thread leaves.
    @Test func theOrderTheThreadsRunInChangesNoBit() throws {
        let stage = Stage.merger()
        let settings = Self.settings(web: 1, column: 8)
        let alone = try Self.renderer(stage, settings)
        try alone.render(camera: stage.camera)
        let together = try Self.renderer(stage, settings)
        try together.render(camera: stage.camera, threads: 5)
        #expect(try together.fixedTarget(.light) == alone.fixedTarget(.light))
        #expect(try together.fixedTarget(.dust) == alone.fixedTarget(.dust))
        #expect(try together.target(.carrier) == alone.target(.carrier))
        #expect(try together.target(.tags) == alone.target(.tags))
        #expect(try together.target(.column) == alone.target(.column))
    }

    /// A frame drawn in parts, the dust of every part before the stars of any, as
    /// `Renderer.render(camera:slice:)` cuts it.
    @Test func aSlicedFrameIsTheSameToTheBit() throws {
        let stage = Stage.merger()
        let renderer = try Self.renderer(stage, Self.settings())
        try renderer.render(camera: stage.camera)
        let light = try renderer.fixedTarget(.light)
        let dust = try renderer.fixedTarget(.dust)

        let total = renderer.drawnCount
        var first = true
        for stage_ in UInt32(0)...1 {
            for start in stride(from: 0, to: total, by: 2_500) {
                try renderer.draw(
                    camera: stage.camera, particles: start..<min(start + 2_500, total),
                    stages: stage_...stage_, first: first)
                first = false
            }
        }
        try renderer.finish()
        #expect(try renderer.fixedTarget(.light) == light)
        #expect(try renderer.fixedTarget(.dust) == dust)
    }

    /// The second way for large splats, a block of threads a splat set aside, lays what the
    /// first way lays, whatever the size past which a splat is set aside and however short the
    /// list is.
    @Test func bothWaysForLargeSplatsLayTheSameBits() throws {
        let stage = Stage.disk()
        let settings = Self.settings(web: 1)
        let firstWay = try Self.renderer(stage, settings)
        try firstWay.render(camera: stage.camera)
        let light = try firstWay.fixedTarget(.light)
        let dust = try firstWay.fixedTarget(.dust)

        for (capacity, pixels) in [(20_000, 64), (20_000, 1), (37, 16)] {
            let secondWay = try Self.renderer(stage, settings, largeCapacity: capacity)
            secondWay.largeSplatPixels = pixels
            try secondWay.render(camera: stage.camera)
            #expect(secondWay.largeSplatCount > 0, "no splat over \(pixels) pixels")
            #expect(try secondWay.fixedTarget(.light) == light, "\(capacity) splats of \(pixels)")
            #expect(try secondWay.fixedTarget(.dust) == dust, "\(capacity) splats of \(pixels)")
        }
    }

    // MARK: - What a splat lays

    /// One star alone: its coverage is the kernel's integral over the point's disc, and its
    /// light the same times its colour.
    @Test func aStarLaysItsWholeKernel() throws {
        var particles = ParticleSystem(capacity: 1)
        particles.append(position: .zero, velocity: .zero, galaxy: 0, radius: 1)
        var settings = RenderSettings(
            width: 64, height: 64, supersample: 1, starCount: 0, minimumKernel: 20, maximumKernel: 20)
        settings.glint = 1
        let renderer = try CUDARenderer(
            context: CUDAContext(), particles: particles, settings: settings,
            laceTexels: Self.laceTexels)
        // Off the pixel grid, so no pixel centre sits on the kernel's edge.
        let camera = Camera(eye: SIMD3(0.013, -50, 0.007), target: SIMD3(0.013, 0, 0.007))
        try renderer.render(camera: camera)
        let light = try renderer.target(.light)
        let coverage = Self.total(light, channel: 3)
        let integral = Double.pi * 100 * (1 - exp(-4.5)) / 4.5
        #expect(abs(coverage / integral - 1) < 0.01, "\(coverage) against \(integral)")
        #expect(try renderer.target(.dust).allSatisfy { $0 == 0 })
        // The point is 20 pixels wide and no wider.
        let lit = stride(from: 3, to: light.count, by: 4).filter { light[$0] > 0 }.count
        #expect(abs(Double(lit) / (Double.pi * 100) - 1) < 0.05)
    }

    /// A grain of dust dims a star behind it and leaves alone one in front.
    @Test func dustDimsOnlyWhatStandsBehindIt() throws {
        func light(star depth: Float, grain: Bool) throws -> Double {
            var particles = ParticleSystem(capacity: 2)
            particles.append(position: SIMD3(0, depth, 0), velocity: .zero, galaxy: 0, radius: 1)
            // Dark matter in the grain's place keeps the count the exposure divides by.
            particles.append(
                position: .zero, velocity: .zero, galaxy: 0, radius: 1,
                formation: ParticleSystem.unformed, component: grain ? .dust : .halo)
            var settings = RenderSettings(
                width: 64, height: 64, supersample: 1, dustStrength: 4_000, starCount: 0,
                minimumKernel: 12, maximumKernel: 12)
            settings.glint = 1
            let renderer = try CUDARenderer(
                context: CUDAContext(), particles: particles, settings: settings,
                laceTexels: Self.laceTexels)
            try renderer.render(camera: Camera(eye: SIMD3(0, -50, 0), target: .zero))
            if grain { #expect(try renderer.target(.dust).contains { $0 > 0 }) }
            return Self.total(try renderer.target(.light), channel: 0)
        }
        // The slabs are stacked about the camera's target: 15 kpc behind it is another slab.
        let behind = try light(star: 15, grain: true)
        let behindClear = try light(star: 15, grain: false)
        let ahead = try light(star: -15, grain: true)
        let aheadClear = try light(star: -15, grain: false)
        #expect(behindClear > 0 && aheadClear > 0)
        #expect(behind < 0.9 * behindClear, "\(behind) against \(behindClear)")
        #expect(ahead == aheadClear)
    }

    @Test func plainPointsKeepEachGalaxyInItsOwnTint() throws {
        var stage = Stage.merger()
        stage.scene.galaxies[0].color = SIMD3(1, 0, 0)
        stage.scene.galaxies[1].color = SIMD3(0, 0, 1)
        let renderer = try Self.renderer(
            stage,
            RenderSettings(
                width: 160, height: 90, supersample: 1, brightness: 0.12, starCount: 0,
                minimumKernel: 1.5, maximumKernel: 1.5, plain: true))
        renderer.setDiskFrames(
            DiskFrame.make(
                scene: stage.scene, centers: stage.scene.galaxies.map(\.position), time: 0,
                strength: 0))
        try renderer.render(camera: stage.camera)
        let light = try renderer.target(.light)
        #expect(Self.total(light, channel: 0) > 0 && Self.total(light, channel: 2) > 0)
        #expect(Self.total(light, channel: 1) == 0)
        // A point of the raw look counts for one on every pixel of its square.
        let coverage = Self.total(light, channel: 3)
        #expect(coverage == coverage.rounded() && coverage >= Double(renderer.drawnCount) / 2)
    }

    /// The dust web changes how the dust is drawn and nothing else: with no dust, no web.
    @Test func theDustWebMovesOnlyTheDust() throws {
        let stage = Stage.disk()
        func draw(dust: Float, web: Float) throws -> (light: [UInt64], dust: [Float]) {
            let renderer = try Self.renderer(stage, Self.settings(dust: dust, stars: 0, web: web))
            try renderer.render(camera: stage.camera)
            return (try renderer.fixedTarget(.light), try renderer.target(.dust))
        }
        let webbed = try draw(dust: 0.6, web: 1)
        let grains = try draw(dust: 0.6, web: 0)
        #expect(webbed.light != grains.light)
        #expect(try draw(dust: 0, web: 1).light == draw(dust: 0, web: 0).light)
        // The web moves no exposure: the dust it lays is the dust the grains carry, to a few
        // per cent of a small lace's own mean.
        let (a, b) = (Self.total(webbed.dust, channel: 0), Self.total(grains.dust, channel: 0))
        let (c, d) = (Self.total(webbed.dust, channel: 1), Self.total(grains.dust, channel: 1))
        #expect(a + c > 0 && abs((a + c) / (b + d) - 1) < 0.25, "\(a + c) against \(b + d)")
    }

    /// The column pass counts every particle that emits, once, and a kernel sized from it is
    /// never narrower than the tree's.
    @Test func theColumnCountsWhatEmitsAndWidensItsKernels() throws {
        let stage = Stage.merger()
        let plain = try Self.renderer(stage, Self.settings(stars: 0))
        try plain.render(camera: stage.camera)
        let counted = try Self.renderer(stage, Self.settings(stars: 0, column: 8))
        try counted.render(camera: stage.camera)

        let emitting = (0..<counted.drawnCount).filter { index in
            ParticleComponent(rawValue: stage.particles.component[index])?.emits ?? false
        }.count
        let cells = try counted.target(.column)
        #expect(cells.allSatisfy { $0 == $0.rounded() })
        let inside = Self.total(cells, channel: 0, of: 1)
        #expect(inside > 0.9 * Double(emitting) && inside <= Double(emitting))
        let wide = Self.total(try counted.target(.light), channel: 3)
        let narrow = Self.total(try plain.target(.light), channel: 3)
        #expect(wide > narrow)
    }

    /// Drawn from 32 bytes each with their kernels off the massive tree, the tracers make the
    /// picture the same particles make drawn whole (#238), as `LightTracerTests` asks of Metal.
    @Test func tracersDrawLikeTheParticlesTheyStandFor() throws {
        var drawnScene = SceneConfig.isolatedDisk(particleCount: 24_000)
        drawnScene.solver = .barnesHut
        var massiveScene = SceneConfig.isolatedDisk(particleCount: 6_000)
        massiveScene.solver = .barnesHut
        let (split, tracers) = ParticleSystem.lightTracers(drawn: drawnScene, massive: massiveScene)
        let settings = RenderSettings(width: 160, height: 96, supersample: 2, starCount: 0)
        let camera = Camera.framing(radius: 30, elevation: 0.6)
        let frames = DiskFrame.make(scene: massiveScene, centers: [.zero], time: 0, strength: 1)
        let context = try CUDAContext()

        // The tracers as the solver holds them, and the massive tree's lengths and records.
        let massive = split.slice(tracers..<split.count)
        let massiveVisible = massive.visibleCount
        var states: [SIMD4<Float>] = []
        var motions: [SIMD4<UInt32>] = []
        for index in 0..<tracers {
            let position = split.positions[index]
            states.append(SIMD4(position.x, position.y, position.z, split.formation[index]))
            let word = TracerWord(
                galaxy: split.galaxyIndex[index], component: split.component[index],
                kernelScale: split.kernelScale[index], luminosity: split.luminosity[index],
                birthRadius: split.birthRadius[index])
            motions.append(SIMD4(0, 0, 0, word.bits))
        }
        let compact = try CUDARenderer(
            context: context, particles: massive, settings: settings, laceTexels: Self.laceTexels)
        let builder = try CUDATreeBuilder(
            context: context, count: massive.count, leafCapacity: 16, nodeCapacity: massive.count)
        try builder.buildCells(positions: compact.positions)
        let ratio = Float(tracers + massiveVisible) / Float(max(massiveVisible, 1))
        let lengths = try context.makeBuffer(length: massive.count * 4)
        try builder.buildSmoothing(into: lengths, drawn: massiveVisible, ratio: ratio)
        try builder.buildSpacing(drawn: massiveVisible, ratio: ratio)
        try compact.setSmoothing(lengths)
        compact.setTracers(
            CUDARenderer.Tracers(
                states: try context.makeBuffer(states), motions: try context.makeBuffer(motions),
                count: tracers, cells: try #require(builder.spacing), treeFrame: builder.frame,
                depth: builder.maximumDepth))
        compact.setDiskFrames(frames)
        try compact.render(camera: camera)
        let traced = try compact.target(.light)

        let whole = try CUDARenderer(
            context: context, particles: split, settings: settings, laceTexels: Self.laceTexels)
        let wholeBuilder = try CUDATreeBuilder(
            context: context, count: split.count, leafCapacity: 24, nodeCapacity: split.count)
        try wholeBuilder.buildCells(positions: whole.positions)
        let wholeLengths = try context.makeBuffer(length: split.count * 4)
        try wholeBuilder.buildSmoothing(into: wholeLengths, drawn: split.visibleCount)
        try whole.setSmoothing(wholeLengths)
        whole.setDiskFrames(frames)
        try whole.render(camera: camera)
        let expected = try whole.target(.light)

        func blocks(_ pixels: [Float]) -> [Double] {
            var sums = [Double](repeating: 0, count: (320 / 16) * (192 / 16))
            for y in 0..<192 {
                for x in 0..<320 {
                    let base = (y * 320 + x) * 4
                    sums[(y / 16) * 20 + x / 16] +=
                        Double(pixels[base]) + Double(pixels[base + 1]) + Double(pixels[base + 2])
                }
            }
            return sums
        }
        let a = blocks(traced)
        let b = blocks(expected)
        let meanA = a.reduce(0, +) / Double(a.count)
        let meanB = b.reduce(0, +) / Double(b.count)
        #expect(meanB > 0)
        #expect(abs(meanA / meanB - 1) < 0.2, "\(meanA) against \(meanB)")
        var covariance = 0.0
        var varianceA = 0.0
        var varianceB = 0.0
        for (x, y) in zip(a, b) {
            covariance += (x - meanA) * (y - meanB)
            varianceA += (x - meanA) * (x - meanA)
            varianceB += (y - meanB) * (y - meanB)
        }
        #expect(covariance / (varianceA * varianceB).squareRoot() > 0.95)
    }

    // MARK: - The plan and its limits

    /// Each kind of frame draws the passes `Renderer.encodeSplat` drew, in its order.
    @Test func aFramesPassesAreItsLooks() {
        let camera = Camera.framing(radius: 80)
        func passes(
            _ settings: RenderSettings, lace: Float? = 1, stages: ClosedRange<UInt32> = 0...1,
            first: Bool = true
        ) -> [FramePlan.Pass] {
            FramePlan(
                settings: settings, camera: camera, time: 0, drawnCount: 1_000, tracerCount: 0,
                luminosityNormalisation: 1, mapped: false, laceScale: lace, stages: stages,
                first: first
            ).passes
        }
        #expect(passes(Self.settings()) == [.starfield, .dust, .stars])
        #expect(passes(Self.settings(stars: 0, column: 8)) == [.column, .dust, .stars])
        #expect(
            passes(Self.settings(web: 1))
                == [.webCarrier, .starfield, .paintedDust, .webResolve, .stars])
        // A renderer that could not bake the lace draws the dust as it always was.
        #expect(passes(Self.settings(web: 1), lace: nil) == [.starfield, .dust, .stars])
        #expect(passes(Self.settings(web: 1, column: 8), stages: 1...1, first: false) == [.stars])
        #expect(
            passes(Self.settings(web: 1, column: 8), stages: 0...0, first: false)
                == [.webCarrier, .paintedDust, .webResolve])
        var plain = Self.settings()
        plain.plain = true
        #expect(passes(plain) == [.plain])
        #expect(FramePlan.Pass.allCases.count == 8)
        #expect(MemoryLayout<SplatUniforms>.stride == 176 && MemoryLayout<WebUniforms>.stride == 112)
    }

    /// A pixel that takes more than the target holds stays at its ceiling: 2^24 units of light.
    @Test func aPixelSaturatesRatherThanWrap() throws {
        var particles = ParticleSystem(capacity: 64)
        for _ in 0..<64 {
            particles.append(position: .zero, velocity: .zero, galaxy: 0, radius: 1, luminosity: 1e30)
        }
        var settings = RenderSettings(
            width: 16, height: 16, supersample: 1, brightness: 1e30, starCount: 0, minimumKernel: 4,
            maximumKernel: 4)
        settings.glint = 1
        let renderer = try CUDARenderer(
            context: CUDAContext(), particles: particles, settings: settings,
            laceTexels: Self.laceTexels)
        try renderer.render(camera: Camera(eye: SIMD3(0.01, -50, 0.01), target: SIMD3(0.01, 0, 0.01)))
        let fixed = try renderer.fixedTarget(.light)
        #expect(fixed.max() == UInt64.max)
        #expect(CUDARenderer.fixedUnit == 1 << 40)
        let light = try renderer.target(.light)
        #expect(light.max() == Float(UInt64.max) / Float(1 << 40))
        #expect(light.allSatisfy { $0.isFinite })
    }

    // MARK: - The measures #283 makes, small

    /// Half floats as Metal blends them hold a star's light to their own precision, and lose
    /// the light that falls under their smallest value.
    @Test func halfFloatsHoldLessThanFixedPoint() throws {
        func light(brightness: Float, halves: Bool) throws -> [Float] {
            var particles = ParticleSystem(capacity: 1)
            particles.append(position: .zero, velocity: .zero, galaxy: 0, radius: 1)
            var settings = RenderSettings(
                width: 64, height: 64, supersample: 1, brightness: brightness, starCount: 0,
                minimumKernel: 20, maximumKernel: 20)
            settings.glint = 1
            let renderer = try CUDARenderer(
                context: CUDAContext(), particles: particles, settings: settings,
                laceTexels: Self.laceTexels)
            renderer.halfFloats = halves
            try renderer.render(camera: Camera(eye: SIMD3(0.013, -50, 0.007), target: SIMD3(0.013, 0, 0.007)))
            return try renderer.target(.light)
        }
        // One splat a pixel: a half float holds what the fixed point holds, to 11 bits.
        let fixed = try light(brightness: 0.15, halves: false)
        let halves = try light(brightness: 0.15, halves: true)
        var compared = 0
        for (a, b) in zip(fixed, halves) where a > 1e-3 {
            #expect(abs(b / a - 1) < 0.0005, "\(b) against \(a)")
            // A half float has 11 significant bits.
            let scaled = b / b.binade * 1024
            #expect(scaled == scaled.rounded())
            compared += 1
        }
        #expect(compared > 500)
        // Under half the smallest half float, 3e-8, the light is gone; fixed point keeps it.
        let faint = try light(brightness: 1e-10, halves: false)
        let lost = try light(brightness: 1e-10, halves: true)
        #expect(Self.total(faint, channel: 0) > 0)
        #expect(Self.total(lost, channel: 0) == 0)
    }

    /// The measures #283 runs at 4K and up to 200 M drawn, at a size the CPU target draws:
    /// they run, and say what they are asked to say.
    @Test func theMeasuresOfABoxRunSmall() throws {
        let faint = try CUDARenderChecks.faintLight(
            drawn: 20_000, width: 160, height: 90, laceTexels: Self.laceTexels)
        #expect(faint.count > 5 && faint.contains { $0.contains("half floats keep") })
        let timed = try CUDARenderChecks.timings(
            drawn: 20_000, width: 160, height: 90, repeats: 1, largeSplatPixels: 64,
            laceTexels: Self.laceTexels)
        #expect(timed.count == 5 && timed.contains { $0.contains("second way") })
    }

    // MARK: - On a GPU, in #283

    /// The faint light at 200 M drawn, where a particle carries 0.005 of the light: the
    /// sampler's starting positions accumulated in half floats as Metal blends them, and in
    /// fixed point. Printed, for #283 to say what half floats lose. `SILLAGE_CUDA_RENDER_COUNT`
    /// draws another count.
    @Test(.enabled(if: onAGPU, needsAGPU))
    func theFaintLightAt200MSurvivesTheAccumulation() throws {
        let count =
            Int(ProcessInfo.processInfo.environment["SILLAGE_CUDA_RENDER_COUNT"] ?? "") ?? 200_000_000
        for line in try CUDARenderChecks.faintLight(drawn: count) { print("CUDARENDER", line) }
    }

    /// The time of the particle passes at 4K at 8 M, 50 M and 200 M drawn, both ways for large
    /// splats, wide and close, against Metal's 40 ms + 7.6 ns a particle a 4K frame (#239).
    @Test(.enabled(if: onAGPU, needsAGPU))
    func theParticlePassesAreTimed() throws {
        for count in [8_000_000, 50_000_000, 200_000_000] {
            for line in try CUDARenderChecks.timings(drawn: count) { print("CUDARENDER", line) }
        }
    }
}
