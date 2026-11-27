import Foundation
import SillageCore

/// The frames of a take's video without a flight (#429), worked out apart from the engine that
/// draws them: the moment each frame shows along the time track (#305, #309), the camera the
/// look's plan gives it, the look, the time and the painted arms there, and the exposure of a look
/// that measures its own over the video (#340). What `TakeExport.write` does for Metal when it
/// has no flight, in the same order, so that an engine that draws through it draws the frames the
/// Mac's `export` draws. A flight's frames are `FlightFrames`'.
public final class TakeFrames {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case trackForAnotherTake(track: Int, take: Int)
        case heldWithoutFlight(String)

        public var description: String {
            switch self {
            case .trackForAnotherTake(let track, let take):
                "a time track of \(track) captured frames for a take of \(take)"
            case .heldWithoutFlight(let held):
                "the take holds only \(held) of its framing take's run: it is drawn along a flight (--flight)"
            }
        }
    }

    public let take: RecordingFile.Loaded
    /// Where the camera, the painted arms, the time and the exposure are read: `take` itself, or
    /// another take of the same run with the same frames (#239).
    public let framing: RecordingFile.Loaded
    public let look: LookFile
    public let capturedRate: Int
    public let width: Int
    public let height: Int
    public let track: TimeTrack
    public let replay: ShotReplay

    public init(
        take: RecordingFile.Loaded, look: LookFile, capturedRate: Int, width: Int, height: Int,
        framing: RecordingFile.Loaded? = nil, track: TimeTrack? = nil
    ) throws {
        let framed = framing ?? take
        if framed.recording !== take.recording,
            framed.recording.capturedFrames != take.recording.capturedFrames
        {
            let held = try HeldFrames(
                times: take.recording.frames.map { Double($0.time) * Physics.megayearsPerTimeUnit },
                megayears: TimeTrack.megayears(of: framed.recording), interval: framed.recording.interval)
            throw Failure.heldWithoutFlight(held.description)
        }
        let rate = max(capturedRate, 1)
        let frames = take.recording.capturedFrames
        if let track, track.capturedFrames != frames || track.capturedRate != rate {
            throw Failure.trackForAnotherTake(track: track.capturedFrames, take: frames)
        }
        let played = try track ?? TimeTrack(capturedFrames: frames, capturedRate: rate)
        self.take = take
        self.framing = framed
        self.look = look
        self.capturedRate = rate
        self.width = width
        self.height = height
        self.track = played
        replay = TakeFraming.replay(
            look: look, framing: framed, capturedRate: rate, width: width, height: height, track: played)
    }

    /// Every frame a video at `framesPerSecond` shows from `start` for `duration` seconds of
    /// video, cut at the end of the take.
    public func videoFrames(framesPerSecond: Int, start: Double = 0, duration: Double? = nil)
        -> [TimeTrack.Frame]
    {
        track.frames(framesPerSecond: framesPerSecond, start: start, duration: duration)
    }

    /// The seconds of the whole video along the track.
    public var videoSeconds: Double { track.seconds }

    /// Sets `stage` on a frame: the positions of its moment with their kernel lengths, and the
    /// camera, the look, the time and the painted arms there, under `exposure` when the look
    /// measures its own.
    public func prepare(on stage: some FrameStage, at frame: TimeTrack.Frame, exposure: ExposureScale?)
        throws -> ShotReplay.Shot
    {
        _ = try stage.stage(FlightFrames.Place(captured: frame.captured), eased: false)
        stage.inside = nil
        stage.skyTurn = .zero
        let styling = stage.styling
        guard
            let shot = TakeFraming.prepare(styling, look: look, replay: replay, framing: framing, at: frame)
        else { throw RecordingFile.Failure.truncated }
        if let exposure { styling.apply(exposure.applied(to: shot.look)) }
        return shot
    }

    /// One exposure for `frames`, the frames of the video drawn, measured on a few of them, for a
    /// look that takes its exposure from the frames (#340). Nil when the look keeps its own.
    public func measureScale(on stage: some FrameStage, frames: [TimeTrack.Frame]) throws -> ClipExposure? {
        guard let target = look.exposure, !frames.isEmpty else { return nil }
        stage.setGrain(frame: 0)
        var samples: [ClipExposure.Sample] = []
        for index in ClipExposure.samples(of: frames.count) {
            let shot = try prepare(on: stage, at: frames[index], exposure: nil)
            let solved = try ExposureSolver.solve(
                target: target, stretches: shot.look.stretch > 0,
                draw: { scale in
                    stage.styling.apply(scale.applied(to: shot.look))
                    return ExposureMeter.read(
                        rgba: try stage.measure(camera: shot.camera), width: width, height: height)
                })
            if let solved { samples.append(.init(captured: frames[index].captured, solution: solved)) }
        }
        guard !samples.isEmpty else { return nil }
        return ClipExposure(scale: ExposureSolver.held(samples.map(\.solution)), samples: samples)
    }
}
