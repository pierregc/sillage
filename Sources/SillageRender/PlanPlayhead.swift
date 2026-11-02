import SillageCore
import simd

/// The shot a look file's plan gives a take at any playhead, for a canvas that scrubs back and
/// forth (#177): the export's own `ShotReplay` at the rate the take was captured, started again
/// from the first frame when the playhead goes back or the file changes. The auto camera eases
/// and the director moves on, so no frame can be placed without the ones before it; replaying
/// them costs microseconds a frame, and the radius a plan measures comes from the first frame's
/// radii, sorted once rather than on every edit.
public final class PlanPlayhead {
    public let take: RecordingFile.Loaded
    /// The rate the take was captured at, which the director's clock runs on.
    public let capturedRate: Int
    private let radii: [Float]
    private var replay: ShotReplay?
    private var file: LookFile?
    private var last: (position: Double, shot: ShotReplay.Shot)?

    /// `radii` from `firstFrameRadii(of:)`, when they were sorted elsewhere.
    public init(take: RecordingFile.Loaded, capturedRate: Int, radii: [Float]? = nil) {
        self.take = take
        self.capturedRate = max(capturedRate, 1)
        self.radii = radii ?? Self.firstFrameRadii(of: take)
    }

    /// What a take read back from its file is measured on: the drawn particles of its first
    /// frame.
    public static func firstFrameRadii(of take: RecordingFile.Loaded) -> [Float] {
        take.recording.positions(at: 0).map { simd_length($0) }.sorted()
    }

    /// The shot the export draws `file` through at a captured position, fractional or not.
    public func shot(_ file: LookFile, atCaptured position: Double) -> ShotReplay.Shot {
        if file == self.file, let last, last.position == position { return last.shot }
        if file != self.file || replay == nil || position < (last?.position ?? 0) {
            replay = ShotReplay(
                file: file, take: take, capturedFrames: take.recording.capturedFrames,
                framesPerSecond: capturedRate, radius: file.camera.framedRadius(sortedRadii: radii))
            self.file = file
        }
        let shot = replay!.shot(atCaptured: position)
        last = (position, shot)
        return shot
    }
}
