import CoreGraphics
import Foundation
import Metal
import SillageCore
import simd

/// Draws a take with a look file into a video, frame by frame and as fast as the GPU goes,
/// at any size and frame rate. The camera is replayed from the first captured frame as the
/// look grid replays it, so the same frame of both is the same picture.
public final class TakeExport {
    public struct Report: Sendable {
        public var frames: Int
        public var seconds: Double
        public var framesPerSecond: Int

        /// The overlay's captions and what it could not do, for the log.
        public var overlay: [String] = []
        /// What the look measured and drew with when it takes its exposure from the frames (#340).
        public var exposure: ClipExposure?

        public var renderedPerSecond: Double { Double(frames) / max(seconds, 1e-9) }
        public var speed: Double { renderedPerSecond / Double(max(framesPerSecond, 1)) }
    }

    public let take: RecordingFile.Loaded
    /// Where the camera, the painted arms, the time and the exposure are read: `take` itself,
    /// or another take of the same run, the massive one a full pass is framed on (#239).
    public let framing: RecordingFile.Loaded
    public let look: LookFile
    /// Written over every frame after the post-processing (#317); nil draws the picture alone.
    public var overlay: OverlayRequest?
    /// The rate the run was captured at, which decides how long the take plays.
    public let capturedRate: Int
    /// From the video's time to the take's (#305): one captured frame per played one unless
    /// given.
    public let track: TimeTrack
    /// A camera path of its own (#295), over its own time track; nil follows the look's plan.
    public let flight: FlightFile?
    private let device: MTLDevice
    private let positions: MTLBuffer
    private let expander: SnapshotExpander
    private let smoothing: SmoothingField
    private let stream: SnapshotStream
    /// The captured position `positions` holds, and the smoothing drawn from it: a frame at the
    /// same moment of the take, as a freeze or a slow track gives, draws from them again.
    private var expanded: Double?
    /// How many times the take was expanded, for the tests.
    private(set) var expansions = 0
    /// The exposure the last frames drawn were held to, when the look measures its own (#340).
    public private(set) var exposure: ClipExposure?

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case trackForAnotherTake(track: Int, take: Int)
        case flightAndTrack

