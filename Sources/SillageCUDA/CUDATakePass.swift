import Foundation
import SillageCore
import SillageRender

#if canImport(simd)
    import simd
#endif

/// Makes the CUDA engine of the pass that writes a take (#378), on the GPU library or the CPU
/// target, whichever the command was linked with. It refuses a build whose comparison with the
/// reference outputs failed or never ran, as the full pass does (`CUDAEngineCheck`).
public struct CUDATakePassMaker: TakePassEngineMaker {
    public let context: CUDAContext
    /// Threads the CPU target draws a frame with; a GPU ignores it.
    public var threads: Int
    /// Where the engine check's record is read, beside the libraries by default.
    public var checkRecord: URL

    public init(
        context: CUDAContext, threads: Int = ProcessInfo.processInfo.activeProcessorCount,
        checkRecord: URL = CUDAEngineCheck.defaultRecord
    ) {
        self.context = context
        self.threads = threads
        self.checkRecord = checkRecord
    }

    public var engine: String { CUDAEngineCheck.engine }

    public func refuseUnchecked() throws { try CUDAEngineCheck.require(at: checkRecord, context: context) }

    public func make(_ start: TakePassRun.Start) throws -> any TakePassEngine {
        try CUDATakePassEngine(context: context, start: start, threads: threads)
    }
}

/// The pass that writes a take on CUDA (#378), as `MetalTakePassEngine` runs it on the Mac: the
/// scene sampled here, its light tracers with it when it has some, or the massive particles of
/// the draw alone for `--pass massive`, `CUDABarnesHutSolver` over them, the smoothing read off
/// its tree, a `CUDARenderer` over its buffers for the run's own video, encoded by ffmpeg. A
/// sample drawn here is the Mac's to rounding, not to the bit (#272): the scene is this
/// machine's own, and `hires.json` says which engine ran it.
public final class CUDATakePassEngine: TakePassEngine, CUDARunDrawn {
    public enum Failure: Error, CustomStringConvertible {
        case solver(String)

        public var description: String {
            switch self {
            case .solver(let name):
                "the CUDA engine runs the Barnes-Hut solver alone, not \(name): the scene's solver is"
                    + " restricted, or --solver asks another"
            }
        }
    }

    public let context: CUDAContext
    public let barnesHut: CUDABarnesHutSolver
    public let massive: ParticleSystem
    public let tracerCount: Int
    public let droppedTracers: Int
    public let heldCount: Int
    public let threads: Int
    public let renderer: CUDARenderer
    private let lengths: CUDABuffer
    private let massiveDrawn: Int
    private let width: Int
    private let height: Int
    private weak var video: CUDARunVideoDrawing?
    private var stillSeconds: Double = 0
    /// The positions as the CPU reads them, every held particle, tracers first, and the massive
    /// visible particles' formation times, downloaded once a step into pinned host memory.
    private let hostPositions: CUDAHostMemory
    private let hostFormation: CUDAHostMemory
    private var downloadedAt: (time: Float, restores: Int)?
    private var restores = 0
    private var downloadFailure: Error?

