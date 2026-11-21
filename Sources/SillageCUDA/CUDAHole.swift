internal import CSillageCUDA
import Foundation
import SillageCore
import SillageRender

#if canImport(simd)
    import simd
#endif

/// A `TidalDisruption` stepped on CUDA (#336), as `TidalRun` steps it on Metal: the same
/// kernels of `HoleShaders`, the same parameters, the grid's sums in fixed point.
public final class CUDATidalRun: TidalStepping {
    public let scene: TidalDisruption
    public let gas: GasGrid
    public let releaseTime: Double
    public private(set) var stepsTaken = 0
    /// The first call the engine refused, after which the run stands still: `TidalStepping`
    /// does not throw, so a caller reads this after stepping.
    public private(set) var failure: Error?
    public var time: Double { releaseTime + Double(stepsTaken) * Double(scene.timeStep) }

    private let count: Int
    private let positions: CUDABuffer
    private let velocities: CUDABuffer
    private let fixed: CUDABuffer
    private let grid: CUDABuffer
    private let column: CUDABuffer

    public init(context: CUDAContext, scene: TidalDisruption, gas: GasGrid = GasGrid()) throws {
        self.scene = scene
        self.gas = gas
        let released = scene.released()
        releaseTime = released.time
        count = released.positions.count
        positions = try context.makeBuffer(released.positions.map { SIMD4<Float>($0, 0) })
        velocities = try context.makeBuffer(
            [SIMD4<Float>](repeating: SIMD4<Float>(released.velocity, 0), count: max(count, 1)))
        fixed = try context.makeBuffer(length: gas.cells * 32)
        grid = try context.makeBuffer(length: gas.cells * 16)
        column = try context.makeBuffer(length: gas.columns * 4)
    }

    public func step(_ steps: Int) {
        guard steps > 0, failure == nil else { return }
        var parameters = HoleStepParams(scene: scene, gas: gas, count: count)
        var run = sc_hole_run(
            positions: positions.handle, velocities: velocities.handle, fixed: fixed.handle,
            grid: grid.handle,
            column: column.handle)
        do {
            try check(
                sc_hole_step(&run, &parameters, MemoryLayout<HoleStepParams>.size, UInt32(steps)),
                "\(steps) steps of the black hole")
            try positions.context.synchronize()
            stepsTaken += steps
        } catch {
            failure = error
        }
    }

    public func resume(from frame: TidalFrame, step: Int) {
        precondition(frame.count == count, "a frame of another scene")
        guard failure == nil else { return }
        do {
            try positions.upload(frame.positions)
            try velocities.upload(frame.velocities)
            stepsTaken = step
        } catch {
            failure = error
        }
    }

    /// Empty after a failure, which `failure` then holds (#301).
    public var frame: TidalFrame {
        var p: [SIMD4<Float>] = []
        var v: [SIMD4<Float>] = []
        if failure == nil {
            do {
                p = try positions.download(SIMD4<Float>.self, count: count)
                v = try velocities.download(SIMD4<Float>.self, count: count)
            } catch {
                (p, v) = ([], [])
                failure = error
            }
        }
        return TidalFrame(time: time, positions: p, velocities: v)
    }
}

/// Draws a `TidalFrame` on CUDA (#336) as `HoleRenderer` draws it on Metal: the draws of
/// `HoleSplats` into a supersampled light, in the renderer's 64-bit fixed point, then the
/// post-processing of `PostPlan` and the picture as bytes.
public final class CUDAHoleRenderer {
    public let context: CUDAContext
    public let settings: RenderSettings
    /// The lens tables over camera distances, which renderers can share.
    public var lenses = HoleLensSet()
    public var exposure = HoleExposure()
    private var grain = FrameGrain()
    private let width: Int
    private let height: Int
    private let light: CUDABuffer
    private let values: CUDABuffer
    private let post: CUDAPost
    private var lensBuffers: [Float: CUDABuffer] = [:]
    private var positions: CUDABuffer?
    private var velocities: CUDABuffer?
    private var uploaded = 0
    private var starPositions: CUDABuffer?
    private var starColours: CUDABuffer?
    private var starCount = 0

