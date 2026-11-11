import Foundation
import SillageCore

/// One pass of a Barnes-Hut step, which an engine runs with its own kernels (#274). Exhaustive:
/// an engine switches over it without a `default`, so a pass added here for Metal stops the
/// CUDA module compiling until it runs it too.
public enum BarnesHutPass {
    /// Gas into stars over the leaves of the tree (`bhFormStars`).
    case starFormation
    /// The light tracers' gas, at the chances the massive pass just wrote (`bhTracerFormStars`).
    case tracerStarFormation
    /// The massive particles' half kick and drift, and the tracers' drift.
    case drift
    /// The particles into the tree's order, when a tree is used again (`bhGather`).
    case gather
    /// One dispatch of the force pass over these Morton slots (`bhAcceleration`).
    case accelerations(Range<Int>)
    /// The black holes' pull on everything and everything's on them.
    case holes
    /// The closing half kick (`bhKick`).
    case kick
    /// The disks cooled towards `disks`; nothing when nil (`bhDissipate`).
    case dissipation([DiskCoolingGPU]?)
    /// One dispatch of the tracers' fused pass over these slots of their walk order.
    case tracerStep(mode: UInt32, pieces: Range<Int>, disks: [DiskCoolingGPU]?)
}

/// CPU work a tree build leaves room for, with the phase it is timed as while profiling.
public struct BarnesHutWork {
    public let phase: String
    public let run: () -> Void
}

/// What an engine gives a step (#274): Metal's kernels in command buffers, or CUDA's launches.
/// The order of the passes is `BarnesHutStep`'s; an engine only runs each.
public protocol BarnesHutPasses: AnyObject {
    /// Submits each pass on its own and times it.
    var profiling: Bool { get }
    /// The massive particles' positions and velocities where the CPU reads them, as the last
    /// drift left them once a build is under way.
    var massivePositions: UnsafeBufferPointer<SIMD3<Float>> { get }
    var massiveVelocities: UnsafeBufferPointer<SIMD3<Float>> { get }

    /// Runs `passes` in order as one submission and waits for it.
    func run(_ passes: [BarnesHutPass])
    /// The same, timed as `phase` of the step's profile.
    func profile(_ phase: String, _ passes: [BarnesHutPass])
    /// Builds the tree from the positions, gathers the particles for the force pass on the way,
    /// and sorts the tracers' walk order after it when asked. `work` runs on the CPU while the
    /// tree builds. `profiled` is false for a build that is not a step's.
    func buildTree(sortingTracers: Bool, meanwhile work: [BarnesHutWork], profiled: Bool)
    /// A profiled step ended.
    func stepped(milliseconds: Double)
}

/// A Barnes-Hut step, in the order both engines run it (#274): formation, drift, the tree build
/// with the CPU work it leaves room for, the cooling disks, the forces a piece at a time, the
/// holes, the kick, the dissipation, then the tracers. Moved out of `MetalBarnesHutSolver`.
public enum BarnesHutStep {
    public static func run(_ host: BarnesHutHost, on engine: some BarnesHutPasses, steps: Int) {
        for _ in 0..<max(steps, 0) {
            let stepClock = Date()
            var clock = Date()
            // Star formation goes first, before the drift, and that is not a detail.
            //
            // It reads a velocity *gradient* across a single leaf — sixteen particles — and
            // one step of drift is enough to blur that below the threshold a shock has to
            // clear. Run on a stale tree, it lost two thirds of the rate and the whole merger
            // burst with it: the windows went from 213, 261, 536, 199, 456, 727 to 107, 84,
            // 110, 68, 46, 42. Here the tree was built from exactly these positions.
            if engine.profiling {
                engine.profile("star formation", [.starFormation])
                if host.tracerCount > 0 {
                    engine.profile("tracer formation", [.tracerStarFormation])
                }
                engine.profile("drift", [.drift])
            } else {
                engine.run([.starFormation, .tracerStarFormation, .drift])
            }
            host.lastDriftMilliseconds = Date().timeIntervalSince(clock) * 1000
            clock = Date()
            if host.stepsSinceTree <= 0 {
                rebuildTree(host, on: engine)
                host.stepsSinceTree = max(BarnesHutHost.treeReuse, 1)
            }
            host.stepsSinceTree -= 1
            host.stepsSinceTracerSort -= 1
            host.tracerOrderAge += 1
            host.lastTreeMilliseconds = Date().timeIntervalSince(clock) * 1000
            clock = Date()
            let disks = host.coolingDisks()
            host.lastCoolingDisks = disks
            if engine.profiling {
                engine.profile("force", forces(host))
                if !host.holes.isEmpty { engine.profile("black holes", [.holes]) }
                engine.profile("kick", [.kick])
                engine.profile("dissipation", [.dissipation(disks)])
                if host.tracerCount > 0 {
                    engine.profile("tracer force", tracerSteps(host, mode: 1, disks: disks))
                }
            } else {
                submitForces(host, on: engine, disks: disks)
            }
            host.lastForceMilliseconds = Date().timeIntervalSince(clock) * 1000
            host.time += host.scene.timeStep
            if engine.profiling {
                engine.stepped(milliseconds: Date().timeIntervalSince(stepClock) * 1000)
            }
        }
    }

