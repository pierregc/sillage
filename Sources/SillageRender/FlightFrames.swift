import Foundation
import SillageCore

#if canImport(simd)
    import simd
#endif

/// What an engine gives the frames of a take, along a flight (#382) or not (#429): the renderer a
/// frame is prepared on, the take's positions at a moment with their kernel lengths, and a render
/// read back for the measures. `FlightFrames` and `TakeFrames` work out everything else, the same
/// for every engine.
public protocol FrameStage: AnyObject {
    /// What a frame's look, palette, time and painted arms are set on.
    var styling: any FrameStyling { get }
    var drawnCount: Int { get }
    /// What the next renders take of the inside of a galaxy; nil draws as every export does.
    var inside: InsideFrame? { get set }
    /// The angle the view turns, and its roll about it, while a frame's shutter is open, by which
    /// the deep sky fades (#512, `SkyParams.turn`); zero for a still.
    var skyTurn: SIMD2<Float> { get set }
    /// The point stars the last render drew.
    var starsDrawn: Int { get }
    /// Puts the take's positions at `place` and their kernel lengths on the engine, and gives the
    /// positions sixteen bytes apart, valid until the next call. A flight's lengths are `eased`
    /// between the take's own frames (#297); a take's video builds them at every moment.
    func stage(_ place: FlightFrames.Place, eased: Bool) throws -> UnsafeRawPointer
    /// Puts the film grain where frame `index` of a video finds it.
    func setGrain(frame index: Int)
    /// One render through `camera` with what is set, read back as RGBA.
    func measure(camera: Camera) throws -> [UInt8]
}

/// The frames of a flight (#295, #297), worked out apart from the engine that draws them: the
/// camera and the moment of each, the look it is drawn with, how far the eye is from matter
/// there, the renders its shutter passes, and its exposure, the scale of a look that measures
/// its own (#340) and the automatic trim solved along the whole flight and eased. What
/// `TakeExport` does for Metal, in the same order, so that an engine that draws through it draws
/// the frames the Mac's `export --flight` draws.
public final class FlightFrames {
    /// Where a frame reads the take.
    public struct Place: Sendable, Equatable {
        /// The captured position in the framing take's run.
        public var captured: Double
        /// Among the take's own frames, and the run of them it falls in, when the take holds only
        /// some moments of that run (#379).
        public var stored: Double?
        public var run: ClosedRange<Int>?

        public init(captured: Double, stored: Double? = nil, run: ClosedRange<Int>? = nil) {
            self.captured = captured
            self.stored = stored
            self.run = run
        }

        /// The blend of the take's frames there.
        public func blend(in recording: Recording) -> Recording.Blend? {
            if let stored, let run { return recording.blend(atStored: stored, within: run) }
            return recording.blend(atCaptured: captured)
        }
    }

    /// What the frames took of the inside of a galaxy, for the log: `TakeExport.InsideReport`.
    public struct Report: Sendable, Equatable, Codable {
        /// The nearest the eye came to matter, in kiloparsecs (`Nearness`).
        public var nearest = Float.infinity
        /// The deepest trim the automatic exposure took, in stops.
        public var deepestTrim = 0.0
        /// The most renders a frame was averaged from, and all the renders drawn.
        public var mostRenders = 1
        public var renders = 0
        /// The most point stars a render drew.
        public var mostStars = 0
        /// Within a kiloparsec of matter: the most the eye moved between two frames, in parsecs,
        /// and the fastest the take's time ran, against the speed it was captured at.
        public var fastestNear = 0.0
        public var fastestTimeNear = 0.0
        /// The share of the nearness the eye covers each second on each run paced by it (#406).
        public var paces: [Double] = []

        public init(paces: [Double] = []) { self.paces = paces }

