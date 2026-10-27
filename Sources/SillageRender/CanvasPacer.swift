import Foundation
import QuartzCore

/// When the canvas's frames leave the GPU free, for background work that must not cost the
/// canvas its frame rate (#114). Two queues on the GPU share it rather than take turns, so a
/// frame drawn beside a thumbnail takes four times as long; work submitted in the gap between
/// one frame finishing and the next starting costs the canvas nothing.
public final class CanvasPacer: @unchecked Sendable {
    private let condition = NSCondition()
    private var lastFinished: CFTimeInterval = 0
    private var interval: Double = 1.0 / 60
    private var cost: Double = 0

    /// Slack kept before the next frame is due.
    static let margin = 0.0015
    /// A canvas silent this long is not drawing.
    static let idle = 0.1
    /// The longest a piece of work waits for a gap before going anyway.
    static let patience = 0.05

    public init() {}

    /// A canvas frame has finished on the GPU after `gpuSeconds`.
    public func frameFinished(gpuSeconds: Double) {
        let now = CACurrentMediaTime()
        condition.lock()
        let since = now - lastFinished
        if since < Self.idle { interval = 0.8 * interval + 0.2 * min(max(since, 1.0 / 240), Self.idle) }
        cost = gpuSeconds > 0 ? 0.8 * cost + 0.2 * gpuSeconds : cost
        lastFinished = now
        condition.broadcast()
        condition.unlock()
    }

    /// Returns once `seconds` of GPU work can run before the canvas's next frame starts, or
    /// right after a frame when there is never that much room, or after `patience`.
    public func waitForGap(_ seconds: Double) {
        let start = CACurrentMediaTime()
        condition.lock()
        defer { condition.unlock() }
        var seen = lastFinished
        while true {
            let now = CACurrentMediaTime()
            if now - lastFinished > Self.idle || now - start > Self.patience { return }
            let room = interval - cost - Self.margin
            if now + seconds <= lastFinished + room { return }
            // No room in any gap: going right after a frame is the best there is.
            if seconds > room, lastFinished != seen { return }
            seen = lastFinished
            _ = condition.wait(until: Date(timeIntervalSinceNow: max(lastFinished + interval - now, 0.001)))
        }
    }
}
