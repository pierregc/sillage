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

        public var renderedPerSecond: Double { Double(frames) / max(seconds, 1e-9) }
        public var speed: Double { renderedPerSecond / Double(max(framesPerSecond, 1)) }
    }

    public let take: RecordingFile.Loaded
    /// Where the camera, the painted arms, the time and the exposure are read: `take` itself,
    /// or another take of the same run, the massive one a full pass is framed on (#239).
    public let framing: RecordingFile.Loaded
    public let look: LookFile
    /// The rate the run was captured at, which decides how long the take plays.
    public let capturedRate: Int
    private let device: MTLDevice
    private let positions: MTLBuffer
    private let expander: SnapshotExpander
    private let smoothing: SmoothingField
    private let stream: SnapshotStream

    public init(
        take: RecordingFile.Loaded, look: LookFile, capturedRate: Int, device: MTLDevice? = nil,
        framing: RecordingFile.Loaded? = nil
    ) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else {
            throw RenderError.noDevice
        }
        self.take = take
        self.framing = framing ?? take
        self.look = look
        self.capturedRate = max(capturedRate, 1)
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
    public var takeSeconds: Double { Double(capturedFrames - 1) / Double(capturedRate) }

    /// Captured positions, fractional between captured frames, of every frame a video at
    /// `framesPerSecond` shows from `start` for `duration` seconds, cut at the end of the take.
    public func positions(framesPerSecond: Int, start: Double, duration: Double?) -> [Double] {
        let rate = Double(capturedRate)
        let last = Double(capturedFrames - 1)
        let first = min(max(start, 0) * rate, last)
        let step = rate / Double(max(framesPerSecond, 1))
        let span = min(duration.map { max($0, 0) * rate } ?? last, last - first)
        let count = duration.map { max(Int(($0 * Double(framesPerSecond)).rounded()), 1) }
        let fitting = Int((span / step + 1e-9).rounded(.down)) + 1
        return (0..<min(count ?? fitting, fitting)).map { first + Double($0) * step }
    }

    /// `stills` are frames of the video, counted from its first, handed to `still` exactly as
    /// the encoder takes them.
    public func write(
        to url: URL, width: Int, height: Int, framesPerSecond: Int, start: Double = 0,
        duration: Double? = nil, codec: VideoCodec = .hevc, bitsPerSecond: Int? = nil,
        quality: Double? = nil, metadata: VideoMetadata? = nil, stills: Set<Int> = [],
        still: @escaping (_ frame: Int, _ image: CGImage) throws -> Void = { _, _ in },
        progress: (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) throws -> Report {
        let wanted = positions(framesPerSecond: framesPerSecond, start: start, duration: duration)
        let renderer = try makeRenderer(width: width, height: height)
        let replay = makeReplay(width: width, height: height)
        let writer = try VideoWriter(
            width: width, height: height, framesPerSecond: Int32(framesPerSecond), codec: codec,
            bitsPerSecond: bitsPerSecond, quality: quality, metadata: metadata, to: url)
        let started = Date()
        for (index, position) in wanted.enumerated() {
            let shot = try prepare(renderer, at: position, replay: replay)
            try writer.append(
                on: device,
                drawing: { target, buffer in
                    renderer.encode(camera: shot.camera, into: buffer, present: target)
                },
                read: stills.contains(index)
                    ? { pixels in if let image = PNGWriter.image(bgra: pixels) { try still(index, image) } }
                    : nil)
            progress(index + 1, wanted.count)
        }
        try writer.finish()
        return Report(
            frames: wanted.count, seconds: Date().timeIntervalSince(started),
            framesPerSecond: framesPerSecond)
    }

    /// Every frame a video at `framesPerSecond` would show, drawn as the video draws them and
    /// read back as RGBA, for the animations that are not written through the encoder.
    public func frames(
        width: Int, height: Int, framesPerSecond: Int, start: Double = 0,
        duration: Double? = nil, progress: (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) throws -> [[UInt8]] {
        let wanted = positions(framesPerSecond: framesPerSecond, start: start, duration: duration)
        let renderer = try makeRenderer(width: width, height: height)
        let replay = makeReplay(width: width, height: height)
        return try wanted.enumerated().map { index, position in
            let shot = try prepare(renderer, at: position, replay: replay)
            defer { progress(index + 1, wanted.count) }
            return renderer.render(camera: shot.camera)
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

    /// One frame as the export draws it, read back as RGBA.
    func still(atCaptured frame: Int, width: Int, height: Int) throws -> [UInt8] {
        let renderer = try makeRenderer(width: width, height: height)
        let shot = try prepare(
            renderer, at: Double(frame), replay: makeReplay(width: width, height: height))
        return renderer.render(camera: shot.camera)
    }

    /// The shot each of `positions`, in the order a video plays them, is drawn through at
    /// `width` by `height`: what a canvas showing the export's framing is checked against.
    public func shots(atCaptured positions: [Double], width: Int, height: Int) -> [ShotReplay.Shot] {
        let replay = makeReplay(width: width, height: height)
        return positions.map { replay.shot(atCaptured: $0) }
    }

    private func makeReplay(width: Int, height: Int) -> ShotReplay {
        TakeFraming.replay(
            look: look, framing: framing, capturedRate: capturedRate, width: width, height: height)
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

    private func prepare(_ renderer: Renderer, at position: Double, replay: ShotReplay) throws
        -> ShotReplay.Shot
    {
        let recording = take.recording
        guard let blend = recording.blend(atCaptured: position),
            expander.expand(blend, of: recording, through: stream, into: positions)
        else { throw RecordingFile.Failure.truncated }
        // Every frame, as the look grid does: a field refreshed every few frames would leave
        // a still of the grid and the same frame here a kernel apart.
        smoothing.update(from: positions)
        guard
            let shot = TakeFraming.prepare(
                renderer, look: look, replay: replay, framing: framing, at: position)
        else { throw RecordingFile.Failure.truncated }
        return shot
    }
}