    init(context: CUDAContext, start: TakePassRun.Start, threads: Int) throws {
        guard start.backend == "barnes-hut" else { throw Failure.solver(start.backend) }
        self.context = context
        self.threads = max(threads, 1)
        var seeded: ParticleSystem
        var tracers = 0
        var store: CUDALightTracerStore?
        if let resumed = start.resumed {
            // A resumed run samples nothing (#377): its massive set as its first run sampled it,
            // its tracers' buffers left for the checkpoint to fill.
            (seeded, tracers) = (resumed.massive, resumed.tracers)
            if tracers > 0 {
                store = try CUDALightTracerStore(
                    context: context, capacity: tracers + seeded.count, awaiting: tracers)
            }
        } else if start.massive != nil {
            let splitStart = Date()
            if start.massiveOnly {
                // `--pass massive`: the tracers are drawn to pick the same massive particles as
                // the draw with them, then dropped as they come.
                let kept = ParticleSystem.streamingLightTracers(drawn: start.drawn, massive: start.scene) {
                    _ in
                }
                (seeded, tracers) = (kept.massive, kept.tracers)
            } else {
                let split = try CUDABarnesHutSolver.lightTracers(
                    context: context, drawn: start.drawn, massive: start.scene)
                (store, seeded, tracers) = (split.tracers, split.massive, split.tracers.count)
            }
            print(
                String(
                    format: "tracers    %d light, %d massive visible, %d halo, softening %.4f, step %.5f,"
                        + " angle %.2f, %.1f s",
                    tracers, seeded.visibleCount, seeded.count - seeded.visibleCount, start.scene.softening,
                    start.scene.timeStep, start.tracerOpeningAngle ?? start.scene.openingAngle,
                    Date().timeIntervalSince(splitStart)))
        } else {
            seeded = RestrictedSolver.sampleParticles(for: start.drawn)
        }
        droppedTracers = start.resumed?.dropped ?? (start.massiveOnly ? tracers : 0)
        if start.massiveOnly { tracers = 0 }
        barnesHut = try CUDABarnesHutSolver(
            context: context, scene: start.scene, massive: seeded, tracers: store)
        store = nil
        if let theta = start.tracerOpeningAngle { barnesHut.tracerOpeningAngle = theta }
        barnesHut.profiling = start.profiling
        massive = seeded
        tracerCount = tracers
        heldCount = tracers + seeded.count
        massiveDrawn = seeded.visibleCount > 0 ? seeded.visibleCount : seeded.count
        // As Metal's `SmoothingField` starts, until the first tree.
        lengths = try context.makeBuffer([Float](repeating: 0.05, count: max(massiveDrawn, 1)))
        renderer = try CUDARenderer(
            context: context, attributes: ParticleAttributes(seeded), settings: start.settings,
            externalPositions: barnesHut.positions, externalFormation: barnesHut.formation,
            externalPositionOffset: tracers * 16)
        try renderer.setSmoothing(lengths)
        renderer.setGalaxyColours(start.look.palette)
        hostPositions = try CUDAHostMemory(context: context, length: max(heldCount * 16, 16))
        hostFormation = try CUDAHostMemory(context: context, length: max(seeded.visibleCount * 4, 16))
        width = start.settings.width
        height = start.settings.height
    }

    public var solver: any Solver { barnesHut }
    public var stepper: (any StepChangingSolver)? { barnesHut }
    public var diskFrames: [DiskState] { barnesHut.diskFrames }
    public var device: String {
        CUDAContext.target == .gpu ? "\(context.name), the GPU library" : context.name
    }

    public func refreshSmoothing() throws {
        _ = try barnesHut.writeSmoothing(into: lengths, drawn: massiveDrawn)
    }

    /// The positions and the formation times as the last step left them, downloaded when the
    /// solver has stepped since.
    private func download() {
        let now = (time: barnesHut.time, restores: restores)
        if let downloadedAt, downloadedAt == now { return }
        do {
            try barnesHut.positions.download(
                into: UnsafeMutableRawBufferPointer(rebasing: hostPositions.bytes[0..<(heldCount * 16)]))
            try barnesHut.formation.download(
                into: UnsafeMutableRawBufferPointer(
                    rebasing: hostFormation.bytes[0..<(massive.visibleCount * 4)]))
            downloadedAt = now
        } catch {
            downloadFailure = error
        }
    }

    public func withPositions(_ body: (UnsafePointer<SIMD3<Float>>) throws -> Void) rethrows {
        download()
        try body(hostPositions.bytes.baseAddress!.assumingMemoryBound(to: SIMD3<Float>.self))
    }

    public func formed(since start: Float, before end: Float) -> Int {
        download()
        let states = UnsafeRawPointer(hostPositions.bytes.baseAddress!)
        let times = UnsafeRawPointer(hostFormation.bytes.baseAddress!)
        var formed = 0
        for index in 0..<tracerCount {
            let time = states.load(fromByteOffset: index * 16 + 12, as: Float.self)
            if time >= start && time < end { formed += 1 }
        }
        for index in 0..<massive.visibleCount {
            let time = times.load(fromByteOffset: index * 4, as: Float.self)
            if time >= start && time < end { formed += 1 }
        }
        return formed
    }

    public func framedRadius(_ plan: LookFile.CameraPlan) -> Float {
        guard tracerCount > 0 else { return plan.framedRadius(positions: barnesHut.particles.positions) }
        // As `MetalBarnesHutSolver.radii(every: 16)`, without building every tracer as a particle.
        var radii: [Float] = []
        withPositions { positions in
            radii = stride(from: 0, to: heldCount, by: 16).map { simd_length(positions[$0]) }
        }
        return plan.framedRadius(sortedRadii: radii.sorted())
    }

    public func apply(_ look: RenderLook) { renderer.apply(look) }