        private enum CodingKeys: String, CodingKey {
            case nearest, deepestTrim, mostRenders, renders, mostStars, fastestNear, fastestTimeNear, paces
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // JSON has no infinity: a frame that saw nothing leaves no nearest.
            nearest = try c.decodeIfPresent(Float.self, forKey: .nearest) ?? .infinity
            deepestTrim = try c.decode(Double.self, forKey: .deepestTrim)
            mostRenders = try c.decode(Int.self, forKey: .mostRenders)
            renders = try c.decode(Int.self, forKey: .renders)
            mostStars = try c.decode(Int.self, forKey: .mostStars)
            fastestNear = try c.decode(Double.self, forKey: .fastestNear)
            fastestTimeNear = try c.decode(Double.self, forKey: .fastestTimeNear)
            paces = try c.decodeIfPresent([Double].self, forKey: .paces) ?? []
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            if nearest.isFinite { try c.encode(nearest, forKey: .nearest) }
            try c.encode(deepestTrim, forKey: .deepestTrim)
            try c.encode(mostRenders, forKey: .mostRenders)
            try c.encode(renders, forKey: .renders)
            try c.encode(mostStars, forKey: .mostStars)
            try c.encode(fastestNear, forKey: .fastestNear)
            try c.encode(fastestTimeNear, forKey: .fastestTimeNear)
            if !paces.isEmpty { try c.encode(paces, forKey: .paces) }
        }

        /// Takes in what other frames of the same video took.
        public mutating func merge(_ other: Report) {
            nearest = min(nearest, other.nearest)
            deepestTrim = max(deepestTrim, other.deepestTrim)
            mostRenders = max(mostRenders, other.mostRenders)
            renders += other.renders
            mostStars = max(mostStars, other.mostStars)
            fastestNear = max(fastestNear, other.fastestNear)
            fastestTimeNear = max(fastestTimeNear, other.fastestTimeNear)
            if paces.isEmpty { paces = other.paces }
        }

        public var summary: String {
            let near =
                nearest.isFinite
                ? (nearest < 1
                    ? String(format: "%.0f pc", nearest * 1000) : String(format: "%.1f kpc", nearest))
                : "nothing"
            var text = "nearest matter \(near) from the eye"
            text += String(format: ", exposure down by up to %.1f stops", deepestTrim)
            if mostStars > 0 {
                text += String(format: ", up to %.1f M point stars a render", Double(mostStars) / 1e6)
            }
            if mostRenders > 1 { text += ", up to \(mostRenders) renders a frame (\(renders) in all)" }
            if fastestNear > 0 {
                text += String(
                    format: "; within 1 kpc of matter the eye moves up to %.1f pc a frame", fastestNear)
            }
            if !paces.isEmpty {
                let shares = paces.map { String(format: "%.2f", $0) }.joined(separator: ", ")
                text += "; paced at \(shares) of the nearness a second"
            }
            // Past a hundredth of its speed the nearest stars dart from their own motions.
            if fastestTimeNear > 0.0125 {
                text += String(
                    format: " and time runs at up to 1/%.0f of the take's speed: the nearest stars will dart",
                    1 / fastestTimeNear)
            }
            return text
        }
    }

    /// The exposure every frame of the flight is drawn under, measured once for the whole of it.
    public struct Exposure: Sendable, Equatable {
        /// What a look that takes its exposure from the frames (#340) is scaled by; nil when the
        /// look keeps its own.
        public var scale: ExposureScale?
        /// The mean luminance the automatic exposure holds the frames under, 0 with it off.
        public var target: Float
        /// The trims solved along the flight; nil for a still, which takes its own.
        public var trims: InsideExposure.Track?

        public init(scale: ExposureScale?, target: Float, trims: InsideExposure.Track? = nil) {
            self.scale = scale
            self.target = target
            self.trims = trims
        }
    }

    /// One frame set up on the engine: its shot with the look as drawn, the cameras its renders
    /// go through, and what it takes of the inside of a galaxy.
    public struct Frame {
        public var seconds: Double
        public var shot: ShotReplay.Shot
        public var cameras: [Camera]
        public var within: InsideFrame
        /// The automatic exposure's trim, in stops.
        public var stops: Double
        /// The renders the frame is averaged from.
        public var renders: Int { max(cameras.count - 1, 1) }
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case holeFlight
        case outside(seconds: Double, flight: Double)

        public var description: String {
            switch self {
            case .holeFlight: "a flight that gives the hole's time is for a black hole close up"
            case .outside(let seconds, let flight):
                String(format: "%g s is outside the flight's %g s", seconds, flight)
            }
        }
    }

    /// Seconds of video between the moments a flight's automatic exposure is solved at.
    public static let trimStep = 0.25
    /// Frames of the video's time checked against the frames held, a second.
    static let heldCheckRate = 120

