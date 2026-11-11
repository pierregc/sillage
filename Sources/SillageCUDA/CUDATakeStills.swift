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

    /// `framing` is another take of the same run that gives the camera, the painted arms, the
    /// time and the exposure, as `export --framing` has it (#239).
    public init(
        context: CUDAContext, take: RecordingFile.Loaded, look: LookFile, capturedRate: Int,
        width: Int, height: Int, framing: RecordingFile.Loaded? = nil,
        laceTexels: Int = DustWeb.laceTexels
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
    public func still(
        atCaptured position: Double, frame index: Int, format: CUDAPost.Format = .rgb,
        threads: Int = 1
    ) throws -> UnsafeRawBufferPointer {
        guard let blend = take.recording.blend(atCaptured: position) else {
            throw RecordingFile.Failure.truncated
        }
        let decoded = take.recording.positions(at: blend)
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
        guard
            let shot = TakeFraming.prepare(
                renderer, look: look, replay: replay, framing: framing, at: position)
        else { throw RecordingFile.Failure.truncated }
        try renderer.upload(positions: decoded)
        try renderer.setSmoothing(lengths)
        renderer.setGrain(frame: index)
        return try renderer.picture(camera: shot.camera, format: format, threads: threads)
    }
}
