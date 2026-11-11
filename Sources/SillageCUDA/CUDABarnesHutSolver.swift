internal import CSillageCUDA
import Foundation
import SillageCore
import SillageRender

/// `MetalBarnesHutSolver` without its light tracers, on CUDA (#274): the massive particles of a
/// scene stepped as the Mac steps them, with the halos, the black holes, star formation, the
/// cooling disks and dissipation, saved and resumed to the bit. The light tracers are #275's.
///
/// Nothing of the solver is written twice. The kernels are the shared MSL of
/// `BarnesHutShaders`, launched a pass at a time through `sillage_cuda_solver.h`; the step is
/// `BarnesHutStep` and the CPU work around it `BarnesHutHost`, the ones Metal runs. This class
/// only holds the buffers and runs each pass.
///
/// Deterministic: no float atomic feeds the motion, the black holes' reactions are summed a
/// block at a time and the blocks in a fixed order, and nothing is built with fast math, so two
/// runs give the same bits, and so does a run resumed from a checkpoint.
public final class CUDABarnesHutSolver: Solver {
    public let kind: SolverKind = .barnesHut
    public var scene: SceneConfig { host.scene }
    public var time: Float { host.time }
    public let context: CUDAContext
    /// The solver's CPU side, the one `MetalBarnesHutSolver` runs: its counters, centres, disk
    /// frames, parameters and checkpoint state.
    public let host: BarnesHutHost

    /// Times every phase of a step into `takeProfile()`, waiting for the device after each pass.
    public var profiling = false
    private let profiler = StepProfiler()
    /// Read back once each build has run.
    public private(set) var nodeCount = 0
    /// What the first call that failed left behind. A pass cannot throw through the shared step,
    /// so the solver keeps the error and runs nothing after it: read it, or step with
    /// `advance(steps:)`, which throws it.
    public private(set) var failure: CUDAError?

    /// Every particle's position and velocity, a `float3` each in 16 bytes, laid out
    /// `[massive visible | massive halo]`; the light tracers will come before them (#275).
    public let positions: CUDABuffer
    public let velocities: CUDABuffer
    /// When each massive particle's stars formed.
    public let formation: CUDABuffer
    private let accelerationBuffer: CUDABuffer
    private let massBuffer: CUDABuffer
    /// Position and mass by Morton slot, which the tree build gathers.
    private let sortedBuffer: CUDABuffer
    private let costBuffer: CUDABuffer
    private let componentBuffer: CUDABuffer
    private let galaxyBuffer: CUDABuffer?
    private let builder: CUDATreeBuilder
    private let handle: OpaquePointer
    /// The massive positions and velocities in pinned host memory, where the shared CPU work
    /// reads them while the tree builds.
    private let hostPositions: CUDAHostMemory
    private let hostVelocities: CUDAHostMemory
    public let quadrupole: Bool
    public let opensHoldingCells: Bool

    public var centers: [SIMD3<Float>] { host.centers }
    public var diskFrames: [DiskState] { host.diskFrames }
    public var openingAngle: Float {
        get { host.openingAngle }
        set { host.openingAngle = newValue }
    }
    public var softening: Float {
        get { host.softening }
        set { host.softening = newValue }
    }

    /// What the steps since the last call cost, phase by phase.
    public func takeProfile() -> StepProfile { profiler.take() }

    private var massive: Int { host.massive }

    /// Over the particles the scene samples here. A run compared with Metal reads the Mac's
    /// instead: a sample drawn on Linux is the Mac's to rounding, not to the bit (#272).
    public convenience init(context: CUDAContext, scene: SceneConfig) throws {
        try self.init(
            context: context, scene: scene, massive: RestrictedSolver.sampleParticles(for: scene))
    }