    public let take: RecordingFile.Loaded
    /// Where the camera, the painted arms, the time and the exposure are read: `take` itself, or
    /// another take of the same run (#239).
    public let framing: RecordingFile.Loaded
    public let look: LookFile
    public let capturedRate: Int
    public let width: Int
    public let height: Int
    public let flight: Flight
    /// Where the take's frames stand in the framing take's run when it holds only some of its
    /// moments, key frames or an extract (#379).
    public let held: HeldFrames?
    /// What the frames prepared so far took of the inside of a galaxy.
    public private(set) var report = Report()
    /// The frame of a video prepared before this one, for the speeds the report gives.
    private var before: (played: Double, captured: Double, eye: SIMD3<Float>)?
    private var stillExposure: Exposure?

    public init(
        take: RecordingFile.Loaded, look: LookFile, capturedRate: Int, width: Int, height: Int,
        framing: RecordingFile.Loaded? = nil, flight file: FlightFile
    ) throws {
        if file.isBlackHole { throw Failure.holeFlight }
        self.take = take
        let framed = framing ?? take
        self.framing = framed
        self.look = look
        let rate = max(capturedRate, 1)
        self.capturedRate = rate
        self.width = width
        self.height = height
        // A take whose frames are not its framing take's holds some moments of that run: it is
        // played in the framing take's frames, and each frame drawn is placed among its own.
        var held: HeldFrames?
        if framed.recording !== take.recording,
            framed.recording.capturedFrames != take.recording.capturedFrames
        {
            held = try HeldFrames(
                times: take.recording.frames.map { Double($0.time) * Physics.megayearsPerTimeUnit },
                megayears: TimeTrack.megayears(of: framed.recording), interval: framed.recording.interval)
        }
        self.held = held
        // Its `look` keys stand on the camera the export draws without it.
        var replay: ShotReplay?
        flight = try Flight(
            file, take: FlightTake(take: framed, capturedRate: rate),
            look: { position in
                let cameras =
                    replay
                    ?? TakeFraming.replay(
                        look: look, framing: framed, capturedRate: rate, width: width, height: height)
                replay = cameras
                return cameras.shot(atCaptured: position).camera
            })
        // The whole flight, before anything is drawn: a time that leaves the frames held is
        // refused with what is there.
        if let held {
            for frame in flight.track.frames(framesPerSecond: Self.heldCheckRate, start: 0, duration: nil) {
                _ = try held.place(atCaptured: frame.captured)
            }
        }
        report = Report(paces: flight.pacings.map(\.share))
    }

    /// Every frame a video at `framesPerSecond` shows from `start` for `duration` seconds.
    public func videoFrames(framesPerSecond: Int, start: Double = 0, duration: Double? = nil)
        -> [TimeTrack.Frame]
    {
        flight.track.frames(framesPerSecond: framesPerSecond, start: start, duration: duration)
    }

    /// The frame the video shows `seconds` into the flight.
    public func frame(atSeconds seconds: Double) -> TimeTrack.Frame {
        TimeTrack.Frame(
            played: seconds * Double(capturedRate), captured: flight.captured(atSeconds: seconds))
    }

    /// The seconds of the keys that stand on the look's own camera.
    public var lookKeys: [Double] { flight.file.keys.filter { $0.look == true }.map(\.at) }

    func place(atCaptured position: Double) throws -> Place {
        guard let held else { return Place(captured: position) }
        let place = try held.place(atCaptured: position)
        return Place(captured: position, stored: place.stored, run: place.run)
    }

