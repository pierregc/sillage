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

    public var frame: TidalFrame {
        let p = (try? positions.download(SIMD4<Float>.self, count: count)) ?? []
        let v = (try? velocities.download(SIMD4<Float>.self, count: count)) ?? []
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
    public func upload(_ frame: TidalFrame) throws {
        if positions == nil || uploaded != frame.count {
            positions = try context.makeBuffer(length: max(frame.count, 1) * 16)
            velocities = try context.makeBuffer(length: max(frame.count, 1) * 16)
            uploaded = frame.count
        }
        try positions?.upload(frame.positions)
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
    /// `--width`, `--height` and the view's options. `gas` is the grid the run was made with.
    public static func draw(
        _ options: HoleOptions, folder: SceneFolder, context: CUDAContext, gas: GasGrid = GasGrid()
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
        let width = options.int("width") ?? 1920
        let height = options.int("height") ?? 1080
        let renderer = try CUDAHoleRenderer(
            context: context, settings: lookFile.settings(width: width, height: height))
        if let at = lookFile.exposureAt {
            renderer.exposure.fixed = true
            try renderer.upload(seek(take.step(at: at)))
        }
        let shown = try seek(options.double("at").map(take.step(at:)) ?? take.header.steps.last ?? 0)
        try renderer.upload(shown)
        let pixels = try renderer.render(
            camera: lookFile.camera.camera(progress: 0), look: lookFile.renderLook)
        return Picture(pixels: [UInt8](pixels), width: width, height: height, time: shown.time)
    }
}
