import Foundation
import Metal
import SillageCore
import simd

/// A size and a bit rate under a name, for the places a video ends up.
public struct VideoPreset: Sendable, Equatable {
    public var name: String
    public var width: Int
    public var height: Int
    /// Absent, the encoder's generous default for the size.
    public var bitsPerSecond: Int?
    /// Set when the place only takes one codec, which then cannot be changed.
    public var codec: VideoCodec?

    public static let all = [
        VideoPreset(name: "1080p", width: 1920, height: 1080),
        VideoPreset(name: "4k", width: 3840, height: 2160),
        VideoPreset(name: "vertical", width: 1080, height: 1920),
        VideoPreset(name: "square", width: 1080, height: 1080),
        // WhatsApp keeps a video whole under 16 MB: thirty seconds at 4 Mbit/s is 15, and it
        // plays H.264 whatever the phone.
        VideoPreset(
            name: "whatsapp", width: 1280, height: 720, bitsPerSecond: 4_000_000, codec: .h264),
    ]

    public static func named(_ name: String) -> VideoPreset? {
        all.first { $0.name == name.lowercased() }
    }
}

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
    public let look: LookFile
    /// The rate the run was captured at, which decides how long the take plays.
    public let capturedRate: Int
    private let device: MTLDevice
    private let positions: MTLBuffer
    private let expander: SnapshotExpander
    private let smoothing: SmoothingField
    private let stream: SnapshotStream

    public init(
        take: RecordingFile.Loaded, look: LookFile, capturedRate: Int, device: MTLDevice? = nil
    ) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else {
            throw RenderError.noDevice
        }
        self.take = take
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
        expander = try SnapshotExpander(device: device, particleCount: count)
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

    public func write(
        to url: URL, width: Int, height: Int, framesPerSecond: Int, start: Double = 0,
        duration: Double? = nil, codec: VideoCodec = .h264, bitsPerSecond: Int? = nil,
        quality: Double? = nil, metadata: VideoMetadata? = nil,
        progress: (_ done: Int, _ total: Int) -> Void = { _, _ in }
    ) throws -> Report {
        let wanted = positions(framesPerSecond: framesPerSecond, start: start, duration: duration)
        let renderer = try makeRenderer(width: width, height: height)
        let replay = ShotReplay(
            file: look, take: take, capturedFrames: capturedFrames,
            framesPerSecond: capturedRate)
        let writer = try VideoWriter(
            width: width, height: height, framesPerSecond: Int32(framesPerSecond), codec: codec,
            bitsPerSecond: bitsPerSecond, quality: quality, metadata: metadata, to: url)
        let started = Date()
        for (index, position) in wanted.enumerated() {
            let shot = try prepare(renderer, at: position, replay: replay)
            try writer.append(on: device) { target, buffer in
                renderer.encode(camera: shot.camera, into: buffer, present: target)
            }
            progress(index + 1, wanted.count)
        }
        try writer.finish()
        return Report(
            frames: wanted.count, seconds: Date().timeIntervalSince(started),
            framesPerSecond: framesPerSecond)
    }

    /// One frame as the export draws it, read back as RGBA.
    func still(atCaptured frame: Int, width: Int, height: Int) throws -> [UInt8] {
        let renderer = try makeRenderer(width: width, height: height)
        let replay = ShotReplay(
            file: look, take: take, capturedFrames: capturedFrames,
            framesPerSecond: capturedRate)
        let shot = try prepare(renderer, at: Double(frame), replay: replay)
        return renderer.render(camera: shot.camera)
    }

    private func makeRenderer(width: Int, height: Int) throws -> Renderer {
        let renderer = try Renderer(
            device: device, particles: take.particles,
            settings: look.renderSettings(width: width, height: height),
            externalPositions: positions)
        renderer.setSmoothing(smoothing.buffer)
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
        let shot = replay.shot(atCaptured: position)
        renderer.prepare(look, shot: shot, take: take, at: blend)
        return shot
    }
}
