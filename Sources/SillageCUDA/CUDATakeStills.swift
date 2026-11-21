import Foundation
import SillageCore
import SillageRender

/// Seconds spent in the phases of a drawing, kept when a run is profiled (`--profile`): each
/// phase waits for the device before its time is read, so the time is the phase's own, and a
/// phase timed inside another is taken off the outer one's.
public final class PhaseTimes {
    public private(set) var order: [String] = []
    public private(set) var seconds: [String: Double] = [:]
    public private(set) var counts: [String: Int] = [:]
    /// Seconds of the phases timed inside each phase still running.
    private var within: [Double] = []

    public init() {}

    public func add(_ phase: String, _ spent: Double) {
        if seconds[phase] == nil { order.append(phase) }
        seconds[phase, default: 0] += spent
        counts[phase, default: 0] += 1
    }

    /// Runs `work`, waits for the device, and counts the time as `phase`'s.
    public func time<T>(_ phase: String, on context: CUDAContext?, _ work: () throws -> T) throws -> T {
        let started = Date()
        within.append(0)
        do {
            let result = try work()
            try context?.synchronize()
            let spent = Date().timeIntervalSince(started)
            add(phase, spent - within.removeLast())
            if !within.isEmpty { within[within.count - 1] += spent }
            return result
        } catch {
            within.removeLast()
            throw error
        }
    }

    /// The seconds of every phase together.
    public var total: Double { seconds.values.reduce(0, +) }

    /// A line a phase, the longest first, each with its share of `total` seconds, then what of
    /// `total` no phase counted.
    public func lines(total: Double) -> [String] {
        var lines = order.sorted { (seconds[$0] ?? 0) > (seconds[$1] ?? 0) }.map { phase in
            let spent = seconds[phase] ?? 0
            let count = counts[phase] ?? 0
            return String(
                format: "%@: %.2f s, %.0f %%, %d times, %.1f ms each", phase, spent,
                100 * spent / max(total, 1e-9), count, 1000 * spent / Double(max(count, 1)))
        }
        let rest = total - self.total
        if rest > 0 {
            lines.append(String(format: "the rest: %.2f s, %.0f %%", rest, 100 * rest / max(total, 1e-9)))
        }
        return lines
    }
}

/// Frames of a take drawn on CUDA as `TakeExport` draws them with Metal (#277): the camera the
/// director or the look gives each moment (`TakeFraming`), the positions the take holds there,
/// the smoothing lengths of the tree built over them, the look and the film grain of that frame
/// of a video, then the particle passes and the post-processing. The two engines draw the same
/// picture from the same take, look and framing; `docs/notes/cuda-engine.md` says how close.
/// The frames of a flight go through `FlightFrames`, which it is the engine's stage of (#382).
public final class CUDATakeStills: FrameStage {
    public let take: RecordingFile.Loaded
    public let framing: RecordingFile.Loaded
    public let look: LookFile
    /// The rate the take was captured at, which a video's frames are counted at by default.
    public let capturedRate: Int
    public let width: Int
    public let height: Int
    public let renderer: CUDARenderer
    /// Host threads the CPU target draws a pass from; a GPU ignores it.
    public var threads = 1
    /// Where the time of each phase goes when the drawing is profiled.
    public var phases: PhaseTimes? {
        didSet { renderer.phases = phases }
    }

    private let context: CUDAContext
    private let replay: ShotReplay
    private let builder: CUDATreeBuilder
    private let held: CUDABuffer
    private let lengths: CUDABuffer
    private let count: Int
    /// The take's positions at the moment staged, in pinned memory, and those of a captured
    /// frame beside it while its tree is built.
    private let decoded: CUDAHostMemory
    private var beside: CUDAHostMemory?
    /// Where the renderer's positions and lengths stand: a frame at the same moment of the
    /// take, as a freeze gives, draws from them again.
    private var staged: (place: FlightFrames.Place, eased: Bool)?
    /// How many times the take was decoded for a flight's frame, for the tests.
    private(set) var stagings = 0
    /// The frames of the flight `flightStill` and `flightFrame` draw (#347), when there is one.
    public let flightFrames: FlightFrames?
    public var flight: Flight? { flightFrames?.flight }
    /// The kernel lengths of the captured frames a flight's moment lies between, kept for the
    /// next moment: `EasedSmoothing`'s two fields.
    private var easedFields: [(frame: Int, lengths: [Float])] = []
    /// What the last flight frame drawn took of the inside of a galaxy.
    public private(set) var lastFlightFrame: FlightFrame?