    /// What a new solver starts from: the first half kick needs an acceleration, so the tree and
    /// the forces are worked out before any step. A tracer keeps none, so it takes its first
    /// half kick now, unless a checkpoint brings it.
    public static func seed(
        _ host: BarnesHutHost, on engine: some BarnesHutPasses, tracersAwaitCheckpoint: Bool
    ) {
        rebuildTree(host, on: engine)
        engine.run(
            forces(host) + [.holes]
                + (tracersAwaitCheckpoint ? [] : tracerSteps(host, mode: 0, disks: nil)))
    }

    /// What a solver restored from a checkpoint starts from, once its buffers are read back and
    /// its counters taken: the tree without the centres and disk frames a rebuild moves on, and
    /// the accelerations the next step's first half kick reads, as the last step left them. The
    /// tracers' walk order only decides how fast they walk, so it is sorted afresh. A tracer
    /// keeps no acceleration: its saved velocity is half a kick ahead already.
    public static func restored(_ host: BarnesHutHost, on engine: some BarnesHutPasses) {
        let sortTracers = host.tracerCount > 0
        engine.buildTree(sortingTracers: sortTracers, meanwhile: [], profiled: false)
        host.gathered = true
        if sortTracers {
            host.stepsSinceTracerSort = max(BarnesHutHost.tracerSortInterval, 1)
            host.tracerOrderAge = 0
        }
        engine.run(forces(host) + [.holes])
    }

    /// Builds the tree from the drifted positions, with the halo centres and the disk frames
    /// that go with it: they read the positions the build is reading, so they are taken
    /// meanwhile.
    static func rebuildTree(_ host: BarnesHutHost, on engine: some BarnesHutPasses) {
        let sortTracers = host.tracerCount > 0 && host.stepsSinceTracerSort <= 0
        if sortTracers {
            host.stepsSinceTracerSort = max(BarnesHutHost.tracerSortInterval, 1)
            host.tracerOrderAge = 0
        }
        var work = [
            BarnesHutWork(phase: "halo centres") {
                host.updateHaloCenters(
                    positions: engine.massivePositions,
                    velocities: host.dissipates ? engine.massiveVelocities : nil)
            }
        ]
        if host.dissipates {
            work.append(
                BarnesHutWork(phase: "disk frames") {
                    host.updateDiskFrames(
                        positions: engine.massivePositions, velocities: engine.massiveVelocities)
                })
        }
        engine.buildTree(sortingTracers: sortTracers, meanwhile: work, profiled: true)
        host.gathered = true
    }

    /// The force pass over `pieces` of the Morton slots, all of them when nil, a dispatch for
    /// each `forceChunk` of them. A reused tree still needs this step's positions in its order.
    static func forces(_ host: BarnesHutHost, pieces: Range<Int>? = nil) -> [BarnesHutPass] {
        var passes: [BarnesHutPass] = []
        if !host.gathered {
            passes.append(.gather)
            host.gathered = true
        }
        let slots = pieces ?? 0..<host.massive
        if slots.upperBound >= host.massive { host.gathered = false }
        var start = slots.lowerBound
        while start < slots.upperBound {
            let span = min(max(BarnesHutHost.forceChunk, 1), slots.upperBound - start)
            passes.append(.accelerations(start..<start + span))
            start += span
        }
        return passes
    }

    /// The tracers' fused pass over `pieces` of their walk order, all of it when nil (#238).
    /// `mode` 0 takes the first half kick, 1 closes this step and opens the next.
    static func tracerSteps(
        _ host: BarnesHutHost, mode: UInt32, pieces: Range<Int>? = nil, disks: [DiskCoolingGPU]?
    ) -> [BarnesHutPass] {
        guard host.tracerCount > 0 else { return [] }
        var passes: [BarnesHutPass] = []
        let slots = pieces ?? 0..<host.tracerCount
        var start = slots.lowerBound
        while start < slots.upperBound {
            let span = min(max(BarnesHutHost.forceChunk, 1), slots.upperBound - start)
            passes.append(.tracerStep(mode: mode, pieces: start..<start + span, disks: disks))
            start += span
        }
        return passes
    }

    /// The force pass, one submission a piece, with the holes, the kick and the cooling in the
    /// last massive one. The tracers' pieces follow: they move nothing the massive pass reads.
    ///
    /// A frame queued behind the solver waits for the whole command buffer, not for the next
    /// piece encoded in it. The CPU build used to be the gap frames got in through; without it
    /// one buffer for the whole pass halved the live frame rate, 13 to 15 a second down to 8
    /// at two million visible particles. In pieces it was 17.5, and with nothing drawn the
    /// pieces cost nothing (#38).
    static func submitForces(
        _ host: BarnesHutHost, on engine: some BarnesHutPasses, disks: [DiskCoolingGPU]?
    ) {
        let chunk = max(BarnesHutHost.forceChunk, 1)
        for start in stride(from: 0, to: host.massive, by: chunk) {
            let upper = min(start + chunk, host.massive)
            var passes = forces(host, pieces: start..<upper)
            if upper == host.massive {
                passes += [.holes, .kick, .dissipation(disks)]
            }
            engine.run(passes)
        }
        for start in stride(from: 0, to: host.tracerCount, by: chunk) {
            engine.run(
                tracerSteps(
                    host, mode: 1, pieces: start..<min(start + chunk, host.tracerCount),
                    disks: disks))
        }
    }
}
