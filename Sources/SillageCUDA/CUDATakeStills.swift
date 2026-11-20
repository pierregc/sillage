import Foundation
import SillageCore
import SillageRender

/// Frames of a take drawn on CUDA as `TakeExport` draws them with Metal (#277): the camera the
/// director or the look gives each moment (`TakeFraming`), the positions the take holds there,
/// the smoothing lengths of the tree built over them, the look and the film grain of that frame
/// of a video, then the particle passes and the post-processing. The two engines draw the same
/// picture from the same take, look and framing; `docs/notes/cuda-engine.md` says how close.
public final class CUDATakeStills {
    public let take: RecordingFile.Loaded
    public let framing: RecordingFile.Loaded
    public let look: LookFile
    /// The rate the take was captured at, which a video's frames are counted at by default.
    public let capturedRate: Int
    public let width: Int
    public let height: Int
    public let renderer: CUDARenderer

    private let context: CUDAContext
    private let replay: ShotReplay
    private let builder: CUDATreeBuilder
    private let held: CUDABuffer
    private let lengths: CUDABuffer
    private let count: Int
    /// The flight the frames of `flightStill` are drawn along (#347), when the stills have one.
    public let flight: Flight?
    /// The kernel lengths of the captured frames a flight's moment lies between, kept for the
    /// next moment: `EasedSmoothing`'s two fields.
    private var easedFields: [(frame: Int, lengths: [Float])] = []
    /// A flight's exposure, measured once: the scale of the photograph it leaves from, and the
    /// mean luminance its frames are held under.
    private var flightExposure: (scale: ExposureScale?, target: Float)?
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

    /// `framing` is another take of the same run that gives the camera, the painted arms, the
    /// time and the exposure, as `export --framing` has it (#239).
    public init(
        context: CUDAContext, take: RecordingFile.Loaded, look: LookFile, capturedRate: Int,
        width: Int, height: Int, framing: RecordingFile.Loaded? = nil,
        laceTexels: Int = DustWeb.laceTexels, flight file: FlightFile? = nil
    ) throws {
        self.context = context
        self.take = take
        self.framing = framing ?? take
        self.look = look
        self.capturedRate = max(capturedRate, 1)
        self.width = width
        self.height = height
        count = take.recording.particleCount
        renderer = try CUDARenderer(
            context: context, particles: take.particles,
            settings: look.renderSettings(width: width, height: height), laceTexels: laceTexels)
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
        // Its `look` keys stand on the camera the stills draw without it, as an export's do.
        let cameras = replay
        let framed = FlightTake(take: framing ?? take, capturedRate: max(capturedRate, 1))
        flight = try file.map {
            try Flight(
                $0, take: framed,
                look: { cameras.shot(atCaptured: $0).camera })
        }
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
        let decoded = try positions(atCaptured: position)
        try buildLengths(decoded)
        guard
            let shot = TakeFraming.prepare(
                renderer, look: look, replay: replay, framing: framing, at: position)
        else { throw RecordingFile.Failure.truncated }
        try renderer.upload(positions: decoded)
        try renderer.setSmoothing(lengths)
        renderer.setGrain(frame: index)
        if let light {
            return try renderer.develop(format: format, light: context.makeBuffer(light))
        }
        return try renderer.picture(camera: shot.camera, format: format, threads: threads)
    }

    private func positions(atCaptured position: Double) throws -> [SIMD3<Float>] {
        guard let blend = take.recording.blend(atCaptured: position) else {
            throw RecordingFile.Failure.truncated
        }
        return take.recording.positions(at: blend)
    }

