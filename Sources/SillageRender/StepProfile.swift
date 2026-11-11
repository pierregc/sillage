import Foundation

/// Where a solver step spends its time, summed over the steps since it was last taken.
///
/// CPU phases are wall time on the stepping thread. GPU passes are the command buffer's own
/// clock, which only means something when each pass is submitted alone, so profiling a
/// solver also splits its submissions.
public struct StepProfile: Sendable {
    /// In the order a step runs them. The tree phases are those of `GPUTreeBuilder`.
    public static let phases = [
        "star formation", "tracer formation", "drift", "halo centres", "disk frames",
        "bounds", "morton", "sort", "nodes", "masses", "tracer sort",
        "force", "tracer force", "kick", "dissipation", "step",
    ]

    public var steps = 0
    public var treeBuilds = 0
    public var milliseconds: [String: Double] = [:]

    public init() {}

    /// Mean over every step, so phases that only run on a rebuild are diluted by reuse.
    public func perStep(_ phase: String) -> Double {
        steps > 0 ? (milliseconds[phase] ?? 0) / Double(steps) : 0
    }

    public mutating func add(_ phase: String, _ value: Double) {
        milliseconds[phase, default: 0] += value
    }
}

/// Shared between the stepping thread and whoever reads it.
public final class StepProfiler: @unchecked Sendable {
    private let lock = NSLock()
    private var profile = StepProfile()

    public init() {}

    public func update(_ change: (inout StepProfile) -> Void) {
        lock.lock()
        change(&profile)
        lock.unlock()
    }

    public func take() -> StepProfile {
        lock.lock()
        defer {
            profile = StepProfile()
            lock.unlock()
        }
        return profile
    }
}