    /// What a flight's frame took of the inside of a galaxy, for the log.
    public struct FlightFrame: Sendable, Equatable {
        /// Kiloparsecs from the eye to the nearest matter (`Nearness`).
        public var nearness: Float
        /// The automatic exposure's trim, in stops.
        public var stops: Double
        /// The renders the frame was averaged from, and the point stars the last one drew.
        public var renders: Int
        public var stars: Int
    }

    /// Pixels of a splat's square past which a flight's frames set it aside for a block of
    /// threads on a GPU, the second way for large splats: from inside a galaxy the near kernels
    /// cover tens of thousands of pixels, which one thread a particle walks alone while its
    /// warp waits. The bits are the first way's.
    public static let flightLargeSplatPixels = 1_024

    /// Splats a pass may set aside of `drawn` particles; the rest are drawn the first way.
    public static func largeSplatCapacity(drawn: Int) -> Int { min(max(drawn / 4, 1_024), 1 << 20) }

    /// `framing` is another take of the same run that gives the camera, the painted arms, the
    /// time and the exposure, as `export --framing` has it (#239). `largeSplatPixels` draws the
    /// splats past that many pixels the second way; 0 draws every splat from its own thread.
    public init(
        context: CUDAContext, take: RecordingFile.Loaded, look: LookFile, capturedRate: Int,
        width: Int, height: Int, framing: RecordingFile.Loaded? = nil,
        laceTexels: Int = DustWeb.laceTexels, flight file: FlightFile? = nil, largeSplatPixels: Int = 0
    ) throws {
        self.context = context
        self.take = take
        self.framing = framing ?? take
        self.look = look
        self.capturedRate = max(capturedRate, 1)
        self.width = width
        self.height = height
        count = take.recording.particleCount
        // The flight first: a take or a flight that cannot be drawn is refused before the
        // device holds anything.
        flightFrames = try file.map {
            try FlightFrames(
                take: take, look: look, capturedRate: capturedRate, width: width, height: height,
                framing: framing, flight: $0)
        }
        let particles = take.particles
        let drawn = particles.visibleCount > 0 ? particles.visibleCount : particles.count
        renderer = try CUDARenderer(
            context: context, particles: particles,
            settings: look.renderSettings(width: width, height: height),
            largeSplatCapacity: largeSplatPixels > 0 ? Self.largeSplatCapacity(drawn: drawn) : 0,
            laceTexels: laceTexels)
        renderer.largeSplatPixels = largeSplatPixels
        if self.framing.recording !== take.recording {
            renderer.luminosityNormalisation = ParticleAttributes.luminosityNormalisation(
                formation: self.framing.particles.formation)
        }
        replay = TakeFraming.replay(
            look: look, framing: self.framing, capturedRate: self.capturedRate, width: width,
            height: height)
        builder = try CUDATreeBuilder(
            context: context, count: count, leafCapacity: 24, nodeCapacity: count / 4 + 1024)
        held = try context.makeBuffer(length: count * 16)
        lengths = try context.makeBuffer(length: count * 4)
        decoded = try CUDAHostMemory(context: context, length: count * 16)
    }

    public var capturedFrames: Int { take.recording.capturedFrames }

    /// The captured position of frame `index` of a video at `framesPerSecond`, which starts at
    /// the take's first frame: where `TakeExport.positions` puts it.
    public func position(ofFrame index: Int, framesPerSecond: Int? = nil) -> Double {
        let step = Double(capturedRate) / Double(max(framesPerSecond ?? capturedRate, 1))
        return Double(index) * step
    }

