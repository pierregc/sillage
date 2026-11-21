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
public final class CUDAFullPassEngine: FullPassEngine, CUDARunDrawn {
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
    /// The drawn particles between two steps while frames there are drawn (#310).
    private(set) var drifted: CUDABuffer?

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

    public func drawDrifted(by fraction: Float?) throws {
        drifted = try fraction.map { try barnesHut.drawnDrift(by: $0) }
    }

    /// The light tracers as the renderer reads them, with the spacing records of the tree as
    /// it stands: a new buffer after the tree grows.
    var tracers: CUDARenderer.Tracers? {
        guard tracerCount > 0 else { return nil }
        let spacing = barnesHut.tracerSpacing
        return CUDARenderer.Tracers(
            states: drifted ?? barnesHut.positions, motions: barnesHut.velocities, count: tracerCount,
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
            engine: self, renderer: renderer, width: format.width, height: format.height,
            codec: format.codec, bitsPerSecond: format.bitsPerSecond, framesPerSecond: framesPerSecond,
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

    public func drawnAttributes() throws -> ParticleSystem { try barnesHut.drawnAttributes(massive: massive) }

    public var state: SolverState { barnesHut.state }

    public func writeParticles(to handle: FileHandle) throws { try barnesHut.writeParticles(to: handle) }

    public func restore(_ state: SolverState, from handle: FileHandle) throws {
        try barnesHut.restore(state, from: handle)
    }

    public func takeProfile() -> StepProfile? { barnesHut.profiling ? barnesHut.takeProfile() : nil }

    public func check() throws {
        if let failure = barnesHut.failure { throw failure }
        // A kernel's fault surfaces at the next synchronisation: here, not at a later download (#301).
        try context.synchronize()
    }

    public var peakMemory: (host: Int?, device: Int?) {
        (ProcessMemory.peakFootprint(), context.memoryHeld.peak)
    }
}

/// What a run's drawing reads of its engine at each frame: the light tracers as the tree stands,
/// the drawn particles between two steps, and the threads of the CPU target.
protocol CUDARunDrawn: AnyObject {
    var tracers: CUDARenderer.Tracers? { get }
    var drifted: CUDABuffer? { get }
    var threads: Int { get }
}

/// A video of a CUDA run, a full pass's preset or a take pass's own: its renderer over the
/// solver's buffers, its picture handed to ffmpeg a frame at a time.
final class CUDARunVideoDrawing: RunVideoDrawing {
    let renderer: CUDARenderer
    private unowned let engine: any CUDARunDrawn
    private let width: Int
    private let height: Int
    private let codec: VideoCodec
    private let bitsPerSecond: Int?
    private let framesPerSecond: Int
    private let metadata: VideoMetadata?
    private var writer: FFmpegVideoWriter?
    /// The last frame's drawing, in seconds.
    private(set) var lastSeconds: Double = 0

    init(
        engine: any CUDARunDrawn, renderer: CUDARenderer, width: Int, height: Int, codec: VideoCodec,
        bitsPerSecond: Int?, framesPerSecond: Int, metadata: VideoMetadata?
    ) {
        self.engine = engine
        self.renderer = renderer
        self.width = width
        self.height = height
        self.codec = codec
        self.bitsPerSecond = bitsPerSecond
        self.framesPerSecond = framesPerSecond
        self.metadata = metadata
    }

    var styling: any FramePreparing { renderer }

    func begin(_ url: URL) throws {
        writer = try FFmpegVideoWriter(
            url: url, width: width, height: height, framesPerSecond: framesPerSecond, codec: codec,
            bitsPerSecond: bitsPerSecond, metadata: metadata)
    }

    func append(camera: Camera, still: ((any RunVideoStill) throws -> Void)?) throws {
        let clock = Date()
        renderer.setTracers(engine.tracers)
        renderer.drawnPositions = engine.drifted
        let pixels = try renderer.picture(camera: camera, format: .rgb, threads: engine.threads)
        lastSeconds = Date().timeIntervalSince(clock)
        try writer?.append(pixels)
        if let still {
            try still(CUDARunVideoStill(width: width, height: height, bytes: [UInt8](pixels)))
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
