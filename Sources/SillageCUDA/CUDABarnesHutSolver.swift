internal import CSillageCUDA
import Foundation
import SillageCore
import SillageRender

/// Light tracers as the CUDA solver holds them (#275), as `LightTracerStore` holds them on Metal
/// (#238): the front of its position and velocity buffers, 16 bytes each, the formation time in
/// the w of the one and the `TracerWord` in the w of the other. Filled a chunk at a time while the
/// scene is sampled, each chunk uploaded as it comes, so the drawn count is never held on the
/// host; the massive particles go in after them.
public final class CUDALightTracerStore {
    public let positions: CUDABuffer
    public let velocities: CUDABuffer
    /// Tracers and massive particles together.
    public let capacity: Int
    public private(set) var count = 0
    /// Left for a checkpoint to fill (#240): their saved velocities carry the first half kick.
    public private(set) var awaitsCheckpoint = false

    public init(context: CUDAContext, capacity: Int) throws {
        self.capacity = max(capacity, 1)
        positions = try context.makeBuffer(length: self.capacity * 16)
        velocities = try context.makeBuffer(length: self.capacity * 16)
    }

    /// Room for `tracers` light tracers that a checkpoint fills, so a resumed run samples none.
    public convenience init(context: CUDAContext, capacity: Int, awaiting tracers: Int) throws {
        try self.init(context: context, capacity: capacity)
        count = min(max(tracers, 0), self.capacity)
        awaitsCheckpoint = true
    }

    public func append(_ chunk: LightTracerChunk) throws {
        let taken = min(chunk.count, capacity - count)
        guard taken > 0 else { return }
        try chunk.states.withUnsafeBytes {
            try positions.upload(UnsafeRawBufferPointer(rebasing: $0[0..<taken * 16]), at: count * 16)
        }
        try chunk.motions.withUnsafeBytes {
            try velocities.upload(UnsafeRawBufferPointer(rebasing: $0[0..<taken * 16]), at: count * 16)
        }
        count += taken
    }
}