    /// The frame at a captured position as the video's frame `index` is drawn: the film grain
    /// has moved on by the frames of the video before it. 8-bit bytes in pinned host memory,
    /// valid until the next call.
    ///
    /// With `light`, another engine's accumulation (four floats a supersampled pixel), the
    /// particle passes are not run: the frame is set up as ever and `light` is developed.
    public func still(
        atCaptured position: Double, frame index: Int, format: CUDAPost.Format = .rgb,
        threads: Int = 1, light: [Float]? = nil
    ) throws -> UnsafeRawBufferPointer {
        renderer.inside = nil
        staged = nil
        guard let blend = take.recording.blend(atCaptured: position) else {
            throw RecordingFile.Failure.truncated
        }
        let positions = try decode(blend, into: decoded)
        try buildLengths(positions)
        guard
            let shot = TakeFraming.prepare(
                renderer, look: look, replay: replay, framing: framing, at: position)
        else { throw RecordingFile.Failure.truncated }
        try renderer.positions.upload(positions, at: renderer.positionOffset)
        try renderer.setSmoothing(lengths)
        renderer.setGrain(frame: index)
        if let light {
            return try renderer.develop(format: format, light: context.makeBuffer(light))
        }
        return try renderer.picture(camera: shot.camera, format: format, threads: threads)
    }

    private func timed<T>(_ phase: String, device: Bool = true, _ work: () throws -> T) throws -> T {
        guard let phases else { return try work() }
        return try phases.time(phase, on: device ? context : nil, work)
    }

    /// The take's positions at `blend` into `memory`, sixteen bytes each.
    private func decode(_ blend: Recording.Blend, into memory: CUDAHostMemory) throws
        -> UnsafeRawBufferPointer
    {
        try timed("take decode", device: false) {
            let values = memory.bytes.bindMemory(to: SIMD3<Float>.self)
            guard take.recording.positions(at: blend, into: values) else {
                throw RecordingFile.Failure.truncated
            }
            return UnsafeRawBufferPointer(rebasing: memory.bytes[0..<(count * 16)])
        }
    }

    /// The smoothing lengths of the tree built over `positions`, into `lengths`.
    private func buildLengths(_ positions: UnsafeRawBufferPointer) throws {
        try timed("tree and kernel lengths") {
            try held.upload(positions)
            var grown = 0
            repeat {
                if try builder.overflowed {
                    try builder.grow()
                    grown += 1
                }
                try builder.buildCells(positions: held)
            } while try builder.overflowed && grown < 20
            try builder.buildSmoothing(into: lengths, drawn: count)
        }
    }

    /// The kernel lengths of a flight's moment, into `lengths` (#297's `EasedSmoothing`): the
    /// trees are built at the take's own frames alone, and a moment between two of them takes
    /// the lengths between theirs, so that they change evenly while time runs slowly.
    /// `positions` holds the particles of the moment itself.
    private func easeLengths(at place: FlightFrames.Place, _ positions: UnsafeRawBufferPointer) throws {
        let recording = take.recording
        let position = place.stored ?? place.captured
        let last = recording.capturedFrames - 1
        let lower = min(max(Int(position.rounded(.down)), 0), last)
        let share = Float(min(max(position - Double(lower), 0), 1))
        let wanted = share > 0 && lower < last ? [lower, lower + 1] : [lower]
        easedFields.removeAll { !wanted.contains($0.frame) }
        for frame in wanted where !easedFields.contains(where: { $0.frame == frame }) {
            if Double(frame) == position {
                try buildLengths(positions)
            } else {
                let blend =
                    place.run.map { recording.blend(atStored: Double(frame), within: $0) }
                    ?? recording.blend(atCaptured: Double(frame))
                guard let blend else { throw RecordingFile.Failure.truncated }
                let scratch = try beside ?? CUDAHostMemory(context: context, length: count * 16)
                beside = scratch
                try buildLengths(decode(blend, into: scratch))
            }
            easedFields.append((frame, try lengths.download(Float.self, count: count)))
        }
        func field(_ frame: Int) throws -> [Float] {
            guard let held = easedFields.first(where: { $0.frame == frame }) else {
                throw RecordingFile.Failure.truncated
            }
            return held.lengths
        }
        let before = try field(wanted[0])
        guard wanted.count > 1 else { return try lengths.upload(before) }
        let after = try field(wanted[1])
        try lengths.upload(before.indices.map { before[$0] + (after[$0] - before[$0]) * share })
    }

    // MARK: - The stage of a flight's frames

    public var styling: any FrameStyling { renderer }
    public var drawnCount: Int { renderer.drawnCount }
    public var starsDrawn: Int { renderer.starsDrawn }

    public var inside: InsideFrame? {
        get { renderer.inside }
        set { renderer.inside = newValue }
    }

    public func setGrain(frame index: Int) { renderer.setGrain(frame: index) }

