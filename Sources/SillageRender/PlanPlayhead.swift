import SillageCore
#if canImport(simd)
    import simd
#else
    import Foundation
#endif

/// The shot a look file's plan gives a take at any playhead, for a canvas that scrubs back and
/// forth (#177): the export's own `ShotReplay` at the rate the take was captured, started again
/// from the first frame when the playhead goes back or the file changes. The auto camera eases
/// and the immersed director moves on, so no frame can be placed without the ones before it;
/// replaying them costs microseconds a frame. What would cost more is measured once: the
/// first frame's radii a plan frames, and the director's `ShotPlan`, which takes another
/// camera plan or lens without reading the take again.
public final class PlanPlayhead {
    public let take: RecordingFile.Loaded
    /// The rate the take was captured at, which the director's clock runs on.
    public let capturedRate: Int
    private let radii: [Float]
    private var directed: ShotPlan?
    private var replay: ShotReplay?
    private var drawn: (file: LookFile, aspect: Float)?
    private var last: (position: Double, shot: ShotReplay.Shot)?

    /// `radii` from `firstFrameRadii(of:)` and `directed` from `ShotPlan(take:file:framesPerSecond:)`
    /// at `capturedRate`, when they were made elsewhere.
    public init(
        take: RecordingFile.Loaded, capturedRate: Int, radii: [Float]? = nil,
        directed: ShotPlan? = nil
    ) {
        self.take = take
        self.capturedRate = max(capturedRate, 1)
        self.radii = radii ?? Self.firstFrameRadii(of: take)
        self.directed = directed
    }

    /// What a take read back from its file is measured on: the drawn particles of its first
    /// frame.
    public static func firstFrameRadii(of take: RecordingFile.Loaded) -> [Float] {
        take.recording.positions(at: 0).map { simd_length($0) }.sorted()
    }

    /// The shot the export draws `file` through at a captured position, fractional or not, in
    /// frames `aspect` times as wide as they are high.
    public func shot(_ file: LookFile, atCaptured position: Double, aspect: Float) -> ShotReplay.Shot {
        let same = drawn.map { $0.file == file && $0.aspect == aspect } ?? false
        if same, let last, last.position == position { return last.shot }
        if !same || replay == nil || position < (last?.position ?? 0) {
            var plan: ShotPlan?
            if file.camera.mode == .director {
                let made = directed ?? ShotPlan(take: take, file: file, framesPerSecond: capturedRate)
                directed = made
                plan = made.replanned(camera: file.camera, fieldOfView: file.look.fieldOfView)
            }
            replay = ShotReplay(
                file: file, take: take, capturedFrames: take.recording.capturedFrames,
                framesPerSecond: capturedRate, aspect: aspect, plan: plan,
                radius: file.camera.framedRadius(sortedRadii: radii))
            drawn = (file, aspect)
        }
        let shot = replay!.shot(atCaptured: position)
        last = (position, shot)
        return shot
    }
}