    /// The smoothing lengths of the tree built over `decoded`, into `lengths`.
    private func buildLengths(_ decoded: [SIMD3<Float>]) throws {
        try held.upload(decoded)
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

    /// The kernel lengths of a flight's moment, into `lengths` (#297's `EasedSmoothing`): the
    /// trees are built at the take's captured frames alone, and a moment between two of them
    /// takes the lengths between theirs, so that they change evenly while time runs slowly.
    /// `decoded` holds the positions of the moment itself.
    private func easeLengths(at position: Double, _ decoded: [SIMD3<Float>]) throws {
        let last = capturedFrames - 1
        let lower = min(max(Int(position.rounded(.down)), 0), last)
        let share = Float(min(max(position - Double(lower), 0), 1))
        let wanted = share > 0 && lower < last ? [lower, lower + 1] : [lower]
        easedFields.removeAll { !wanted.contains($0.frame) }
        for frame in wanted where !easedFields.contains(where: { $0.frame == frame }) {
            try buildLengths(
                Double(frame) == position ? decoded : positions(atCaptured: Double(frame)))
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

    /// Sets the renderer on the moment of the flight at `seconds`: the positions, the eased
    /// lengths, the shot's look, and how far the eye is from matter there.
    private func stage(_ flight: Flight, atSeconds seconds: Double) throws -> (
        shot: ShotReplay.Shot, within: InsideFrame
    ) {
        let captured = flight.captured(atSeconds: seconds)
        let decoded = try positions(atCaptured: captured)
        try easeLengths(at: captured, decoded)
        let frame = TimeTrack.Frame(played: seconds * Double(capturedRate), captured: captured)
        guard
            let shot = TakeFraming.prepare(
                renderer, look: look, shot: flight.shot(atSeconds: seconds, look: look.look),
                framing: framing, at: frame)
        else { throw RecordingFile.Failure.truncated }
        try renderer.upload(positions: decoded)
        try renderer.setSmoothing(lengths)
        let within = InsideFrame(
            settings: flight.inside,
            nearness: decoded.withUnsafeBytes { bytes in
                bytes.baseAddress.map {
                    Nearness.distance(from: shot.camera.eye, to: $0, count: renderer.drawnCount)
                } ?? .infinity
            })
        renderer.inside = within
        return (shot, within)
    }

    private func pixels(_ camera: Camera, threads: Int) throws -> [UInt8] {
        [UInt8](try renderer.picture(camera: camera, format: .rgba, threads: threads))
    }

    /// The exposure of a flight, as `TakeExport` measures it (#297): the scale of a look that
    /// takes its exposure from the frames (#340), measured on the photograph the flight leaves
    /// from, its look keys or its first frame; and the mean luminance the automatic exposure
    /// holds its frames under, the settings' or the brightest of the look keys' when that is
    /// more.
    private func exposure(of flight: Flight, threads: Int) throws -> (scale: ExposureScale?, target: Float) {
        if let flightExposure { return flightExposure }
        let keys = flight.file.keys.filter { $0.look == true }.map(\.at)
        var scale: ExposureScale?
        if let wanted = look.exposure {
            let moments = keys.isEmpty ? [0] : keys
            var solutions: [ExposureSolver.Solution] = []
            for index in ClipExposure.samples(of: moments.count) {
                let (shot, _) = try stage(flight, atSeconds: moments[index])
                let solved = try ExposureSolver.solve(
                    target: wanted, stretches: shot.look.stretch > 0,
                    draw: { scale in
                        renderer.apply(scale.applied(to: shot.look))
                        return ExposureMeter.read(
                            rgba: try pixels(shot.camera, threads: threads), width: width, height: height)
                    })
                if let solved { solutions.append(solved) }
            }
            if !solutions.isEmpty { scale = ExposureSolver.held(solutions) }
        }
        var target = Double(flight.inside.exposure)
        if target > 0 {
            for seconds in keys {
                let (shot, _) = try stage(flight, atSeconds: seconds)
                renderer.apply(scale?.applied(to: shot.look) ?? shot.look)
                target = max(
                    target,
                    InsideExposure.meanLuminance(rgba: try pixels(shot.camera, threads: threads)))
            }
        }
        let measured = (scale, Float(target))
        flightExposure = measured
        return measured
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
        guard let flight else { throw CUDAError(.invalidArgument, "these stills have no flight") }
        guard seconds >= 0, seconds <= flight.seconds else {
            throw CUDAError(.invalidArgument, "\(seconds) s is outside the flight's \(flight.seconds) s")
        }
        let (scale, target) = try exposure(of: flight, threads: threads)
        let (shot, within) = try stage(flight, atSeconds: seconds)
        func exposed(_ stops: Double) -> RenderLook {
            let trimmed = InsideExposure.trimmed(shot.look, stops: stops)
            return scale?.applied(to: trimmed) ?? trimmed
        }
        var stops = 0.0
        if target > 0, !flight.lookSpans.contains(where: { $0.contains(seconds) }) {
            var failure: (any Error)?
            stops = InsideExposure.solve(target: Double(target)) { stops in
                renderer.apply(exposed(stops))
                do {
                    return InsideExposure.meanLuminance(rgba: try pixels(shot.camera, threads: threads))
                } catch {
                    failure = failure ?? error
                    return 0
                }
            }
            if let failure { throw failure }
        }
        renderer.apply(exposed(stops))
        let views =
            interval > 0
            ? flight.cameras(atSeconds: seconds, interval: interval, frame: within, height: height)
            : [shot.camera]
        renderer.setGrain(frame: index)
        let picture = try renderer.picture(cameras: views, format: format, threads: threads)
        lastFlightFrame = FlightFrame(
            nearness: within.nearness, stops: stops, renders: max(views.count - 1, 1),
            stars: renderer.starsDrawn)
        return picture
    }
}