    /// Over `massive`, laid out `[visible | halo]`, as `MetalBarnesHutSolver` takes them.
    public init(
        context: CUDAContext, scene: SceneConfig, massive particles: ParticleSystem,
        quadrupole: Bool = BarnesHutHost.quadrupole, opensHoldingCells: Bool = true
    ) throws {
        self.context = context
        let host = BarnesHutHost(scene: scene, massive: particles, tracers: 0)
        self.host = host
        self.quadrupole = quadrupole
        self.opensHoldingCells = opensHoldingCells
        let massive = host.massive

        positions = try context.makeBuffer(length: massive * 16)
        velocities = try context.makeBuffer(length: massive * 16)
        accelerationBuffer = try context.makeBuffer(length: massive * 16)
        massBuffer = try context.makeBuffer(host.treeMass)
        sortedBuffer = try context.makeBuffer(length: massive * 16)
        costBuffer = try context.makeBuffer(length: massive * 4)
        formation = try context.makeBuffer(
            particles.formation.count == massive
                ? particles.formation : [Float](repeating: ParticleSystem.ancient, count: massive))
        func attribute(_ values: [UInt32], _ fallback: UInt32) -> [UInt32] {
            values.count == massive ? values : [UInt32](repeating: fallback, count: massive)
        }
        // Star formation needs to know what a particle is; dissipation also needs whose it is.
        componentBuffer = try context.makeBuffer(attribute(particles.component, 0))
        galaxyBuffer = host.dissipates ? try context.makeBuffer(attribute(particles.galaxyIndex, 0)) : nil
        if !particles.positions.isEmpty {
            try positions.upload(particles.positions)
            try velocities.upload(particles.velocities)
        }
        hostPositions = try CUDAHostMemory(context: context, length: massive * 16)
        hostVelocities = try CUDAHostMemory(context: context, length: massive * 16)
        builder = try CUDATreeBuilder(
            context: context, count: massive, leafCapacity: BarnesHutHost.leafCapacity,
            maximumDepth: BarnesHutHost.maximumTreeDepth, quadrupole: quadrupole,
            nodeCapacity: massive / 2 + 1024)

        var config = sc_solver_config(
            massive: UInt32(massive), first: 0, quadrupole: quadrupole ? 1 : 0,
            opens_holding_cells: opensHoldingCells ? 1 : 0, leaf_chances: 0)
        var buffers = sc_solver_buffers(
            positions: positions.handle, velocities: velocities.handle,
            accelerations: accelerationBuffer.handle, mass: massBuffer.handle,
            sorted: sortedBuffer.handle, formation: formation.handle,
            component: componentBuffer.handle, galaxy: galaxyBuffer?.handle,
            cost: costBuffer.handle, slot_chances: nil)
        var made: OpaquePointer?
        try check(
            sc_solver_create(context.handle, &config, &buffers, &made),
            "a solver of \(massive) massive particles")
        guard let made else { throw CUDAError(.unknown, "no solver") }
        handle = made

        BarnesHutStep.seed(host, on: self, tracersAwaitCheckpoint: false)
        if let failure { throw failure }
    }

    deinit { sc_solver_destroy(handle) }

    public func step() { step(count: 1) }

    public func step(count steps: Int) {
        guard failure == nil else { return }
        BarnesHutStep.run(host, on: self, steps: steps)
    }

    /// Steps, and throws what a pass left behind.
    public func advance(steps: Int = 1) throws {
        step(count: steps)
        if let failure { throw failure }
    }

    /// Every massive particle as it stands. Downloaded on every access.
    public var particles: ParticleSystem {
        var system = host.template
        system.positions = (try? positions.download(SIMD3<Float>.self, count: massive)) ?? []
        system.velocities = (try? velocities.download(SIMD3<Float>.self, count: massive)) ?? []
        system.formation = (try? formation.download(Float.self, count: massive)) ?? []
        return system
    }

    /// Total momentum, as `MetalBarnesHutSolver.momentum()` sums it.
    public func momentum() throws -> SIMD3<Float> {
        let moving = try velocities.download(SIMD3<Float>.self, count: massive)
        return moving.withUnsafeBufferPointer { host.momentum(velocities: $0) }
    }

    /// The accelerations the last force pass left, for validation against direct summation.
    public var accelerations: [SIMD3<Float>] {
        get throws { try accelerationBuffer.download(SIMD3<Float>.self, count: massive) }
    }

