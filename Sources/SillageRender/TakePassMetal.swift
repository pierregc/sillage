import Foundation
import Metal
import SillageCore

/// Makes the Metal engine of a take pass.
public struct MetalTakePassMaker: TakePassEngineMaker {
    public init() {}

    public var engine: String { "metal" }

    public func make(_ start: TakePassRun.Start) throws -> any TakePassEngine {
        try MetalTakePassEngine(start)
    }
}

/// A take pass on Metal (#376), as `sillage-render`'s loop ran it before the flow was shared: the
/// scene sampled, its light tracers with it when it has some, `MetalBarnesHutSolver` or the
/// solver the factory gives, or the restricted solver on the CPU, a renderer over the solver's
/// own buffers and the smoothing read off its tree.
public final class MetalTakePassEngine: TakePassEngine {
    public let gpuSolver: (any GPUSolver)?
    public let solver: any Solver
    /// The solver of a run with light tracers.
    public let tracerSolver: MetalBarnesHutSolver?
    public let massive: ParticleSystem
    public let tracerCount: Int
    public let droppedTracers: Int
    public let renderer: Renderer
    public let smoothing: SmoothingField
    public let heldCount: Int
    private let width: Int
    private let height: Int
    private weak var video: MetalRunVideoDrawing?

    init(_ start: TakePassRun.Start) throws {
        var seeded: ParticleSystem
        var tracerCount = 0
        var tracerStore: LightTracerStore?
        // With tracers `seeded` is the massive set alone: the tracers go straight into the
        // solver's buffers as they are sampled, 32 bytes each (#238).
        if start.massive != nil {
            let splitStart = Date()
            if start.massiveOnly {
                // `--massive-only` (#239): the massive particles of that draw run alone, which the
                // same draw with its tracers repeats to the bit, so the shots planned on this run
                // frame that one. The tracers are drawn to pick the same massive particles, then
                // dropped as they come.
                let kept = ParticleSystem.streamingLightTracers(drawn: start.drawn, massive: start.scene) {
                    _ in
                }
                (seeded, tracerCount) = (kept.massive, kept.tracers)
            } else {
                let split = try MetalBarnesHutSolver.lightTracers(drawn: start.drawn, massive: start.scene)
                (tracerStore, seeded, tracerCount) = (split.tracers, split.massive, split.tracers.count)
            }
            print(
                String(
                    format: "tracers    %d light, %d massive visible, %d halo, softening %.4f, step %.5f,"
                        + " angle %.2f, %.1f s",
                    tracerCount, seeded.visibleCount, seeded.count - seeded.visibleCount,
                    start.scene.softening, start.scene.timeStep,
                    start.tracerOpeningAngle ?? start.scene.openingAngle, Date().timeIntervalSince(splitStart)
                ))
        } else {
            seeded = RestrictedSolver.sampleParticles(for: start.drawn)
        }
        droppedTracers = start.massiveOnly ? tracerCount : 0
        if start.massiveOnly { tracerCount = 0 }
        let gpuSolver: (any GPUSolver)? =
            start.backend == "cpu"
            ? nil
            : tracerCount > 0
                ? try MetalBarnesHutSolver(scene: start.scene, massive: seeded, tracers: tracerStore)
                : try GPUSolverFactory.make(scene: start.scene, particles: seeded)
        tracerStore = nil
        self.gpuSolver = gpuSolver
        tracerSolver = tracerCount > 0 ? gpuSolver as? MetalBarnesHutSolver : nil
        if let theta = start.tracerOpeningAngle, let barnesHut = gpuSolver as? MetalBarnesHutSolver {
            barnesHut.tracerOpeningAngle = theta
        }
        // `--profile` times every pass of a step on the GPU, printed with each frame.
        if start.profiling { (gpuSolver as? MetalBarnesHutSolver)?.profiling = true }
        solver = gpuSolver ?? RestrictedSolver(scene: start.scene, particles: seeded)
        renderer = try Renderer(
            particles: seeded, settings: start.settings, externalPositions: gpuSolver?.positions,
            externalFormation: gpuSolver?.formation, externalPositionOffset: tracerCount * 16)
        try renderer.setTracers(tracerSolver)
        // Particles the solver's position buffer holds, tracers first.
        heldCount = tracerCount + seeded.count
        smoothing = try SmoothingField(
            device: renderer.device,
            particleCount: seeded.visibleCount > 0 ? seeded.visibleCount : seeded.count)
        renderer.setSmoothing(smoothing.buffer)
        renderer.setGalaxyColours(start.look.palette)
        massive = seeded
        self.tracerCount = tracerCount
        width = start.settings.width
        height = start.settings.height
    }

