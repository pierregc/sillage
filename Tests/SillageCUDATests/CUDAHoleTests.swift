import Foundation
import Testing

@testable import SillageCUDA
@testable import SillageCore
@testable import SillageRender

#if canImport(simd)
    import simd
#endif

/// The black hole close up on CUDA (#336), run here on the CPU target against what Metal gave
/// in `Tests/Fixtures/hole`: the run stepped on from a moment of it, and three stills of the
/// moment Metal reached. docs/notes/cuda-engine.md gives the measures.
@Suite("CUDA black hole")
struct CUDAHoleTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Tests/Fixtures/hole")

    struct Manifest: Decodable {
        struct View: Decodable {
            var look: String
            var file: String
        }

        var tracers: Int
        var gas: GasGrid
        var startStep: Int
        var steps: Int
        var width: Int
        var height: Int
        var views: [View]
    }

    static func manifest() throws -> Manifest {
        try JSONDecoder().decode(
            Manifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
    }

    static func scene() throws -> TidalDisruption {
        try JSONDecoder().decode(
            HoleSceneFile.self, from: Data(contentsOf: folder.appendingPathComponent("scene.json"))
        ).blackHole
    }

    static func frame(_ name: String, tracers: Int) throws -> TidalFrame {
        let data = try Data(contentsOf: folder.appendingPathComponent(name))
        let values = data.withUnsafeBytes { Array($0.bindMemory(to: SIMD4<Float>.self)) }
        #expect(values.count == 2 * tracers)
        return TidalFrame(
            time: 0, positions: Array(values[0..<tracers]), velocities: Array(values[tracers..<(2 * tracers)])
        )
    }

    /// The lens tables, built once for every test: on the CPU of a test build they take seconds.
    static let lenses = HoleLensSet()

    static func look(_ view: Manifest.View) throws -> HoleLookFile {
        try HoleLookFile.decoded(from: Data(contentsOf: folder.appendingPathComponent(view.look)))
    }

    /// What CUDA's run is held to after Metal's 40 steps: the same tracers swallowed, the
    /// positions and velocities within a share of their size (measured 5.5e-7 and 4.7e-6), and
    /// the light looser. The viscosity's heat is `1 - keep²` with `keep = exp(-ε)` and ε about
    /// 1e-6, the difference of two floats near one, which two maths libraries round apart by a
    /// few percent of it: the light's largest difference was 1.2 % of the brightest, its mean
    /// 2.9 % of the mean light (docs/notes/cuda-engine.md).
    static let positionTolerance: Float = 1e-5
    static let velocityTolerance: Float = 1e-4
    static let lightTolerance: (largest: Float, mean: Double) = (0.05, 0.1)

    @Test func theRunStepsAsMetalsWithinTheTolerance() throws {
        let manifest = try Self.manifest()
        let start = try Self.frame("start.bin", tracers: manifest.tracers)
        let end = try Self.frame("end.bin", tracers: manifest.tracers)
        let run = try CUDATidalRun(context: CUDAContext(), scene: Self.scene(), gas: manifest.gas)
        run.resume(from: start, step: manifest.startStep)
        run.step(manifest.steps)
        #expect(run.failure == nil)
        let stepped = run.frame
        var position: Float = 0
        var velocity: Float = 0
        var light: Float = 0
        var brightest: Float = 0
        var swallowed = (cuda: 0, metal: 0)
        var lightDifference = 0.0
        var lightTotal = 0.0
        var lightOff = 0
        for index in 0..<manifest.tracers {
            let (a, b) = (stepped.positions[index], end.positions[index])
            let (va, vb) = (stepped.velocities[index], end.velocities[index])
            if va.w < 0 { swallowed.cuda += 1 }
            if vb.w < 0 { swallowed.metal += 1 }
            let at = SIMD3<Float>(b.x, b.y, b.z)
            let moving = SIMD3<Float>(vb.x, vb.y, vb.z)
            position = max(position, simd_length(SIMD3<Float>(a.x, a.y, a.z) - at) / max(simd_length(at), 1))
            velocity = max(
                velocity,
                simd_length(SIMD3<Float>(va.x, va.y, va.z) - moving) / max(simd_length(moving), 0.01))
            light = max(light, abs(a.w - b.w))
            brightest = max(brightest, b.w)
            lightDifference += Double(abs(a.w - b.w))
            lightTotal += Double(b.w)
            if abs(a.w - b.w) > 0.01 * max(b.w, 1e-30) { lightOff += 1 }
        }
        print(
            "CUDAHOLE run", manifest.steps, "steps:", "position", position, "velocity", velocity, "light",
            light / max(brightest, 1e-30), "mean light", lightDifference / max(lightTotal, 1e-30),
            "tracers 1 % off",
            lightOff, "swallowed", swallowed)
        #expect(swallowed.cuda == swallowed.metal)
        #expect(
            position < Self.positionTolerance && velocity < Self.velocityTolerance, "\(position), \(velocity)"
        )
        #expect(light <= Self.lightTolerance.largest * brightest, "\(light) of \(brightest)")
        #expect(
            lightDifference <= Self.lightTolerance.mean * lightTotal, "\(lightDifference) of \(lightTotal)")
        #expect(brightest > 0, "a run with no heat checks nothing of the gas")
    }

    /// What a still is held to against Metal's: its PSNR, its largest difference in levels, and
    /// the share of its pixels more than 8 levels off. Measured 54.7 to 55.2 dB, 17 to 31 levels
    /// and 0.084 %: the film grain's hash landing the other side of a rounding on a few pixels,
    /// as in #277's stills, and Metal's half floats.
    static let stillTolerances: [String: (psnr: Double, largest: Int, overEight: Double)] = [
        "physics": (50, 48, 0.002),
        "ring": (50, 48, 0.002),
        "straight": (50, 48, 0.002),
    ]

    @Test func theStillsAreMetalsWithinTheTolerance() throws {
        let manifest = try Self.manifest()
        let end = try Self.frame("end.bin", tracers: manifest.tracers)
        let context = try CUDAContext()
        for view in manifest.views {
            let look = try Self.look(view)
            let renderer = try CUDAHoleRenderer(
                context: context, settings: look.settings(width: manifest.width, height: manifest.height))
            renderer.lenses = Self.lenses
            try renderer.upload(end)
            let drawn = [UInt8](
                try renderer.render(camera: look.camera.camera(progress: 0), look: look.renderLook))
            let reference = [UInt8](try Data(contentsOf: Self.folder.appendingPathComponent(view.file)))
            let measure = CUDAStillChecks.measure(drawn, channels: 3, reference, channels: 3)
            print("CUDAHOLE still", look.name, measure)
            let tolerance = try #require(Self.stillTolerances[look.name])
            #expect(measure.psnr >= tolerance.psnr, "\(look.name): \(measure)")
            #expect(measure.largest <= tolerance.largest, "\(look.name): \(measure)")
            #expect(measure.overEight <= tolerance.overEight, "\(look.name): \(measure)")
            #expect(reference.contains { $0 > 64 }, "\(look.name): a black still checks nothing")
        }
    }

    @Test func aStillDrawnTwiceIsTheSameBytes() throws {
        let manifest = try Self.manifest()
        let end = try Self.frame("end.bin", tracers: manifest.tracers)
        let look = try Self.look(manifest.views[0])
        let context = try CUDAContext()
        var pictures: [[UInt8]] = []
        for _ in 0..<2 {
            let renderer = try CUDAHoleRenderer(
                context: context, settings: look.settings(width: 96, height: 54))
            renderer.lenses = Self.lenses
            try renderer.upload(end)
            pictures.append(
                [UInt8](try renderer.render(camera: look.camera.camera(progress: 0), look: look.renderLook)))
        }
        #expect(pictures[0] == pictures[1])
    }

    /// `sillage-cuda black-hole still` from a take of the fixture's two moments: the later one
    /// read from the take and drawn as Metal drew it, and a moment between the two stepped to.
    @Test func theCommandDrawsAMomentOfATake() throws {
        let manifest = try Self.manifest()
        let start = try Self.frame("start.bin", tracers: manifest.tracers)
        let end = try Self.frame("end.bin", tracers: manifest.tracers)
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("cuda-hole-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let folder = SceneFolder(work)
        let scene = try JSONDecoder().decode(
            HoleSceneFile.self, from: Data(contentsOf: Self.folder.appendingPathComponent("scene.json")))
        try folder.create(scene)
        let header = HoleTakeFile.Header(
            scene: scene, tracers: manifest.tracers, releaseTime: scene.blackHole.released().time,
            steps: [manifest.startStep, manifest.startStep + manifest.steps])
        let writer = try HoleTakeFile.Writer(header: header, to: folder.take)
        try writer.append(start)
        try writer.append(end)
        try writer.finish()
        let context = try CUDAContext()
        func still(at step: Int) throws -> CUDAHoleStill.Picture {
            try CUDAHoleStill.draw(
                HoleOptions([
                    "still", folder.url.path, "out.png", "--look",
                    Self.folder.appendingPathComponent(manifest.views[0].look).path, "--at",
                    String(header.time(step: step)), "--width", String(manifest.width), "--height",
                    String(manifest.height),
                ]), folder: folder, context: context, gas: manifest.gas)
        }
        let last = try still(at: manifest.startStep + manifest.steps)
        let reference = [UInt8](
            try Data(contentsOf: Self.folder.appendingPathComponent(manifest.views[0].file)))
        let measure = CUDAStillChecks.measure(last.pixels, channels: 3, reference, channels: 3)
        print("CUDAHOLE command", measure)
        #expect(last.time == header.time(step: manifest.startStep + manifest.steps))
        #expect(measure.psnr >= 50, "\(measure)")
        let between = try still(at: manifest.startStep + manifest.steps / 2)
        #expect(between.time == header.time(step: manifest.startStep + manifest.steps / 2))
        #expect(between.pixels.contains { $0 > 64 } && between.pixels != last.pixels)
    }
}