    /// What each traversal cost, in node evaluations, by Morton slot.
    public var traversalCosts: [UInt32] {
        get throws { try costBuffer.download(UInt32.self, count: massive) }
    }

    /// Writes the smoothing lengths of the first `drawn` massive particles from the live tree,
    /// so the renderer needs no tree of its own. False before there is a tree.
    public func writeSmoothing(into lengths: CUDABuffer, drawn: Int) throws -> Bool {
        guard nodeCount > 0 else { return false }
        try builder.buildSmoothing(into: lengths, drawn: drawn)
        return true
    }

    private func attempt(_ work: () throws -> Void) {
        guard failure == nil else { return }
        do { try work() } catch let error as CUDAError {
            failure = error
        } catch {
            failure = CUDAError(.unknown, "\(error)")
        }
    }

    private func timed(_ phase: String, _ work: () throws -> Void) rethrows {
        let clock = Date()
        try work()
        let spent = Date().timeIntervalSince(clock) * 1000
        profiler.update { $0.add(phase, spent) }
    }

    /// True when the build ran out of nodes, once there is room for it to run again.
    private func grewAfterOverflow() throws -> Bool {
        guard try builder.overflowed else { return false }
        try builder.grow()
        return true
    }
}

// MARK: - The step's passes

extension CUDABarnesHutSolver: BarnesHutPasses {
    public var massivePositions: UnsafeBufferPointer<SIMD3<Float>> {
        UnsafeBufferPointer(
            start: hostPositions.bytes.baseAddress?.assumingMemoryBound(to: SIMD3<Float>.self),
            count: massive)
    }

    public var massiveVelocities: UnsafeBufferPointer<SIMD3<Float>> {
        UnsafeBufferPointer(
            start: hostVelocities.bytes.baseAddress?.assumingMemoryBound(to: SIMD3<Float>.self),
            count: massive)
    }

    /// The launches of `passes`, queued in order on the device's stream.
    public func run(_ passes: [BarnesHutPass]) {
        attempt {
            for pass in passes { try launch(pass) }
        }
    }

    public func profile(_ phase: String, _ passes: [BarnesHutPass]) {
        attempt {
            try context.synchronize()
            try timed(phase) {
                for pass in passes { try launch(pass) }
                try context.synchronize()
            }
        }
    }

    /// Builds the tree from the positions and gathers the particles for the force pass on the
    /// way. The shared CPU work reads the positions from pinned host memory, copied once the
    /// drift has landed, and runs while the device builds the tree. On the CPU target the tree
    /// is the CPU's own, laid out by `sc_tree_upload`.
    public func buildTree(sortingTracers: Bool, meanwhile work: [BarnesHutWork], profiled: Bool) {
        attempt {
            if !work.isEmpty {
                try positions.download(into: hostPositions.bytes)
                if host.dissipates { try velocities.download(into: hostVelocities.bytes) }
            }
            if profiling, profiled {
                for item in work { timed(item.phase, item.run) }
                repeat {
                    if CUDAContext.target == .gpu {
                        for phase in CUDATreeBuilder.Phase.allCases {
                            try timed(phase.rawValue) {
                                try builder.build(
                                    phase, positions: positions, mass: massBuffer, sorted: sortedBuffer)
                                try context.synchronize()
                            }
                        }
                    } else {
                        try timed(CUDATreeBuilder.Phase.nodes.rawValue) {
                            try builder.build(positions: positions, mass: massBuffer, sorted: sortedBuffer)
                        }
                    }
                } while try grewAfterOverflow()
                profiler.update { $0.treeBuilds += 1 }
            } else {
                try builder.build(positions: positions, mass: massBuffer, sorted: sortedBuffer)
                for item in work { item.run() }
                while try grewAfterOverflow() {
                    try builder.build(positions: positions, mass: massBuffer, sorted: sortedBuffer)
                }
            }
            nodeCount = try builder.nodeCount
        }
    }

    public func stepped(milliseconds: Double) {
        profiler.update {
            $0.steps += 1
            $0.add("step", milliseconds)
        }
    }