    /// The light tracers as the renderer reads them, with the spacing records of the tree as it
    /// stands: a new buffer after the tree grows.
    var tracers: CUDARenderer.Tracers? {
        guard tracerCount > 0 else { return nil }
        let spacing = barnesHut.tracerSpacing
        return CUDARenderer.Tracers(
            states: barnesHut.positions, motions: barnesHut.velocities, count: tracerCount,
            cells: spacing?.cells, treeFrame: spacing?.frame, depth: spacing?.depth ?? 0)
    }

    var drifted: CUDABuffer? { nil }

    public func prepareFrame(time: Float, diskFrames: [DiskFrame]) {
        renderer.time = time
        renderer.setDiskFrames(diskFrames)
    }

    public func video(url: URL, width: Int, height: Int, framesPerSecond: Int) throws -> any RunVideoDrawing {
        let drawing = CUDARunVideoDrawing(
            engine: self, renderer: renderer, width: width, height: height, codec: .h264, bitsPerSecond: nil,
            framesPerSecond: framesPerSecond, metadata: nil)
        try drawing.begin(url)
        video = drawing
        return drawing
    }

    public func still(camera: Camera) throws -> (any RunVideoStill)? {
        let clock = Date()
        renderer.setTracers(tracers)
        let pixels = try renderer.picture(camera: camera, format: .rgb, threads: threads)
        stillSeconds = Date().timeIntervalSince(clock)
        return CUDARunVideoStill(width: width, height: height, bytes: [UInt8](pixels))
    }

    public func write(_ still: any RunVideoStill, to url: URL, maximumWidth: Int?) throws {
        guard let still = still as? CUDARunVideoStill, let maximumWidth, still.width > maximumWidth else {
            return try still.writePNG(to: url)
        }
        try PNG.write(still.scaled(toWidth: maximumWidth), to: url)
    }

    /// The last frame's drawing, in seconds: the CPU target's or the GPU's, from the CPU.
    public var lastGPUTime: Double { video?.lastSeconds ?? stillSeconds }

    public func capturedParticles() -> ParticleSystem {
        if tracerCount > 0, let drawn = try? barnesHut.drawnAttributes(massive: massive) { return drawn }
        var captured = massive
        if let times = try? barnesHut.formation.download(Float.self, count: massive.count) {
            captured.formation = times
        }
        return captured
    }

    public var state: SolverState? { barnesHut.state }

    public func writeParticles(to handle: FileHandle) throws { try barnesHut.writeParticles(to: handle) }

    public func restore(_ state: SolverState, from handle: FileHandle) throws {
        try barnesHut.restore(state, from: handle)
        restores += 1
    }

    public func skipFrames(_ count: Int) { renderer.skipFrames(count) }

    public func join(_ parts: [URL], into url: URL, frames: Int, framesPerSecond: Int) throws {
        try FFmpegVideo.join(
            parts, into: url, frames: frames, framesPerSecond: framesPerSecond, metadata: nil)
    }

    public func takeProfile() -> StepProfile? { barnesHut.profiling ? barnesHut.takeProfile() : nil }

    public var peakMemory: (host: Int?, device: Int?) {
        (ProcessMemory.peakFootprint(), context.memoryHeld.peak)
    }

    public func check() throws {
        if let failure = barnesHut.failure { throw failure }
        if let downloadFailure { throw downloadFailure }
    }
}

extension CUDARunVideoStill {
    /// The picture scaled down to `width`, the height in proportion, each pixel the mean of the
    /// pixels it covers: a thumbnail.
    func scaled(toWidth target: Int) -> PNG.Image {
        let wide = max(min(target, width), 1)
        let high = max(height * wide / max(width, 1), 1)
        var bytes = [UInt8](repeating: 0, count: wide * high * 3)
        for y in 0..<high {
            let rows = (y * height / high)..<max((y + 1) * height / high, y * height / high + 1)
            for x in 0..<wide {
                let columns = (x * width / wide)..<max((x + 1) * width / wide, x * width / wide + 1)
                var sum = SIMD3<Int>(repeating: 0)
                for row in rows {
                    for column in columns {
                        let at = (row * width + column) * 3
                        sum &+= SIMD3(Int(self.bytes[at]), Int(self.bytes[at + 1]), Int(self.bytes[at + 2]))
                    }
                }
                let count = rows.count * columns.count
                let at = (y * wide + x) * 3
                bytes[at] = UInt8(sum.x / count)
                bytes[at + 1] = UInt8(sum.y / count)
                bytes[at + 2] = UInt8(sum.z / count)
            }
        }
        return PNG.Image(width: wide, height: high, channels: 3, bytes: bytes)
    }
}