    private var barnesHut: MetalBarnesHutSolver? { gpuSolver as? MetalBarnesHutSolver }

    public var stepper: (any StepChangingSolver)? { barnesHut }
    public var diskFrames: [DiskState] { barnesHut?.diskFrames ?? [] }
    public var device: String { renderer.gpuName }

    public func refreshSmoothing() throws {
        if let gpuSolver {
            smoothing.update(from: gpuSolver)
        } else {
            smoothing.update(positions: solver.particles.positions)
        }
    }

    public func formed(since: Float, before: Float) -> Int {
        barnesHut?.formed(since: since, before: before) ?? 0
    }

    public func framedRadius(_ plan: LookFile.CameraPlan) -> Float {
        // Not `particles` with tracers, which would build every one of them as a particle.
        tracerSolver.map { plan.framedRadius(sortedRadii: $0.radii(every: 16).sorted()) }
            ?? plan.framedRadius(positions: solver.particles.positions)
    }

    public func apply(_ look: RenderLook) { renderer.apply(look) }

    public func prepareFrame(time: Float, diskFrames: [DiskFrame]) {
        if gpuSolver == nil { renderer.upload(positions: solver.particles.positions) }
        renderer.time = time
        renderer.setDiskFrames(diskFrames)
    }

    public func video(url: URL, width: Int, height: Int, framesPerSecond: Int) throws -> any RunVideoDrawing {
        let drawing = MetalRunVideoDrawing(
            renderer: renderer, width: width, height: height, codec: .h264, bitsPerSecond: nil,
            framesPerSecond: framesPerSecond, metadata: nil)
        try drawing.begin(url)
        video = drawing
        return drawing
    }

    public func still(camera: Camera) throws -> (any RunVideoStill)? {
        MetalRunVideoStill(
            image: PNGWriter.image(renderer.render(camera: camera), width: width, height: height))
    }

    public func write(_ still: any RunVideoStill, to url: URL, maximumWidth: Int?) throws {
        guard let still = still as? MetalRunVideoStill else { return try still.writePNG(to: url) }
        try PNGWriter.write(still.image, maximumWidth: maximumWidth, to: url)
    }

    public var lastGPUTime: Double { video?.lastGPUTime ?? renderer.lastGPUTime }

    public func withPositions(_ body: (UnsafePointer<SIMD3<Float>>) throws -> Void) rethrows {
        if let gpuSolver {
            try body(gpuSolver.positions.contents().bindMemory(to: SIMD3<Float>.self, capacity: heldCount))
        } else {
            try solver.particles.positions.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                try body(base)
            }
        }
    }

    public func capturedParticles() -> ParticleSystem {
        tracerSolver?.drawnAttributes() ?? gpuSolver?.capturedParticles(from: massive) ?? massive
    }

    public var state: SolverState? { barnesHut?.state }

    public func writeParticles(to handle: FileHandle) throws { try barnesHut?.writeParticles(to: handle) }

    public func takeProfile() -> StepProfile? {
        guard let barnesHut, barnesHut.profiling else { return nil }
        return barnesHut.takeProfile()
    }

    public var peakMemory: (host: Int?, device: Int?) { (ProcessMemory.peakFootprint(), nil) }
}