    public init(context: CUDAContext, settings: RenderSettings) throws {
        self.context = context
        self.settings = settings
        let size = FramePlan.accumulationSize(settings)
        width = size.width
        height = size.height
        light = try context.makeBuffer(length: width * height * 32)
        values = try context.makeBuffer(length: width * height * 16)
        post = try CUDAPost(context: context, sizes: PostPlan.sizes(for: settings))
    }

    /// Hands the frame's tracers to the engine, and measures what their light is normalised by.
    /// `drift` carries them on along their velocities, as `HoleRenderer.upload` does.
    public func upload(_ frame: TidalFrame, drift: Float = 0) throws {
        if positions == nil || uploaded != frame.count {
            positions = try context.makeBuffer(length: max(frame.count, 1) * 16)
            velocities = try context.makeBuffer(length: max(frame.count, 1) * 16)
            uploaded = frame.count
        }
        try positions?.upload(drift != 0 ? frame.positions(drifted: drift) : frame.positions)
        try velocities?.upload(frame.velocities)
        exposure.measure(frame)
    }

    private func lensBuffer(_ lens: HoleLens) throws -> CUDABuffer {
        if let buffer = lensBuffers[lens.cameraDistance] { return buffer }
        let buffer = try context.makeBuffer(lens.entries)
        lensBuffers[lens.cameraDistance] = buffer
        return buffer
    }

    private func placeStars(_ count: Int) throws {
        guard count != starCount else { return }
        let (positions, colours) = HoleSplats.fieldStars(count)
        starCount = count
        starPositions = count > 0 ? try context.makeBuffer(positions) : nil
        starColours = count > 0 ? try context.makeBuffer(colours) : nil
    }

    /// The light of the frame `upload` last took, seen by `camera` as `look` asks: four floats a
    /// supersampled pixel, rows from the top, as `post` reads it.
    public func draw(camera: Camera, look: HoleLook) throws -> CUDABuffer {
        let (near, far, blend, distance) = lenses.pair(at: simd_length(camera.eye))
        let nearBuffer = try lensBuffer(near)
        let farBuffer = try lensBuffer(far)
        let kept = Set(lenses.built)
        lensBuffers = lensBuffers.filter { kept.contains($0.key) }
        try placeStars(look.stars)
        let splats = HoleSplats(
            settings: settings, camera: camera, look: look, exposure: exposure, near: near, far: far,
            blend: blend, distance: distance, starCount: starCount)
        try light.fill(0)
        func splat(_ uniforms: HoleSplatUniforms, _ x: CUDABuffer?, _ v: CUDABuffer?, _ count: Int) throws {
            guard let x, let v, count > 0 else { return }
            var uniforms = uniforms
            try check(
                sc_hole_splat(
                    light.handle, UInt32(width), UInt32(height), x.handle, v.handle, UInt32(count), &uniforms,
                    MemoryLayout<HoleSplatUniforms>.stride, nearBuffer.handle, farBuffer.handle),
                "the black hole's splats")
        }
        for image in 0..<splats.images {
            try splat(splats.tracers.drawing(image: image), positions, velocities, uploaded)
        }
        if let field = splats.stars {
            for image in 0..<splats.images {
                try splat(field.drawing(image: image), starPositions, starColours, starCount)
            }
        }
        try check(
            sc_hole_finish(light.handle, values.handle, UInt32(width), UInt32(height)),
            "the black hole's light")
        return values
    }

    /// The frame as a picture in 8-bit bytes, in pinned host memory valid until the next frame.
    /// The grain moves on one frame, as a frame drawn by `HoleRenderer` does.
    public func render(camera: Camera, look: HoleLook, format: CUDAPost.Format = .rgb) throws
        -> UnsafeRawBufferPointer
    {
        let lit = try draw(camera: camera, look: look)
        let plan = PostPlan(settings: settings, fade: 1, grain: &grain)
        try post.run(plan, light: lit)
        return try post.pack(format)
    }
}

/// `sillage-cuda black-hole still` (#336): one moment of a close up's take, drawn as
/// `sillage-render black-hole still` draws it, the run stepped on CUDA from the frame the take
/// kept before it.
public enum CUDAHoleStill {
    public struct Picture: Sendable {
        /// 8-bit RGB, rows from the top.
        public var pixels: [UInt8]
        public var width: Int
        public var height: Int
        /// The moment drawn, in the hole's time units.
        public var time: Double
    }