    public func stage(_ place: FlightFrames.Place, eased: Bool) throws -> UnsafeRawPointer {
        guard let base = decoded.bytes.baseAddress else { throw RecordingFile.Failure.truncated }
        if let staged, staged.place == place, staged.eased == eased { return UnsafeRawPointer(base) }
        staged = nil
        guard let blend = place.blend(in: take.recording) else { throw RecordingFile.Failure.truncated }
        let positions = try decode(blend, into: decoded)
        if eased {
            try easeLengths(at: place, positions)
        } else {
            try buildLengths(positions)
        }
        try timed("upload") {
            try renderer.positions.upload(positions, at: renderer.positionOffset)
            try renderer.setSmoothing(lengths)
        }
        staged = (place, eased)
        stagings += 1
        return UnsafeRawPointer(base)
    }

    public func measure(camera: Camera) throws -> [UInt8] {
        try timed("exposure measure") {
            [UInt8](try renderer.picture(camera: camera, format: .rgba, threads: threads))
        }
    }

    /// The frame of the flight at `seconds` as the video's frame `index` is drawn (#347), as
    /// `TakeExport` draws it with Metal: the camera and the time the flight gives, the eased
    /// kernel lengths, the inside of a galaxy where the eye is near matter, and the automatic
    /// exposure of that moment alone, a still having no moments around it to ease it over.
    /// With `interval`, the seconds between two frames of the video, the frame is averaged from
    /// the renders its shutter passes. 8-bit bytes in pinned host memory, valid until the next
    /// call.
    public func flightStill(
        atSeconds seconds: Double, frame index: Int, interval: Double = 0,
        format: CUDAPost.Format = .rgb, threads: Int = 1
    ) throws -> UnsafeRawBufferPointer {
        guard let flightFrames else { throw CUDAError(.invalidArgument, "these stills have no flight") }
        self.threads = threads
        let frame = try flightFrames.still(on: self, atSeconds: seconds, interval: interval)
        return try draw(frame, of: flightFrames, index: index, format: format, stops: frame.stops)
    }

    /// A frame of a video of the flight (#382), as `TakeExport.write` draws it: `frame` at the
    /// exposure measured for the whole flight (`FlightFrames.measure`), averaged from the renders
    /// a frame `interval` seconds long passes, with the grain of the video's frame `index`.
    public func flightFrame(
        _ frame: TimeTrack.Frame, index: Int, interval: Double, exposure: FlightFrames.Exposure,
        format: CUDAPost.Format = .rgb
    ) throws -> UnsafeRawBufferPointer {
        guard let flightFrames else { throw CUDAError(.invalidArgument, "these stills have no flight") }
        let prepared = try timed("frame set up", device: false) {
            try flightFrames.prepare(
                on: self, at: frame, exposure: exposure.scale, trims: exposure.trims, interval: interval)
        }
        return try draw(prepared, of: flightFrames, index: index, format: format, stops: nil)
    }

    /// A frame of a take's video without a flight (#429), as `TakeExport.write` draws it: the
    /// camera of the look's plan along the time track, the kernel lengths of the moment's own
    /// tree, the look's exposure measured over the video (`TakeFrames.measureScale`), and the
    /// grain of the video's frame `index`.
    public func takeFrame(
        _ frame: TimeTrack.Frame, of frames: TakeFrames, index: Int, exposure: ExposureScale?,
        format: CUDAPost.Format = .rgb
    ) throws -> UnsafeRawBufferPointer {
        let shot = try timed("frame set up", device: false) {
            try frames.prepare(on: self, at: frame, exposure: exposure)
        }
        renderer.setGrain(frame: index)
        return try renderer.picture(camera: shot.camera, format: format, threads: threads)
    }

    private func draw(
        _ frame: FlightFrames.Frame, of flightFrames: FlightFrames, index: Int, format: CUDAPost.Format,
        stops: Double?
    ) throws -> UnsafeRawBufferPointer {
        renderer.setGrain(frame: index)
        let picture = try renderer.picture(cameras: frame.cameras, format: format, threads: threads)
        flightFrames.note(self, stops: stops)
        lastFlightFrame = FlightFrame(
            nearness: frame.within.nearness, stops: frame.stops, renders: frame.renders,
            stars: renderer.starsDrawn)
        return picture
    }
}