/// `MetalBarnesHutSolver` on CUDA: the massive particles of a scene stepped as the Mac steps them
/// (#274), with the halos, the black holes, star formation, the cooling disks and dissipation,
/// and the light tracers in front of them, laid out and stepped as on Metal (#275), saved and
/// resumed to the bit.
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

    /// Every particle's position and velocity, 16 bytes each, laid out `[tracers | massive
    /// visible | massive halo]`: a light tracer's formation time in the w of its position and its
    /// `TracerWord` in the w of its velocity, a massive particle's a `float3`. Everything else
    /// is the massive particles' alone.
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
    /// The tracers in Morton order, so that neighbours in a warp walk alike: sorted a chunk of
    /// `sortChunk` at a time every `tracerSortInterval` steps, each chunk counted from its start.
    private let tracerOrder: CUDABuffer?
    private let tracerSorter: CUDATreeBuilder?
    /// The chance each massive gas particle had of forming stars this step, by Morton slot.
    private let slotChances: CUDABuffer?

    public var tracerCount: Int { host.tracerCount }
    public var tracerOpeningAngle: Float {
        get { host.tracerOpeningAngle }
        set { host.tracerOpeningAngle = newValue }
    }
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
    private var massiveVisible: Int { host.massiveVisible }
    private var sortChunk: Int { host.sortChunk }

    /// Over the particles the scene samples here. A run compared with Metal reads the Mac's
    /// instead: a sample drawn on Linux is the Mac's to rounding, not to the bit (#272).
    public convenience init(context: CUDAContext, scene: SceneConfig) throws {
        try self.init(
            context: context, scene: scene, massive: RestrictedSolver.sampleParticles(for: scene))
    }

    /// Over `particles` laid out `[tracers | massive visible | massive halo]`, the first
    /// `tracers` of them light tracers, packed here as `lightTracers` packs them while sampling.
    public convenience init(
        context: CUDAContext, scene: SceneConfig, particles: ParticleSystem, tracers: Int,
        quadrupole: Bool = BarnesHutHost.quadrupole, opensHoldingCells: Bool = true
    ) throws {
        let tracers = min(max(tracers, 0), max(particles.visibleCount, 0))
        var chunk = LightTracerChunk()
        for index in 0..<tracers {
            chunk.append(
                position: particles.positions[index], velocity: particles.velocities[index],
                formation: particles.formation[index],
                word: TracerWord(
                    galaxy: particles.galaxyIndex[index], component: particles.component[index],
                    kernelScale: particles.kernelScale[index],
                    luminosity: particles.luminosity[index],
                    birthRadius: particles.birthRadius[index]))
        }
        let store = tracers > 0 ? try CUDALightTracerStore(context: context, capacity: particles.count) : nil
        try store?.append(chunk)
        try self.init(
            context: context, scene: scene, massive: particles.slice(tracers..<particles.count),
            tracers: store, quadrupole: quadrupole, opensHoldingCells: opensHoldingCells)
    }

    /// Over `massive`, laid out `[visible | halo]`, as `MetalBarnesHutSolver` takes them, and
    /// the light tracers `tracers` holds in front of where it puts them.
    public init(
        context: CUDAContext, scene: SceneConfig, massive particles: ParticleSystem,
        tracers store: CUDALightTracerStore? = nil, quadrupole: Bool = BarnesHutHost.quadrupole,
        opensHoldingCells: Bool = true
    ) throws {
        self.context = context
        let tracers = store?.count ?? 0
        let host = BarnesHutHost(scene: scene, massive: particles, tracers: tracers)
        self.host = host
        self.quadrupole = quadrupole
        self.opensHoldingCells = opensHoldingCells
        let massive = host.massive
        let count = host.count
        let tracing = tracers > 0

        if let store, store.capacity < count {
            throw CUDAError(
                .invalidArgument, "light tracers' buffers hold \(store.capacity) particles, not \(count)")
        }
        positions = try store?.positions ?? context.makeBuffer(length: count * 16)
        velocities = try store?.velocities ?? context.makeBuffer(length: count * 16)
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
            try positions.upload(particles.positions, at: tracers * 16)
            try velocities.upload(particles.velocities, at: tracers * 16)
        }
        hostPositions = try CUDAHostMemory(context: context, length: massive * 16)
        hostVelocities = try CUDAHostMemory(context: context, length: massive * 16)
        builder = try CUDATreeBuilder(
            context: context, count: massive, leafCapacity: BarnesHutHost.leafCapacity,
            maximumDepth: BarnesHutHost.maximumTreeDepth, quadrupole: quadrupole,
            nodeCapacity: massive / 2 + 1024, first: tracers)
        tracerOrder = tracing ? try context.makeBuffer(length: tracers * 4) : nil
        tracerSorter =
            tracing
            ? try CUDATreeBuilder(context: context, count: host.sortChunk, nodeCapacity: 1, ownOrder: false)
            : nil
        slotChances = tracing ? try context.makeBuffer(length: massive * 4) : nil

        var config = sc_solver_config(
            massive: UInt32(massive), first: UInt32(tracers), quadrupole: quadrupole ? 1 : 0,
            opens_holding_cells: opensHoldingCells ? 1 : 0, leaf_chances: tracing ? 1 : 0)
        var buffers = sc_solver_buffers(
            positions: positions.handle, velocities: velocities.handle,
            accelerations: accelerationBuffer.handle, mass: massBuffer.handle,
            sorted: sortedBuffer.handle, formation: formation.handle,
            component: componentBuffer.handle, galaxy: galaxyBuffer?.handle,
            cost: costBuffer.handle, slot_chances: slotChances?.handle,
            tracer_order: tracerOrder?.handle)
        var made: OpaquePointer?
        try check(
            sc_solver_create(context.handle, &config, &buffers, &made),
            "a solver of \(massive) massive particles and \(tracers) light tracers")
        guard let made else { throw CUDAError(.unknown, "no solver") }
        handle = made

        BarnesHutStep.seed(host, on: self, tracersAwaitCheckpoint: store?.awaitsCheckpoint == true)
        if let failure { throw failure }
    }

    /// Samples `drawn` with `massive` carrying its mass (#187), as
    /// `MetalBarnesHutSolver.lightTracers` does: the light tracers packed while the sampler draws
    /// and uploaded a chunk at a time into the buffers a solver over the massive set steps them
    /// in, so the drawn count is never held on the host (#238).
    public static func lightTracers(
        context: CUDAContext, drawn: SceneConfig, massive: SceneConfig
    ) throws -> (tracers: CUDALightTracerStore, massive: ParticleSystem) {
        guard drawn.galaxies.count <= TracerWord.galaxyLimit else {
            throw CUDAError(
                .invalidArgument,
                "light tracers carry at most \(TracerWord.galaxyLimit) galaxies, not \(drawn.galaxies.count)")
        }
        let store = try CUDALightTracerStore(
            context: context, capacity: ParticleSystem.lightTracerTotal(drawn: drawn, massive: massive))
        var failure: Error?
        let (set, tracers) = ParticleSystem.streamingLightTracers(drawn: drawn, massive: massive) { chunk in
            guard failure == nil else { return }
            do { try store.append(chunk) } catch { failure = error }
        }
        if let failure { throw failure }
        guard store.count == tracers, tracers + set.count <= store.capacity else {
            throw CUDAError(
                .invalidArgument,
                "light tracers: \(tracers) drawn and \(set.count) massive, room for \(store.capacity)")
        }
        return (store, set)
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

    /// Every particle as it stands, tracers first, as `MetalBarnesHutSolver.particles` gives
    /// them: a tracer's light, kernel and birth radius at the steps they are kept at, its
    /// velocity half a kick ahead of the massive ones'. Downloaded on every access.
    public var particles: ParticleSystem {
        var system = host.template
        let tracers = tracerCount
        system.positions =
            (try? positions.download(SIMD3<Float>.self, count: massive, from: tracers * 16)) ?? []
        system.velocities =
            (try? velocities.download(SIMD3<Float>.self, count: massive, from: tracers * 16)) ?? []
        system.formation = (try? formation.download(Float.self, count: massive)) ?? []
        guard tracers > 0 else { return system }
        let states = (try? positions.download(SIMD4<Float>.self, count: tracers)) ?? []
        let motions = (try? velocities.download(SIMD4<UInt32>.self, count: tracers)) ?? []
        var traced = ParticleSystem(capacity: host.count)
        for index in 0..<min(states.count, motions.count) {
            let (state, motion) = (states[index], motions[index])
            let word = TracerWord(bits: motion.w)
            traced.append(
                position: SIMD3(state.x, state.y, state.z),
                velocity: SIMD3(
                    Float(bitPattern: motion.x), Float(bitPattern: motion.y),
                    Float(bitPattern: motion.z)),
                galaxy: word.galaxy, radius: word.birthRadius, population: 0.5,
                luminosity: word.luminosity, formation: state.w,
                component: ParticleComponent(rawValue: word.component) ?? .star, mass: 0,
                kernelScale: word.kernelScale)
        }
        traced.append(contentsOf: system)
        traced.setVisibleCount(tracers + massiveVisible)
        return traced
    }

    /// The tracer's attributes, `index` counting from the first tracer.
    public func tracerWord(_ index: Int) throws -> TracerWord {
        TracerWord(bits: try velocities.download(UInt32.self, count: 1, from: index * 16 + 12)[0])
    }

    /// Total momentum, as `MetalBarnesHutSolver.momentum()` sums it. Tracers weigh nothing.
    public func momentum() throws -> SIMD3<Float> {
        let moving = try velocities.download(SIMD3<Float>.self, count: massive, from: tracerCount * 16)
        return moving.withUnsafeBufferPointer { host.momentum(velocities: $0) }
    }

    /// The accelerations the last force pass left, tracers first, for validation against direct
    /// summation. A tracer keeps none, so theirs are walked again from the same tree (mode 2).
    public var accelerations: [SIMD3<Float>] {
        get throws {
            let heavy = try accelerationBuffer.download(SIMD3<Float>.self, count: massive)
            guard tracerCount > 0 else { return heavy }
            let probe = try context.makeBuffer(length: tracerCount * 16)
            try tracerSteps(mode: 2, pieces: 0..<tracerCount, disks: nil, probe: probe)
            return try probe.download(SIMD3<Float>.self, count: tracerCount) + heavy
        }
    }

    /// What each traversal cost, in node evaluations, by Morton slot.
    public var traversalCosts: [UInt32] {
        get throws { try costBuffer.download(UInt32.self, count: massive) }
    }

    /// Writes the smoothing lengths of the first `drawn` massive particles from the live tree,
    /// so the renderer needs no tree of its own. With light tracers each massive particle stands
    /// for its share of everything drawn, and the spacing records the tracers' kernels read are
    /// written beside, as `MetalBarnesHutSolver.writeSmoothing` writes them (#238). False before
    /// there is a tree.
    public func writeSmoothing(into lengths: CUDABuffer, drawn: Int) throws -> Bool {
        guard nodeCount > 0 else { return false }
        if tracerCount > 0 {
            let ratio = Float(tracerCount + massiveVisible) / Float(max(massiveVisible, 1))
            try builder.buildSmoothing(into: lengths, drawn: min(drawn, massiveVisible), ratio: ratio)
            try builder.buildSpacing(drawn: massiveVisible, ratio: ratio)
        } else {
            try builder.buildSmoothing(into: lengths, drawn: drawn)
        }
        return true
    }

    /// What the renderer reads to size a tracer's kernel (#238): the massive tree's spacing
    /// records, a `uint2` a node, the frame its codes are taken in and its depth. Nil without
    /// tracers or before `writeSmoothing`, and a new buffer after the tree grows.
    public var tracerSpacing: (cells: CUDABuffer, frame: CUDABuffer, depth: Int)? {
        guard tracerCount > 0, let spacing = builder.spacing else { return nil }
        return (spacing, builder.frame, builder.maximumDepth)
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
    public func buildTree(
        sortingTracers sortTracers: Bool, meanwhile work: [BarnesHutWork], profiled: Bool
    ) {
        attempt {
            let first = tracerCount * 16
            if !work.isEmpty {
                try positions.download(into: hostPositions.bytes, from: first)
                if host.dissipates { try velocities.download(into: hostVelocities.bytes, from: first) }
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
                if sortTracers { try timed("tracer sort") { try sortTracerOrder() } }
                profiler.update { $0.treeBuilds += 1 }
            } else {
                try builder.build(positions: positions, mass: massBuffer, sorted: sortedBuffer)
                for item in work { item.run() }
                while try grewAfterOverflow() {
                    try builder.build(positions: positions, mass: massBuffer, sorted: sortedBuffer)
                }
                if sortTracers { try sortTracerOrder() }
            }
            nodeCount = try builder.nodeCount
        }
    }

    /// The tracers in Morton order, which only decides how alike neighbouring walks are, a chunk
    /// of `sortChunk` at a time: the tree's radix sort on a GPU, a stable sort of the same codes
    /// on the CPU target (`CUDATreeBuilder.sortOrder`).
    private func sortTracerOrder() throws {
        guard let tracerSorter, let tracerOrder else { return }
        for start in stride(from: 0, to: tracerCount, by: sortChunk) {
            try tracerSorter.sortOrder(
                positions: positions, offset: start, points: min(sortChunk, tracerCount - start),
                into: tracerOrder, at: start)
        }
        if profiling { try context.synchronize() }
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
            // The tracers' half kick came with the last tracer pass.
            if tracerCount > 0 {
                var light = host.params(over: tracerCount)
                try check(sc_solver_tracer_drift(handle, &light, stride), "the tracers' drift")
            }
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
        case .tracerStarFormation:
            guard tracerCount > 0, nodeCount > 0 else { return }
            var formation = host.formationParams(nodeCount: nodeCount)
            try check(
                sc_solver_tracer_form_stars(
                    handle, builder.handle, &formation, MemoryLayout<StarFormationGPU>.stride),
                "the tracers' star formation")
        case .tracerStep(let mode, let pieces, let disks):
            try tracerSteps(mode: mode, pieces: pieces, disks: disks, probe: nil)
        }
    }

    /// The tracers' fused pass over `pieces` of their walk order, a launch for each
    /// `forceChunk` of them, as `MetalBarnesHutSolver` dispatches it (#238). It reads the massive
    /// particles the last massive pass gathered. Mode 2 writes each acceleration into `probe`.
    private func tracerSteps(
        mode: UInt32, pieces: Range<Int>, disks: [DiskCoolingGPU]?, probe: CUDABuffer?
    ) throws {
        guard tracerCount > 0 else { return }
        var p = host.tracerStepParams(mode: mode, disks: disks)
        let halos = host.haloList
        let holes = host.holes
        let cooling = disks ?? []
        var start = pieces.lowerBound
        while start < pieces.upperBound {
            let span = min(max(BarnesHutHost.forceChunk, 1), pieces.upperBound - start)
            p.chunkStart = UInt32(start)
            try check(
                sc_solver_tracer_step(
                    handle, builder.handle, &p, MemoryLayout<TracerStepGPU>.stride, UInt32(span),
                    halos, UInt32(halos.count), holes, UInt32(holes.count), cooling,
                    UInt32(cooling.count), probe?.handle),
                "the tracers' pass over \(start..<start + span)")
            start += span
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

// MARK: - Memory

extension CUDABarnesHutSolver {
    /// The device memory a solver holds, in bytes, by what it is for (#275).
    public struct Footprint: Sendable {
        /// The light tracers: 16 bytes of position and 16 of velocity each, 4 of walk order.
        public var tracers = 0
        /// The massive particles: their position and velocity, and what only they have.
        public var massive = 0
        /// The tree over the massive particles: its nodes and moments, codes and orders, and the
        /// spacing records the tracers' kernels read.
        public var tree = 0
        /// The tracers' sort: one chunk's codes and orders, whatever the count.
        public var sort = 0
        /// The halos, holes and disks the passes read, and the holes' partial sums.
        public var lists = 0

        public var total: Int { tracers + massive + tree + sort + lists }
    }

    /// The memory a solver of these counts holds once it is made and has written its spacing
    /// records, worked out with the sizes its allocations take, a buffer never under 16 bytes:
    /// what `CUDAContext.memoryHeld` counts, before the tree outgrows its first node capacity
    /// (each doubling adds 64 bytes a node with the quadrupole).
    public static func footprint(
        tracers: Int, massive: Int, galaxies: Int, holes: Int = 0, dissipates: Bool,
        quadrupole: Bool = BarnesHutHost.quadrupole, sortChunk: Int = BarnesHutHost.tracerSortChunk
    ) -> Footprint {
        func buffer(_ bytes: Int) -> Int { max(bytes, 16) }
        func tree(count: Int, nodes: Int, moments: Bool, order: Bool) -> Int {
            let tiles = (count + 2047) / 2048
            let table = tiles << 8
            return buffer(nodes * 32) + buffer(moments ? nodes * 32 : 0) + 2 * buffer(count * 8)
                + buffer(order ? count * 4 : 0) + buffer(count * 4) + buffer(table * 4)
                + buffer((table + 1023) / 1024 * 4) + buffer(32) + buffer(96) + buffer(32)
        }
        let massive = max(massive, 1)
        let tracing = tracers > 0
        let nodes = massive / 2 + 1024
        var footprint = Footprint()
        footprint.tracers = tracing ? tracers * 32 + buffer(tracers * 4) : 0
        footprint.massive =
            massive * 32 + buffer(massive * 16) * 2 + buffer(massive * 4) * (4 + (dissipates ? 1 : 0))
            + (tracing ? buffer(massive * 4) : 0)
        if !tracing { footprint.massive += 2 * (buffer(massive * 16) - massive * 16) }
        footprint.tree =
            tree(count: massive, nodes: nodes, moments: quadrupole, order: true)
            + (tracing ? buffer(nodes * 8) : 0)
        let chunk = min(max(sortChunk, 1), max(tracers, 1))
        footprint.sort = tracing ? tree(count: chunk, nodes: 1, moments: false, order: false) : 0
        footprint.lists =
            buffer(max(galaxies, 1) * 48) + (tracing || holes > 0 ? buffer(holes * 32) : 0)
            + (holes > 0 ? buffer((massive + 255) / 256 * 4 * 16) : 0)
            + (tracing || dissipates ? buffer(max(galaxies, 1) * 64) : 0)
        return footprint
    }
}