    /// Sets `stage` on a frame: the positions, the look, the time and the painted arms of its
    /// moment, how far the eye is from matter there, and its exposure. With `interval`, the
    /// seconds between two frames of the video, the cameras are the ones the frame's renders go
    /// through, and the report takes the frame in.
    public func prepare(
        on stage: some FrameStage, at frame: TimeTrack.Frame, exposure: ExposureScale?,
        trims: InsideExposure.Track? = nil, interval: Double = 0
    ) throws -> Frame {
        let points = try stage.stage(place(atCaptured: frame.captured), eased: true)
        let seconds = frame.played / Double(capturedRate)
        let styling = stage.styling
        guard
            var shot = TakeFraming.prepare(
                styling, look: look, shot: flight.shot(atSeconds: seconds, look: look.look),
                framing: framing, at: frame)
        else { throw RecordingFile.Failure.truncated }
        let settings = styling.settings
        let within = InsideFrame(
            settings: flight.inside,
            nearness: Nearness.distance(from: shot.camera.eye, to: points, count: stage.drawnCount),
            matter: MatterDepth.knots(
                camera: shot.camera, aspectRatio: Float(settings.width) / Float(max(settings.height, 1)),
                points: points, count: stage.drawnCount,
                dust: flight.inside.dustSlabs > 0 ? (take.particles.component, flight.inside.dustSlabs) : nil)
                ?? [],
            look: flight.look(atSeconds: seconds))
        stage.inside = within
        stage.skyTurn = .zero
        var views = [shot.camera]
        if interval > 0 {
            views = flight.cameras(
                atSeconds: seconds, interval: interval, frame: within, height: settings.height)
            let half = interval * flight.inside.shutter / 2
            stage.skyTurn = SkyParams.turn(
                from: flight.camera(atSeconds: max(seconds - half, 0)).camera,
                to: flight.camera(atSeconds: min(seconds + half, flight.seconds)).camera)
        }
        let stops = trims?.stops(atSeconds: seconds) ?? 0
        shot.look = InsideExposure.trimmed(shot.look, stops: stops)
        if interval > 0 {
            report.deepestTrim = max(report.deepestTrim, stops)
            report.mostRenders = max(report.mostRenders, views.count - 1)
            report.renders += max(views.count - 1, 1)
            // Against the frame before, when it is the one before in the video.
            let step = interval * Double(capturedRate)
            if let before, within.nearness < 1, abs(frame.played - before.played - step) < 1e-6 * step {
                report.fastestNear = max(
                    report.fastestNear, Double(simd_length(shot.camera.eye - before.eye)) * 1000)
                report.fastestTimeNear = max(
                    report.fastestTimeNear, abs(frame.captured - before.captured) / step)
            }
            before = (frame.played, frame.captured, shot.camera.eye)
        }
        if exposure != nil || stops > 0 { styling.apply(exposure?.applied(to: shot.look) ?? shot.look) }
        return Frame(seconds: seconds, shot: shot, cameras: views, within: within, stops: stops)
    }

    /// Says which frame of the video came before the next one prepared, when it was not
    /// prepared here: a video drawn in pieces keeps the speeds its report gives.
    public func follow(_ frame: TimeTrack.Frame) {
        let seconds = frame.played / Double(capturedRate)
        before = (frame.played, frame.captured, flight.camera(atSeconds: seconds).camera.eye)
    }

    /// Keeps what the frame `stage` has just drawn took of the inside of a galaxy.
    public func note(_ stage: some FrameStage, stops: Double? = nil) {
        guard let frame = stage.inside else { return }
        report.nearest = min(report.nearest, frame.nearness)
        report.mostStars = max(report.mostStars, stage.starsDrawn)
        if let stops { report.deepestTrim = max(report.deepestTrim, stops) }
    }

    /// Starts the report again, as before a video's first frame.
    public func resetReport() {
        report = Report(paces: flight.pacings.map(\.share))
        before = nil
    }

    // MARK: - Exposure

    /// The exposure of a look that takes its own from the frames (#340). A flight is exposed as
    /// the photograph it leaves from: on its look keys, or on its first frame when it has none,
    /// whatever part of it is drawn. Measured over the whole of it, the inside of a disk would
    /// darken the photograph. Nil when the look keeps its own.
    public func measureScale(on stage: some FrameStage) throws -> ClipExposure? {
        guard let target = look.exposure else { return nil }
        stage.setGrain(frame: 0)
        let keys = lookKeys
        let frames = (keys.isEmpty ? [0] : keys).map { frame(atSeconds: $0) }
        var samples: [ClipExposure.Sample] = []
        for index in ClipExposure.samples(of: frames.count) {
            let prepared = try prepare(on: stage, at: frames[index], exposure: nil)
            let solved = try ExposureSolver.solve(
                target: target, stretches: prepared.shot.look.stretch > 0,
                draw: { scale in
                    stage.styling.apply(scale.applied(to: prepared.shot.look))
                    return ExposureMeter.read(
                        rgba: try stage.measure(camera: prepared.shot.camera), width: width, height: height)
                })
            if let solved { samples.append(.init(captured: frames[index].captured, solution: solved)) }
        }
        guard !samples.isEmpty else { return nil }
        return ClipExposure(scale: ExposureSolver.held(samples.map(\.solution)), samples: samples)
    }