    /// `options` as `black-hole still` takes them: the folder second, `--at`, `--look`,
    /// `--flight` and `--second` (#335), `--width`, `--height` and the view's options. `gas` is the grid the run was made with;
    /// `lenses`, tables built already.
    public static func draw(
        _ options: HoleOptions, folder: SceneFolder, context: CUDAContext, gas: GasGrid = GasGrid(),
        lenses: HoleLensSet? = nil
    ) throws -> Picture {
        let take = try HoleTakeFile.Loaded(contentsOf: folder.take)
        let lookFile = try options.look(folder: folder)
        let run = try CUDATidalRun(context: context, scene: take.header.scene.blackHole, gas: gas)
        guard run.releaseTime == take.header.releaseTime else {
            throw HoleTakeFile.Failure.wrongFrame("the scene releases at another time than the take's")
        }
        var frame = take.frame(0)
        run.resume(from: frame, step: 0)
        func seek(_ step: Int) throws -> TidalFrame {
            frame = take.seek(step, run: run, held: frame)
            if let failure = run.failure { throw failure }
            return frame
        }
        let flight = try options.values["flight"].map {
            try HoleFlight.resolve(
                FlightFile.decoded(from: Data(contentsOf: folder.flight($0))), header: take.header,
                camera: lookFile.camera)
        }
        let second = options.double("second") ?? 0
        let moment = flight.map { $0.captured(atSeconds: second) }
        let step =
            options.double("at").map(take.step(at:))
            ?? moment.map { Int($0.rounded(.down)) } ?? take.header.steps.last ?? 0
        let drift = options.double("at") == nil ? (moment ?? 0) - (moment?.rounded(.down) ?? 0) : 0
        let width = options.int("width") ?? 1920
        let height = options.int("height") ?? 1080
        let renderer = try CUDAHoleRenderer(
            context: context, settings: lookFile.settings(width: width, height: height))
        if let lenses { renderer.lenses = lenses }
        if let at = lookFile.exposureAt {
            renderer.exposure.fixed = true
            try renderer.upload(seek(take.step(at: at)))
        }
        let shown = try seek(step)
        try renderer.upload(shown, drift: Float(drift * take.header.timeStep))
        var camera = lookFile.camera.camera(progress: 0)
        var renderLook = lookFile.renderLook
        if let flight {
            let shot = flight.camera(atSeconds: second)
            camera = shot.camera
            renderLook.exposure *= Float(pow(2, shot.exposure))
        }
        let pixels = try renderer.render(camera: camera, look: renderLook)
        return Picture(pixels: [UInt8](pixels), width: width, height: height, time: shown.time)
    }
}

/// The close up held to Metal's reference outputs of `Tests/Fixtures/hole` (#336): the run 40
/// steps on from a moment, three stills of the moment Metal reached, and the command's path from
/// a take. Part of `sillage-cuda check`, which runs it in an optimised build: on the CPU of a test
/// build a lens table takes most of a minute (docs/notes/cuda-engine.md).
public enum CUDAHoleCheck {
    public struct Manifest: Decodable, Sendable {
        public struct View: Decodable, Sendable {
            public var look: String
            public var file: String
        }

        public var tracers: Int
        public var gas: GasGrid
        public var startStep: Int
        public var steps: Int
        public var width: Int
        public var height: Int
        public var views: [View]
    }

    /// The run's tolerances after Metal's 40 steps: positions and velocities as a share of their
    /// size (measured 5.5e-7 and 4.7e-6), and the light, whose viscous heat is `1 - keep²` with
    /// `keep = exp(-ε)` and ε about 1e-6, the difference of two floats near one that two maths
    /// libraries round apart by a few percent of it (measured 1.2 % of the brightest at most, 2.9 %
    /// of the light on the mean).
    public static let position: Float = 1e-5
    public static let velocity: Float = 1e-4
    public static let light: (largest: Float, mean: Double) = (0.05, 0.1)
    /// A still's against Metal's (measured 54.7 to 55.2 dB, 17 to 31 levels, 0.084 % over 8).
    public static let still: (psnr: Double, largest: Int, overEight: Double) = (50, 48, 0.002)

