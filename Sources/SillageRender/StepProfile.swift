import Foundation

/// Where a solver step spends its time, summed over the steps since it was last taken.
///
/// CPU phases are wall time on the stepping thread. GPU passes are the command buffer's own
/// clock, which only means something when each pass is submitted alone, so profiling a
/// solver also splits its submissions.
public struct StepProfile: Sendable {
    /// In the order a step runs them. The tree phases are the ones `BarnesHutTree` times.
    public static let phases = [
        "tree wait", "star formation", "drift", "halo centres", "disk frames",
        "bounds", "morton", "sort", "nodes", "accumulate", "quadrupoles", "upload",
        "force", "kick", "dissipation", "step",
    ]

    public var steps = 0
    public var treeBuilds = 0
    public var milliseconds: [String: Double] = [:]

    public init() {}

    /// Mean over every step, so phases that only run on a rebuild are diluted by reuse.
    public func perStep(_ phase: String) -> Double {
        steps > 0 ? (milliseconds[phase] ?? 0) / Double(steps) : 0
    }

    mutating func add(_ phase: String, _ value: Double) {
        milliseconds[phase, default: 0] += value
    }
}

/// Shared between the stepping thread, the tree queue and whoever reads it.
final class StepProfiler: @unchecked Sendable {
    private let lock = NSLock()
    private var profile = StepProfile()

    func update(_ change: (inout StepProfile) -> Void) {
        lock.lock()
        change(&profile)
        lock.unlock()
    }

    func take() -> StepProfile {
        lock.lock()
        defer {
            profile = StepProfile()
            lock.unlock()
        }
        return profile
    }
}
