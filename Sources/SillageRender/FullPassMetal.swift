import Foundation
import Metal
import SillageCore

/// Makes the Metal engine of a full pass: the Mac's, the reference the others are checked
/// against, so it has nothing to check first.
public struct MetalFullPassMaker: FullPassEngineMaker {
    public init() {}

    public var engine: String { "metal" }

    public func refuseUnchecked() throws {}

    public func make(_ start: FullPassRun.Start) throws -> any FullPassEngine {
        try MetalFullPassEngine(start)
    }
}

/// A full pass on Metal (#239), as `sillage-render` ran it before the flow was shared (#278):
/// the massive set and its light tracers sampled together, `MetalBarnesHutSolver` over them, a
/// run renderer over the solver's buffers that every preset's renderer shares, and the
/// smoothing read off the solver's tree.
public final class MetalFullPassEngine: FullPassEngine {
    public let barnesHut: MetalBarnesHutSolver
    public let massive: ParticleSystem
    public let tracerCount: Int
    private let renderer: Renderer
    private let smoothing: SmoothingField
    private let heldCount: Int

    init(_ start: FullPassRun.Start) throws {
        var store: LightTracerStore?
        let massive: ParticleSystem
        let tracerCount: Int
        if let resumed = start.resumed {
            massive = resumed.massive
            tracerCount = resumed.tracers
            if tracerCount > 0 {
                store = try LightTracerStore(capacity: tracerCount + massive.count, awaiting: tracerCount)
            }
        } else {
            let split = try MetalBarnesHutSolver.lightTracers(drawn: start.drawn, massive: start.scene)
            store = split.tracers
            massive = split.massive
            tracerCount = split.tracers.count
        }
        if tracerCount > 0 {
            barnesHut = try MetalBarnesHutSolver(scene: start.scene, massive: massive, tracers: store)
        } else {
            guard
                let made = try GPUSolverFactory.make(scene: start.scene, particles: massive)
                    as? MetalBarnesHutSolver
            else { throw FullPassRun.Failure.notBarnesHut }
            barnesHut = made
        }
        store = nil
        self.massive = massive
        self.tracerCount = tracerCount
        if let theta = start.tracerOpeningAngle { barnesHut.tracerOpeningAngle = theta }
        if start.profiling { barnesHut.profiling = true }
        renderer = try Renderer(
            particles: massive, settings: start.settings, externalPositions: barnesHut.positions,
            externalFormation: barnesHut.formation, externalPositionOffset: tracerCount * 16)
        try renderer.setTracers(tracerCount > 0 ? barnesHut : nil)
        heldCount = tracerCount + massive.count
        smoothing = try SmoothingField(
            device: renderer.device,
            particleCount: massive.visibleCount > 0 ? massive.visibleCount : massive.count)
        renderer.setSmoothing(smoothing.buffer)
    }

    public var solver: any Solver { barnesHut }
    public var diskFrames: [DiskState] { barnesHut.diskFrames }
    public var device: String { renderer.gpuName }

    public func refreshSmoothing() throws { smoothing.update(from: barnesHut) }

    public func drawing(
        for format: RunVideos.Format, look: LookFile, exposure: Float, drawn: Int, framesPerSecond: Int,
        metadata: VideoMetadata?
    ) throws -> any RunVideoDrawing {
        let drawing = try Renderer(
            sharing: renderer, settings: look.renderSettings(width: format.width, height: format.height))
        drawing.setSmoothing(smoothing.buffer)
        drawing.luminosityNormalisation = exposure
        drawing.skipFrames(drawn)
        return MetalRunVideoDrawing(
            renderer: drawing, format: format, framesPerSecond: framesPerSecond, metadata: metadata)
    }

    public func join(
        _ parts: [URL], into url: URL, frames: Int, framesPerSecond: Int, metadata: VideoMetadata?
    ) throws {
        try RunVideos.join(
            parts, into: url, frames: frames, framesPerSecond: framesPerSecond, metadata: metadata)
    }

    public func withPositions(_ body: (UnsafePointer<SIMD3<Float>>) throws -> Void) throws {
        try body(
            UnsafePointer(
                barnesHut.positions.contents().bindMemory(to: SIMD3<Float>.self, capacity: heldCount)))
    }

    public func drawnAttributes() throws -> ParticleSystem {
        tracerCount > 0 ? barnesHut.drawnAttributes() : barnesHut.capturedParticles(from: massive)
    }

    public var state: SolverState { barnesHut.state }

    public func writeParticles(to handle: FileHandle) throws { try barnesHut.writeParticles(to: handle) }

    public func restore(_ state: SolverState, from handle: FileHandle) throws {
        try barnesHut.restore(state, from: handle)
    }

    public func takeProfile() -> StepProfile? { barnesHut.profiling ? barnesHut.takeProfile() : nil }

    public func check() throws {}

    public var peakMemory: (host: Int?, device: Int?) { (ProcessMemory.peakFootprint(), nil) }
}