    public static func manifest(_ folder: URL) throws -> Manifest {
        try JSONDecoder().decode(
            Manifest.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json")))
    }

    public static func scene(_ folder: URL) throws -> HoleSceneFile {
        try JSONDecoder().decode(
            HoleSceneFile.self, from: Data(contentsOf: folder.appendingPathComponent("scene.json")))
    }

    public static func frame(_ folder: URL, _ name: String, tracers: Int) throws -> TidalFrame {
        let data = try Data(contentsOf: folder.appendingPathComponent(name))
        let values = data.withUnsafeBytes { Array($0.bindMemory(to: SIMD4<Float>.self)) }
        guard values.count == 2 * tracers else {
            throw CUDAError(.invalidArgument, "\(name) holds \(values.count / 2) tracers, not \(tracers)")
        }
        return TidalFrame(
            time: 0, positions: Array(values[0..<tracers]), velocities: Array(values[tracers..<(2 * tracers)])
        )
    }

    /// How far CUDA's run lands from Metal's after the fixture's steps.
    public struct RunMeasure: Sendable, CustomStringConvertible {
        public var position: Float = 0
        public var velocity: Float = 0
        public var light: Float = 0
        public var brightest: Float = 0
        public var lightMean = 0.0
        public var swallowed = (cuda: 0, metal: 0)

        public var passed: Bool {
            swallowed.cuda == swallowed.metal && position < CUDAHoleCheck.position
                && velocity < CUDAHoleCheck.velocity && light <= CUDAHoleCheck.light.largest * brightest
                && lightMean <= CUDAHoleCheck.light.mean && brightest > 0
        }

        public var description: String {
            String(
                format: "positions %.2g, velocities %.2g, light %.3f of the brightest and %.3f on the mean,"
                    + " %d swallowed (Metal %d)", position, velocity, light / max(brightest, 1e-30),
                lightMean,
                swallowed.cuda, swallowed.metal)
        }
    }

    public static func run(context: CUDAContext, folder: URL) throws -> RunMeasure {
        let manifest = try manifest(folder)
        let start = try frame(folder, "start.bin", tracers: manifest.tracers)
        let end = try frame(folder, "end.bin", tracers: manifest.tracers)
        let run = try CUDATidalRun(context: context, scene: scene(folder).blackHole, gas: manifest.gas)
        run.resume(from: start, step: manifest.startStep)
        run.step(manifest.steps)
        if let failure = run.failure { throw failure }
        let stepped = run.frame
        var measure = RunMeasure()
        var difference = 0.0
        var total = 0.0
        for index in 0..<manifest.tracers {
            let (a, b) = (stepped.positions[index], end.positions[index])
            let (va, vb) = (stepped.velocities[index], end.velocities[index])
            if va.w < 0 { measure.swallowed.cuda += 1 }
            if vb.w < 0 { measure.swallowed.metal += 1 }
            let at = SIMD3<Float>(b.x, b.y, b.z)
            let moving = SIMD3<Float>(vb.x, vb.y, vb.z)
            measure.position = max(
                measure.position, simd_length(SIMD3<Float>(a.x, a.y, a.z) - at) / max(simd_length(at), 1))
            measure.velocity = max(
                measure.velocity,
                simd_length(SIMD3<Float>(va.x, va.y, va.z) - moving) / max(simd_length(moving), 0.01))
            measure.light = max(measure.light, abs(a.w - b.w))
            measure.brightest = max(measure.brightest, b.w)
            difference += Double(abs(a.w - b.w))
            total += Double(b.w)
        }
        measure.lightMean = difference / max(total, 1e-30)
        return measure
    }

    /// A view of the fixture drawn from Metal's later moment, twice, against Metal's still.
    public static func still(
        context: CUDAContext, folder: URL, view: Manifest.View, lenses: HoleLensSet
    ) throws -> (measure: CUDAStillChecks.Measure, repeats: Bool) {
        let manifest = try manifest(folder)
        let end = try frame(folder, "end.bin", tracers: manifest.tracers)
        let look = try HoleLookFile.decoded(from: Data(contentsOf: folder.appendingPathComponent(view.look)))
        var pictures: [[UInt8]] = []
        for _ in 0..<2 {
            let renderer = try CUDAHoleRenderer(
                context: context, settings: look.settings(width: manifest.width, height: manifest.height))
            renderer.lenses = lenses
            try renderer.upload(end)
            pictures.append(
                [UInt8](try renderer.render(camera: look.camera.camera(progress: 0), look: look.renderLook)))
        }
        let reference = [UInt8](try Data(contentsOf: folder.appendingPathComponent(view.file)))
        return (
            CUDAStillChecks.measure(pictures[0], channels: 3, reference, channels: 3),
            pictures[0] == pictures[1]
        )
    }

    /// `sillage-cuda black-hole still` from a take of the fixture's two moments: the later one
    /// read from the take and drawn as Metal drew the first view, and a moment between the two
    /// stepped to.
    public static func command(context: CUDAContext, folder: URL, lenses: HoleLensSet) throws -> (
        measure: CUDAStillChecks.Measure, stepped: Bool
    ) {
        let manifest = try manifest(folder)
        let scene = try scene(folder)
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("cuda-hole-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let take = SceneFolder(work)
        try take.create(scene)
        let header = HoleTakeFile.Header(
            scene: scene, tracers: manifest.tracers, releaseTime: scene.blackHole.released().time,
            steps: [manifest.startStep, manifest.startStep + manifest.steps])
        let writer = try HoleTakeFile.Writer(header: header, to: take.take)
        try writer.append(frame(folder, "start.bin", tracers: manifest.tracers))
        try writer.append(frame(folder, "end.bin", tracers: manifest.tracers))
        try writer.finish()
        func still(at step: Int) throws -> CUDAHoleStill.Picture {
            try CUDAHoleStill.draw(
                HoleOptions([
                    "still", work.path, "out.png", "--look",
                    folder.appendingPathComponent(manifest.views[0].look).path,
                    "--at", String(header.time(step: step)), "--width", String(manifest.width), "--height",
                    String(manifest.height),
                ]), folder: take, context: context, gas: manifest.gas, lenses: lenses)
        }
        let last = try still(at: manifest.startStep + manifest.steps)
        let reference = [UInt8](try Data(contentsOf: folder.appendingPathComponent(manifest.views[0].file)))
        let between = try still(at: manifest.startStep + manifest.steps / 2)
        let stepped =
            last.time == header.time(step: manifest.startStep + manifest.steps)
            && between.time == header.time(step: manifest.startStep + manifest.steps / 2)
            && between.pixels.contains { $0 > 64 } && between.pixels != last.pixels
        return (CUDAStillChecks.measure(last.pixels, channels: 3, reference, channels: 3), stepped)
    }

    /// The items `sillage-cuda check` records for the close up.
    public static func items(context: CUDAContext, folder: URL) -> [CUDAEngineCheck.Item] {
        var items: [CUDAEngineCheck.Item] = []
        func attempt(_ name: String, _ body: () throws -> (Bool, String)) {
            do {
                let (passed, detail) = try body()
                items.append(CUDAEngineCheck.Item(name: name, passed: passed, detail: detail))
            } catch {
                items.append(CUDAEngineCheck.Item(name: name, passed: false, detail: "\(error)"))
            }
        }
        let lenses = HoleLensSet()
        attempt("hole run") {
            let measure = try run(context: context, folder: folder)
            return (measure.passed, "\(measure)")
        }
        func acceptable(_ measure: CUDAStillChecks.Measure) -> Bool {
            measure.psnr >= still.psnr && measure.largest <= still.largest
                && measure.overEight <= still.overEight
        }
        do {
            for view in try manifest(folder).views {
                attempt("hole \(view.file)") {
                    let (measure, repeats) = try self.still(
                        context: context, folder: folder, view: view, lenses: lenses)
                    return (
                        acceptable(measure) && repeats, "\(measure)\(repeats ? "" : ", not the same twice")"
                    )
                }
            }
        } catch {
            items.append(CUDAEngineCheck.Item(name: "hole stills", passed: false, detail: "\(error)"))
        }
        attempt("hole command") {
            let (measure, stepped) = try command(context: context, folder: folder, lenses: lenses)
            return (
                acceptable(measure) && stepped,
                "\(measure)\(stepped ? "" : ", the moment between not stepped to")"
            )
        }
        return items
    }
}