    /// The mean luminance the flight's frames are held under: the settings', or the brightest of
    /// the frames at its look keys when that is more, since the photograph is exposed as the
    /// export exposes it. 0 with the automatic exposure off.
    public func measureTarget(on stage: some FrameStage, scale: ExposureScale?) throws -> Float {
        guard flight.inside.exposure > 0 else { return 0 }
        stage.setGrain(frame: 0)
        var target = Double(flight.inside.exposure)
        for seconds in lookKeys {
            let prepared = try prepare(on: stage, at: frame(atSeconds: seconds), exposure: scale)
            target = max(
                target, InsideExposure.meanLuminance(rgba: try stage.measure(camera: prepared.shot.camera)))
        }
        return Float(target)
    }

    /// The exposure of the whole flight (#297): the look's scale, then the trim that holds each
    /// frame under the target, solved every `trimStep` seconds along the whole flight, whatever
    /// part of it is drawn, and eased. `progress` hears of each moment solved.
    public func measure(
        on stage: some FrameStage, progress: (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) throws -> (exposure: Exposure, clip: ClipExposure?) {
        let clip = try measureScale(on: stage)
        let scale = clip?.scale
        guard flight.inside.exposure > 0 else { return (Exposure(scale: scale, target: 0), clip) }
        let target = try measureTarget(on: stage, scale: scale)
        let spans = flight.lookSpans
        let moments = InsideExposure.Track.moments(seconds: flight.seconds, step: Self.trimStep)
        var stops: [Double] = []
        for (index, seconds) in moments.enumerated() {
            defer { progress(index + 1, moments.count) }
            guard !spans.contains(where: { $0.contains(seconds) }) else {
                stops.append(0)
                continue
            }
            let prepared = try prepare(on: stage, at: frame(atSeconds: seconds), exposure: scale)
            stops.append(
                try solveTrim(on: stage, prepared.shot, scale: scale, target: target, guess: stops.last ?? 0))
        }
        let track = InsideExposure.Track(
            step: Self.trimStep, stops: stops, ease: flight.inside.exposureEase, still: spans)
        return (Exposure(scale: scale, target: target, trims: track), clip)
    }

    private func solveTrim(
        on stage: some FrameStage, _ shot: ShotReplay.Shot, scale: ExposureScale?, target: Float,
        guess: Double
    ) throws -> Double {
        var failure: (any Error)?
        let stops = InsideExposure.solve(target: Double(target), guess: guess) { stops in
            stage.styling.apply(Self.exposed(shot.look, stops: stops, scale))
            do {
                return InsideExposure.meanLuminance(rgba: try stage.measure(camera: shot.camera))
            } catch {
                failure = failure ?? error
                return 0
            }
        }
        if let failure { throw failure }
        return stops
    }

    static func exposed(_ look: RenderLook, stops: Double, _ scale: ExposureScale?) -> RenderLook {
        let trimmed = InsideExposure.trimmed(look, stops: stops)
        return scale?.applied(to: trimmed) ?? trimmed
    }

    // MARK: - A frame alone

    /// A moment of the flight set up at its own exposure, a still having no moments around it to
    /// ease it over: the look's scale and the target measured once, then the trim of that moment
    /// alone. With `interval`, the cameras of the renders a frame that long is averaged from.
    public func still(on stage: some FrameStage, atSeconds seconds: Double, interval: Double = 0) throws
        -> Frame
    {
        guard seconds >= 0, seconds <= flight.seconds else {
            throw Failure.outside(seconds: seconds, flight: flight.seconds)
        }
        let exposure: Exposure
        if let stillExposure {
            exposure = stillExposure
        } else {
            let scale = try measureScale(on: stage)?.scale
            exposure = Exposure(scale: scale, target: try measureTarget(on: stage, scale: scale))
            stillExposure = exposure
        }
        var frame = try prepare(
            on: stage, at: frame(atSeconds: seconds), exposure: exposure.scale, interval: interval)
        var stops = 0.0
        if exposure.target > 0, !flight.lookSpans.contains(where: { $0.contains(seconds) }) {
            // Where the grain stands once the target is measured, whatever was drawn before.
            stage.setGrain(frame: lookKeys.count)
            stops = try solveTrim(
                on: stage, frame.shot, scale: exposure.scale, target: exposure.target, guess: 0)
        }
        stage.styling.apply(Self.exposed(frame.shot.look, stops: stops, exposure.scale))
        frame.stops = stops
        report.deepestTrim = max(report.deepestTrim, stops)
        return frame
    }
}