    private func launch(_ pass: BarnesHutPass) throws {
        let stride = MemoryLayout<BHParams>.stride
        switch pass {
        case .starFormation:
            guard var formation = host.drawFormation(nodeCount: nodeCount) else { return }
            try check(
                sc_solver_form_stars(
                    handle, builder.handle, &formation, MemoryLayout<StarFormationGPU>.stride),
                "star formation")
        case .drift:
            var p = host.params
            try check(sc_solver_kick_drift(handle, &p, stride), "the drift")
        case .gather:
            var p = host.params
            try check(sc_solver_gather(handle, builder.handle, &p, stride), "the gather")
        case .accelerations(let pieces):
            var p = host.params
            p.chunkStart = UInt32(pieces.lowerBound)
            let list = host.haloList
            try check(
                sc_solver_accelerations(
                    handle, builder.handle, &p, stride, UInt32(pieces.count), list, UInt32(list.count)),
                "the force pass over \(pieces)")
        case .holes:
            let holes = host.holes
            guard !holes.isEmpty else { return }
            var p = host.params
            let list = host.haloList
            try check(
                sc_solver_holes(
                    handle, &p, stride, holes, UInt32(holes.count), list, UInt32(list.count)),
                "the black holes")
        case .kick:
            var p = host.params
            try check(sc_solver_kick(handle, &p, stride), "the kick")
        case .dissipation(let disks):
            guard let disks, galaxyBuffer != nil else { return }
            var p = host.params
            try check(
                sc_solver_dissipate(handle, &p, stride, disks, UInt32(disks.count)), "the dissipation")
        case .tracerStarFormation, .tracerStep:
            // The light tracers are #275's: this solver holds none, and the step asks for
            // their passes only when there are some.
            break
        }
    }
}

// MARK: - Checkpoint

extension CUDABarnesHutSolver {
    public var state: SolverState { host.state }

    /// The bytes `writeParticles` writes.
    public var particleBytes: Int { host.count * 32 + massive * 4 }

    /// What changes of each particle, as `MetalBarnesHutSolver` writes it (#240): every position
    /// and velocity as the buffers hold them, then the massive particles' formation times.
    private var changing: [(buffer: CUDABuffer, length: Int)] {
        [(positions, host.count * 16), (velocities, host.count * 16), (formation, massive * 4)]
    }

    /// The files of the Metal solver's checkpoint, downloaded and written 256 MB at a time.
    public func writeParticles(to handle: FileHandle) throws {
        let longest = changing.map(\.length).max() ?? 0
        let staging = try CUDAHostMemory(context: context, length: min(longest, 256 << 20))
        for (buffer, length) in changing {
            var done = 0
            while done < length {
                let piece = min(length - done, staging.bytes.count)
                let bytes = UnsafeMutableRawBufferPointer(rebasing: staging.bytes[0..<piece])
                try buffer.download(into: bytes, from: done)
                try RunCheckpoint.write(bytes.baseAddress!, piece, to: handle)
                done += piece
            }
        }
    }

    /// Puts the run back where a checkpoint of it left it: its buffers read back, its counters,
    /// centres and disks set, and the tree and the accelerations the next step starts from
    /// built again from the positions, as the last step built them. Exact with one tree a step.
    public func restore(_ state: SolverState, from handle: FileHandle) throws {
        if let failure { throw failure }
        try host.accepts(state)
        for (buffer, length) in changing {
            var read = 0
            while read < length {
                let piece = min(length - read, 256 << 20)
                guard let data = try handle.read(upToCount: piece), data.count == piece else {
                    throw RunCheckpointError.truncated
                }
                try data.withUnsafeBytes { try buffer.upload($0, at: read) }
                read += piece
            }
        }
        host.take(state)
        BarnesHutStep.restored(host, on: self)
        if let failure { throw failure }
    }
}

// MARK: - The solver check

extension CUDABarnesHutSolver: CheckedSolver {
    public func forces() throws -> [SIMD3<Float>] { try accelerations }

    public func stepChecked() throws { try advance(steps: 1) }
}