        public var description: String {
            switch self {
            case .trackForAnotherTake(let track, let take):
                "a time track of \(track) captured frames for a take of \(take)"
            case .flightAndTrack: "a flight keeps its own time: it takes no other track"
            }
        }
    }

    public init(
        take: RecordingFile.Loaded, look: LookFile, capturedRate: Int, device: MTLDevice? = nil,
        framing: RecordingFile.Loaded? = nil, track: TimeTrack? = nil, flight: FlightFile? = nil
    ) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else {
            throw RenderError.noDevice
        }
        self.take = take
        self.framing = framing ?? take
        self.look = look
        self.capturedRate = max(capturedRate, 1)
        let frames = take.recording.capturedFrames
        self.flight = flight
        if flight != nil, track != nil { throw Failure.flightAndTrack }
        let track =
            try flight?.timeTrack(
                megayears: TimeTrack.megayears(of: (framing ?? take).recording),
                capturedRate: self.capturedRate)
            ?? track
        if let track, track.capturedFrames != frames || track.capturedRate != self.capturedRate {
            throw Failure.trackForAnotherTake(track: track.capturedFrames, take: frames)
        }
        self.track =
            try track ?? TimeTrack(capturedFrames: frames, capturedRate: self.capturedRate)
        self.device = device
        let count = take.recording.particleCount
        guard
            let positions = device.makeBuffer(
                length: count * MemoryLayout<SIMD3<Float>>.stride, options: .storageModeShared),
            let stream = SnapshotStream(device: device, recording: take.recording)
        else { throw RenderError.noDevice }
        self.positions = positions
        self.stream = stream
        expander = try SnapshotExpander(device: device, recording: take.recording)
        smoothing = try SmoothingField(device: device, particleCount: count)
    }

    public var capturedFrames: Int { take.recording.capturedFrames }
    public var gpuName: String { device.name }
    public var takeSeconds: Double { Double(capturedFrames - 1) / Double(capturedRate) }
    /// The whole take's video along the track.
    public var videoSeconds: Double { track.seconds }

    /// Captured positions, fractional between captured frames, of every frame a video at
    /// `framesPerSecond` shows from `start` for `duration` seconds of video, cut at the end of
    /// the take.
    public func positions(framesPerSecond: Int, start: Double, duration: Double?) -> [Double] {
        videoFrames(framesPerSecond: framesPerSecond, start: start, duration: duration).map(\.captured)
    }

    /// The same frames, each with its moment in the video's time as well.
    public func videoFrames(framesPerSecond: Int, start: Double, duration: Double?) -> [TimeTrack.Frame] {
        track.frames(framesPerSecond: framesPerSecond, start: start, duration: duration)
    }

    /// `stills` are frames of the video, counted from its first, handed to `still` exactly as
    /// the encoder takes them. `dumps` are frames of the video too: once drawn, `dump` is handed
    /// what their particle passes left and drew from (#276).
    public func write(
        to url: URL, width: Int, height: Int, framesPerSecond: Int, start: Double = 0,
        duration: Double? = nil, codec: VideoCodec = .hevc, bitsPerSecond: Int? = nil,
        quality: Double? = nil, metadata: VideoMetadata? = nil, stills: Set<Int> = [],
        still: @escaping (_ frame: Int, _ image: CGImage) throws -> Void = { _, _ in },
        dumps: Set<Int> = [],
        dump: (_ frame: Int, _ capture: RenderTargetManifest.Capture) throws -> Void = { _, _ in },
        progress: (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) throws -> Report {
        let wanted = videoFrames(framesPerSecond: framesPerSecond, start: start, duration: duration)
        let renderer = try makeRenderer(width: width, height: height)
        let cameras = try makeCameras(width: width, height: height)
        let plan = try overlayPlan(at: wanted, framesPerSecond: framesPerSecond, width: width, height: height)
        let painter = OverlayPainter()
        let scale = try measureExposure(wanted, width: width, height: height)
        let writer = try VideoWriter(
            width: width, height: height, framesPerSecond: Int32(framesPerSecond), codec: codec,
            bitsPerSecond: bitsPerSecond, quality: quality, metadata: metadata, to: url)
        let started = Date()
        for (index, frame) in wanted.enumerated() {
            let shot = try prepare(renderer, at: frame, cameras: cameras, exposure: scale)
            try writer.append(
                on: device,
                drawing: { target, buffer in
                    renderer.encode(camera: shot.camera, into: buffer, present: target)
                },
                over: plan.map { plan in { painter.draw(plan.frames[index], into: $0) } },
                read: stills.contains(index)
                    ? { pixels in if let image = PNGWriter.image(bgra: pixels) { try still(index, image) } }
                    : nil)
            if dumps.contains(index), let capture = capture(renderer, at: frame, shot, cameras.plan) {
                try dump(index, capture)
            }
            progress(index + 1, wanted.count)
        }
        try writer.finish()
        return Report(
            frames: wanted.count, seconds: Date().timeIntervalSince(started),
            framesPerSecond: framesPerSecond,
            overlay: plan?.summary(framesPerSecond: framesPerSecond) ?? [], exposure: exposure)
    }

    /// The overlay of a video showing `positions`, laid out for every frame before the first is
    /// drawn; nil when none is asked.
    public func overlayPlan(at frames: [TimeTrack.Frame], framesPerSecond: Int, width: Int, height: Int)
        throws -> OverlayPlan?
    {
        guard let overlay, !overlay.overlay.isEmpty else { return nil }
        let cameras = try makeCameras(width: width, height: height)
        return OverlayPlan(
            overlay, take: framing, positions: frames.map(\.captured), framesPerSecond: framesPerSecond,
            cameras: frames.map { cameras.shot(at: $0).camera }, width: width, height: height)
    }

    /// Every frame a video at `framesPerSecond` would show, drawn as the video draws them and
    /// read back as RGBA, for the animations that are not written through the encoder.
    public func frames(
        width: Int, height: Int, framesPerSecond: Int, start: Double = 0,
        duration: Double? = nil, progress: (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) throws -> [[UInt8]] {
        let wanted = videoFrames(framesPerSecond: framesPerSecond, start: start, duration: duration)
        let renderer = try makeRenderer(width: width, height: height)
        let cameras = try makeCameras(width: width, height: height)
        let plan = try overlayPlan(at: wanted, framesPerSecond: framesPerSecond, width: width, height: height)
        let painter = OverlayPainter()
        let scale = try measureExposure(wanted, width: width, height: height)
        return try wanted.enumerated().map { index, frame in
            let shot = try prepare(renderer, at: frame, cameras: cameras, exposure: scale)
            defer { progress(index + 1, wanted.count) }
            var pixels = renderer.render(camera: shot.camera)
            if let plan {
                painter.draw(plan.frames[index], intoRGBA: &pixels, width: width, height: height)
            }
            return pixels
        }
    }

    public struct PreviewReport: Sendable {
        public var width: Int
        public var height: Int
        public var framesPerSecond: Int
        public var frames: Int
        public var bytes: Int
        public var seconds: Double
        /// Every size tried, the last one kept.
        public var attempts: [(width: Int, framesPerSecond: Int, bytes: Int)]
    }

    /// The smallest a preview gets while looking for a size under `maximumBytes`: below
    /// these the tails turn to a few pixels and the motion to steps.
    public static let previewFloor = (width: 320, framesPerSecond: 10)

    /// A looping animation of the take. Over `maximumBytes`, the width comes down first, to
    /// `previewFloor`, then the frame rate, each frame rendered again at the new size.
    public func writePreview(
        to url: URL, format: AnimatedImage.Format, width: Int, height: Int,
        framesPerSecond: Int, start: Double = 0, duration: Double? = nil,
        maximumBytes: Int? = nil, quality: Int = 80,
        progress: (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) throws -> PreviewReport {
        let started = Date()
        let aspect = Double(height) / Double(width)
        var (currentWidth, rate) = (width, framesPerSecond)
        var attempts: [(width: Int, framesPerSecond: Int, bytes: Int)] = []
        while true {
            let currentHeight = max(Int((Double(currentWidth) * aspect).rounded()), 1)
            let frames = try self.frames(
                width: currentWidth, height: currentHeight, framesPerSecond: rate, start: start,
                duration: duration, progress: progress)
            try AnimatedImage.write(
                frames, width: currentWidth, height: currentHeight, framesPerSecond: rate,
                format: format, quality: quality, to: url)
            // Not through the URL's resource values, which keep the first size read.
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            attempts.append((currentWidth, rate, bytes))
            guard let maximumBytes, bytes > maximumBytes,
                let next = Self.smaller(
                    width: currentWidth, framesPerSecond: rate,
                    ratio: Double(maximumBytes) / Double(bytes))
            else {
                return PreviewReport(
                    width: currentWidth, height: currentHeight, framesPerSecond: rate,
                    frames: frames.count, bytes: bytes,
                    seconds: Date().timeIntervalSince(started), attempts: attempts)
            }
            (currentWidth, rate) = next
        }
    }

    /// The next size to try when a preview is `1 / ratio` times too big. The bytes go about
    /// as the pixels times the frames, aimed a little under, so most land in one more try.
    static func smaller(width: Int, framesPerSecond: Int, ratio: Double) -> (Int, Int)? {
        let floor = previewFloor
        if width > floor.width {
            return (max(Int(Double(width) * (ratio * 0.9).squareRoot()), floor.width), framesPerSecond)
        }
        if framesPerSecond > floor.framesPerSecond {
            return (width, max(Int(Double(framesPerSecond) * ratio * 0.9), floor.framesPerSecond))
        }
        return nil
    }

    /// The pictures' side of the visual pace (#309): the take drawn small with the export's
    /// camera at moments `spacingMyr` apart, and the change of the log luminance between each
    /// drawing and the next (`VisualPace.change`). `changes[i]` lies between `times[i]` and
    /// `times[i + 1]`. The cameras move on the track's time, so this is meant for an export
    /// without one.
    public func visualChanges(
        width: Int, height: Int, spacingMyr: Double = 1, only: ClosedRange<Double>? = nil,
        drawing: (_ megayears: Double, _ rgba: [UInt8]) throws -> Void = { _, _ in },
        progress: (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) throws -> (times: [Double], changes: [VisualPace.Change]) {
        let megayears = TimeTrack.megayears(of: take.recording)
        guard let first = megayears.first, let last = megayears.last, spacingMyr > 0 else {
            return ([], [])
        }
        let times = Array(stride(from: first, through: last, by: spacingMyr)).filter {
            only?.contains($0) ?? true
        }
        let renderer = try makeRenderer(width: width, height: height)
        let replay = makeReplay(width: width, height: height)
        var changes: [VisualPace.Change] = []
        var previous: [UInt8]?
        for (index, time) in times.enumerated() {
            let position = try TimeTrack.position(of: time, in: megayears)
            let shot = try prepare(
                renderer, at: Self.untracked(position), cameras: .replay(replay), exposure: nil)
            let pixels = renderer.render(camera: shot.camera)
            try drawing(time, pixels)
            if let previous { changes.append(VisualPace.change(previous, pixels)) }
            previous = pixels
            progress(index + 1, times.count)
        }
        return (times, changes)
    }

    /// One frame as the export draws it, read back as RGBA. Captured and played are one
    /// without a track.
    func still(atCaptured frame: Int, width: Int, height: Int) throws -> [UInt8] {
        let renderer = try makeRenderer(width: width, height: height)
        let scale = try measureExposure([Self.untracked(frame)], width: width, height: height)
        let shot = try prepare(
            renderer, at: Self.untracked(frame), cameras: .replay(makeReplay(width: width, height: height)),
            exposure: scale)
        return renderer.render(camera: shot.camera)
    }

    /// One frame as the export draws it, and what its particle passes left and drew from (#276).
    func targets(atCaptured frame: Int, width: Int, height: Int) throws -> (
        pixels: [UInt8], capture: RenderTargetManifest.Capture
    ) {
        let renderer = try makeRenderer(width: width, height: height)
        let replay = makeReplay(width: width, height: height)
        let scale = try measureExposure([Self.untracked(frame)], width: width, height: height)
        let shot = try prepare(renderer, at: Self.untracked(frame), cameras: .replay(replay), exposure: scale)
        let pixels = renderer.render(camera: shot.camera)
        guard let capture = capture(renderer, at: Self.untracked(frame), shot, replay.plan) else {
            throw RenderError.textureAllocation
        }
        return (pixels, capture)
    }

    private static func untracked(_ frame: Int) -> TimeTrack.Frame {
        untracked(Double(frame))
    }

    private static func untracked(_ frame: Double) -> TimeTrack.Frame {
        TimeTrack.Frame(played: frame, captured: frame)
    }

    /// What the frame `renderer` has just drawn at `frame` left in its targets.
    private func capture(
        _ renderer: Renderer, at frame: TimeTrack.Frame, _ shot: ShotReplay.Shot, _ plan: ShotPlan?
    ) -> RenderTargetManifest.Capture? {
        renderer.particleTargets().map {
            RenderTargetManifest.Capture(
                captured: frame.captured, time: renderer.time,
                shot: plan?.shot(atCaptured: frame.played)?.subject.description,
                camera: shot.camera, targets: $0)
        }
    }

    /// The shot each of `positions`, in the order a video plays them, is drawn through at
    /// `width` by `height`: what a canvas showing the export's framing is checked against.
    public func shots(atCaptured positions: [Double], width: Int, height: Int) -> [ShotReplay.Shot] {
        let replay = makeReplay(width: width, height: height)
        return positions.map { replay.shot(atCaptured: $0) }
    }

    func makeReplay(width: Int, height: Int) -> ShotReplay {
        TakeFraming.replay(
            look: look, framing: framing, capturedRate: capturedRate, width: width, height: height,
            track: track)
    }

    /// Where every frame's camera comes from: the look's plan, or a flight.
    enum Cameras {
        case replay(ShotReplay)
        case flight(Flight, look: RenderLook, capturedRate: Int)

        func shot(at frame: TimeTrack.Frame) -> ShotReplay.Shot {
            switch self {
            case .replay(let replay): replay.shot(atPlayed: frame.played)
            case .flight(let flight, let look, let rate):
                flight.shot(atSeconds: frame.played / Double(rate), look: look)
            }
        }

        var plan: ShotPlan? {
            if case .replay(let replay) = self { replay.plan } else { nil }
        }
    }

    func makeCameras(width: Int, height: Int) throws -> Cameras {
        guard let flight = try makeFlight(width: width, height: height) else {
            return .replay(makeReplay(width: width, height: height))
        }
        return .flight(flight, look: look.look, capturedRate: capturedRate)
    }

    /// The flight resolved for frames of `width` by `height`, its `look` keys on the camera the
    /// export draws without it.
    public func makeFlight(width: Int, height: Int) throws -> Flight? {
        guard let flight else { return nil }
        var replay: ShotReplay?
        return try Flight(
            flight, take: FlightTake(take: framing, capturedRate: capturedRate),
            look: { [look, framing, capturedRate] position in
                let cameras =
                    replay
                    ?? TakeFraming.replay(
                        look: look, framing: framing, capturedRate: capturedRate, width: width, height: height
                    )
                replay = cameras
                return cameras.shot(atCaptured: position).camera
            })
    }

    /// The frame at every key of the flight, as RGBA: a flight seen in seconds, nothing encoded.
    public func flightKeys(width: Int, height: Int) throws -> [(seconds: Double, rgba: [UInt8])] {
        guard let flight = try makeFlight(width: width, height: height) else { return [] }
        let renderer = try makeRenderer(width: width, height: height)
        let cameras = Cameras.flight(flight, look: look.look, capturedRate: capturedRate)
        let rate = Double(capturedRate)
        let frames = flight.keySeconds.map { seconds in
            TimeTrack.Frame(played: seconds * rate, captured: flight.captured(atSeconds: seconds))
        }
        let scale = try measureExposure(frames, width: width, height: height)
        return try zip(flight.keySeconds, frames).map { seconds, frame in
            let shot = try prepare(renderer, at: frame, cameras: cameras, exposure: scale)
            return (seconds, renderer.render(camera: shot.camera))
        }
    }

    private func makeRenderer(width: Int, height: Int) throws -> Renderer {
        let renderer = try Renderer(
            device: device, particles: take.particles,
            settings: look.renderSettings(width: width, height: height),
            externalPositions: positions)
        renderer.setSmoothing(smoothing.buffer)
        if framing.recording !== take.recording {
            renderer.luminosityNormalisation = Renderer.luminosityNormalisation(
                formation: framing.particles.formation)
        }
        return renderer
    }

    /// One exposure for `frames`, measured on a few of them by a renderer of its own, so the
    /// grain of the one that draws them is not moved on. Nil when the look keeps its own.
    func measureExposure(_ frames: [TimeTrack.Frame], width: Int, height: Int) throws
        -> ExposureScale?
    {
        exposure = nil
        guard let target = look.exposure, !frames.isEmpty else { return nil }
        let renderer = try makeRenderer(width: width, height: height)
        let cameras = try makeCameras(width: width, height: height)
        var samples: [ClipExposure.Sample] = []
        for index in ClipExposure.samples(of: frames.count) {
            let shot = try prepare(renderer, at: frames[index], cameras: cameras, exposure: nil)
            let solved = ExposureSolver.solve(
                target: target, stretches: shot.look.stretch > 0,
                draw: { scale in
                    renderer.apply(scale.applied(to: shot.look))
                    return ExposureMeter.read(
                        rgba: renderer.render(camera: shot.camera), width: width, height: height)
                })
            if let solved { samples.append(.init(captured: frames[index].captured, solution: solved)) }
        }
        guard !samples.isEmpty else { return nil }
        exposure = ClipExposure(scale: ExposureSolver.held(samples.map(\.solution)), samples: samples)
        return exposure?.scale
    }

    private func prepare(
        _ renderer: Renderer, at frame: TimeTrack.Frame, cameras: Cameras, exposure: ExposureScale?
    ) throws -> ShotReplay.Shot {
        if expanded != frame.captured {
            let recording = take.recording
            expanded = nil
            guard let blend = recording.blend(atCaptured: frame.captured),
                expander.expand(blend, of: recording, through: stream, into: positions)
            else { throw RecordingFile.Failure.truncated }
            // Every frame, as the look grid does: a field refreshed every few frames would leave
            // a still of the grid and the same frame here a kernel apart.
            smoothing.update(from: positions)
            expanded = frame.captured
            expansions += 1
        }
        guard
            let shot = TakeFraming.prepare(
                renderer, look: look, shot: cameras.shot(at: frame), framing: framing, at: frame)
        else { throw RecordingFile.Failure.truncated }
        if let exposure { renderer.apply(exposure.applied(to: shot.look)) }
        return shot
    }
}
