import Foundation
import SillageCore
import SillageRender

#if canImport(simd)
    import simd
#endif

/// Makes the CUDA engine of a full pass (#278), on the GPU library or the CPU target, whichever
/// the command was linked with. It refuses to run a build whose comparison with the reference
/// outputs failed or never ran (`CUDAEngineCheck`).
public struct CUDAFullPassMaker: FullPassEngineMaker {
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

    public func make(_ start: FullPassRun.Start) throws -> any FullPassEngine {
        try CUDAFullPassEngine(context: context, start: start, threads: threads)
    }
}

/// A full pass on CUDA (#278): the massive particles the Mac's massive pass sampled
/// (`massive.bin`), the light tracers sampled here, which carry no mass, `CUDABarnesHutSolver`
/// over them, the smoothing read off its tree, and a `CUDARenderer` a preset over its buffers,
/// encoded by ffmpeg.
public final class CUDAFullPassEngine: FullPassEngine {
    public enum Failure: Error, CustomStringConvertible {
        case noMassiveSet(URL)
        case otherDraw(String)

        public var description: String {
            switch self {
            case .noMassiveSet(let url):
                "no massive set at \(url.path): run the massive pass on the Mac with a sillage-render"
                    + " that writes it (#278), and bring it with the scene folder"
            case .otherDraw(let why): "massive.bin is not this draw's massive set: \(why)"
            }
        }
    }

    public let context: CUDAContext
    public let barnesHut: CUDABarnesHutSolver
    public let massive: ParticleSystem
    public let tracerCount: Int
    public let threads: Int
    private let lengths: CUDABuffer
    private let massiveDrawn: Int
    private let attributes: ParticleAttributes

    init(context: CUDAContext, start: FullPassRun.Start, threads: Int) throws {
        self.context = context
        self.threads = max(threads, 1)
        var store: CUDALightTracerStore?
        if let resumed = start.resumed {
            massive = resumed.massive
            tracerCount = resumed.tracers
            if tracerCount > 0 {
                store = try CUDALightTracerStore(
                    context: context, capacity: tracerCount + massive.count, awaiting: tracerCount)
            }
        } else {
            // A sample drawn here is the Mac's to rounding only (#272): the massive particles are
            // the Mac's own, and the tracers drawn here, which weigh nothing, go with them.
            guard let url = start.massiveSet, FileManager.default.fileExists(atPath: url.path) else {
                throw Failure.noMassiveSet(start.massiveSet ?? URL(fileURLWithPath: "massive.bin"))
            }
            let read = try RunCheckpoint.readMassiveSet(from: url)
            let split = try CUDABarnesHutSolver.lightTracers(
                context: context, drawn: start.drawn, massive: start.scene)
            try Self.check(read, against: split.massive)
            massive = read
            tracerCount = split.tracers.count
            store = split.tracers
        }
        barnesHut = try CUDABarnesHutSolver(
            context: context, scene: start.scene, massive: massive, tracers: store)
        store = nil
        if let theta = start.tracerOpeningAngle { barnesHut.tracerOpeningAngle = theta }
        barnesHut.profiling = start.profiling
        massiveDrawn = massive.visibleCount > 0 ? massive.visibleCount : massive.count
        // As Metal's `SmoothingField` starts, until the first tree.
        lengths = try context.makeBuffer([Float](repeating: 0.05, count: max(massiveDrawn, 1)))
        attributes = ParticleAttributes(massive)
    }

    /// The massive set read from the Mac is the one sampled here, to rounding: the same counts,
    /// galaxies, components and masses, and positions within a hundredth of a kpc.
    static func check(_ read: ParticleSystem, against sampled: ParticleSystem) throws {
        guard read.count == sampled.count, read.visibleCount == sampled.visibleCount else {
            throw Failure.otherDraw(
                "\(read.count) particles, \(read.visibleCount) visible, where this draw has "
                    + "\(sampled.count) and \(sampled.visibleCount)")
        }
        guard read.galaxyIndex == sampled.galaxyIndex, read.component == sampled.component else {
            throw Failure.otherDraw("the galaxies or the components differ")
        }
        for index in read.mass.indices
        where abs(read.mass[index] - sampled.mass[index]) > 1e-5 * abs(sampled.mass[index]) {
            throw Failure.otherDraw(
                "particle \(index) weighs \(read.mass[index]), not \(sampled.mass[index])")
        }
        for index in read.positions.indices {
            let gap = simd_length(read.positions[index] - sampled.positions[index])
            if gap > 1e-2 {
                throw Failure.otherDraw("particle \(index) is \(gap) kpc from where this draw puts it")
            }
        }
    }

    public var solver: any Solver { barnesHut }
    public var diskFrames: [DiskState] { barnesHut.diskFrames }
    public var device: String {
        CUDAContext.target == .gpu ? "\(context.name), the GPU library" : context.name
    }

    public func refreshSmoothing() throws {
        _ = try barnesHut.writeSmoothing(into: lengths, drawn: massiveDrawn)
    }

    /// The light tracers as the renderer reads them, with the spacing records of the tree as
    /// it stands: a new buffer after the tree grows.
    var tracers: CUDARenderer.Tracers? {
        guard tracerCount > 0 else { return nil }
        let spacing = barnesHut.tracerSpacing
        return CUDARenderer.Tracers(
            states: barnesHut.positions, motions: barnesHut.velocities, count: tracerCount,
            cells: spacing?.cells, treeFrame: spacing?.frame, depth: spacing?.depth ?? 0)
    }

    public func drawing(
        for format: RunVideos.Format, look: LookFile, exposure: Float, drawn: Int, framesPerSecond: Int,
        metadata: VideoMetadata?
    ) throws -> any RunVideoDrawing {
        let renderer = try CUDARenderer(
            context: context, attributes: attributes,
            settings: look.renderSettings(width: format.width, height: format.height),
            externalPositions: barnesHut.positions, externalFormation: barnesHut.formation,
            externalPositionOffset: tracerCount * 16)
        try renderer.setSmoothing(lengths)
        renderer.luminosityNormalisation = exposure
        renderer.skipFrames(drawn)
        return CUDARunVideoDrawing(
            engine: self, renderer: renderer, format: format, framesPerSecond: framesPerSecond,
            metadata: metadata)
    }

    public func join(
        _ parts: [URL], into url: URL, frames: Int, framesPerSecond: Int, metadata: VideoMetadata?
    ) throws {
        try FFmpegVideo.join(
            parts, into: url, frames: frames, framesPerSecond: framesPerSecond, metadata: metadata)
    }

    public func withPositions(_ body: (UnsafePointer<SIMD3<Float>>) throws -> Void) throws {
        let held = try barnesHut.positions.download(SIMD3<Float>.self, count: tracerCount + massive.count)
        try held.withUnsafeBufferPointer { try body($0.baseAddress!) }
    }

    /// What `MetalBarnesHutSolver.drawnAttributes` gives, downloaded a million tracers at a time:
    /// a tracer's attributes from its word and its formation time from its state.
    public func drawnAttributes() throws -> ParticleSystem {
        var system = ParticleSystem(capacity: 0)
        let drawn = tracerCount + massive.visibleCount
        system.galaxyIndex.reserveCapacity(drawn)
        system.birthRadius.reserveCapacity(drawn)
        system.population.reserveCapacity(drawn)
        system.luminosity.reserveCapacity(drawn)
        system.formation.reserveCapacity(drawn)
        system.component.reserveCapacity(drawn)
        system.kernelScale.reserveCapacity(drawn)
        let chunk = 1 << 20
        var start = 0
        while start < tracerCount {
            let count = min(chunk, tracerCount - start)
            let states = try barnesHut.positions.download(SIMD4<Float>.self, count: count, from: start * 16)
            let motions = try barnesHut.velocities.download(
                SIMD4<UInt32>.self, count: count, from: start * 16)
            for (state, motion) in zip(states, motions) {
                let word = TracerWord(bits: motion.w)
                system.galaxyIndex.append(word.galaxy)
                system.birthRadius.append(word.birthRadius)
                system.population.append(0.5)
                system.luminosity.append(word.luminosity)
                system.formation.append(state.w)
                system.component.append(word.component)
                system.kernelScale.append(word.kernelScale)
            }
            start += count
        }
        let visible = min(massive.visibleCount, massive.galaxyIndex.count)
        let times = try barnesHut.formation.download(Float.self, count: visible)
        for index in 0..<visible {
            system.galaxyIndex.append(massive.galaxyIndex[index])
            system.birthRadius.append(massive.birthRadius[index])
            system.population.append(massive.population[index])
            system.luminosity.append(massive.luminosity[index])
            system.formation.append(times[index])
            system.component.append(massive.component[index])
            system.kernelScale.append(massive.kernelScale[index])
        }
        return system
    }

    public var state: SolverState { barnesHut.state }

    public func writeParticles(to handle: FileHandle) throws { try barnesHut.writeParticles(to: handle) }

    public func restore(_ state: SolverState, from handle: FileHandle) throws {
        try barnesHut.restore(state, from: handle)
    }

    public func takeProfile() -> StepProfile? { barnesHut.profiling ? barnesHut.takeProfile() : nil }

    public func check() throws {
        if let failure = barnesHut.failure { throw failure }
    }

    public var peakMemory: (host: Int?, device: Int?) {
        (ProcessMemory.peakFootprint(), context.memoryHeld.peak)
    }
}

/// A preset of a CUDA full pass: its renderer over the solver's buffers, its picture handed to
/// ffmpeg a frame at a time.
final class CUDARunVideoDrawing: RunVideoDrawing {
    let renderer: CUDARenderer
    private unowned let engine: CUDAFullPassEngine
    private let format: RunVideos.Format
    private let framesPerSecond: Int
    private let metadata: VideoMetadata?
    private var writer: FFmpegVideoWriter?

    init(
        engine: CUDAFullPassEngine, renderer: CUDARenderer, format: RunVideos.Format, framesPerSecond: Int,
        metadata: VideoMetadata?
    ) {
        self.engine = engine
        self.renderer = renderer
        self.format = format
        self.framesPerSecond = framesPerSecond
        self.metadata = metadata
    }

    var styling: any FramePreparing { renderer }

    func begin(_ url: URL) throws {
        writer = try FFmpegVideoWriter(
            url: url, width: format.width, height: format.height, framesPerSecond: framesPerSecond,
            codec: format.codec, bitsPerSecond: format.bitsPerSecond, metadata: metadata)
    }

    func append(camera: Camera, still: ((any RunVideoStill) throws -> Void)?) throws {
        renderer.setTracers(engine.tracers)
        let pixels = try renderer.picture(camera: camera, format: .rgb, threads: engine.threads)
        try writer?.append(pixels)
        if let still {
            try still(CUDARunVideoStill(width: format.width, height: format.height, bytes: [UInt8](pixels)))
        }
    }

    func end() throws {
        try writer?.finish()
        writer = nil
    }
}

/// A frame of a CUDA full pass as ffmpeg took it, 8-bit RGB.
public struct CUDARunVideoStill: RunVideoStill {
    public let width: Int
    public let height: Int
    public let bytes: [UInt8]

    public func writePNG(to url: URL) throws {
        try PNG.write(PNG.Image(width: width, height: height, channels: 3, bytes: bytes), to: url)
    }
}
