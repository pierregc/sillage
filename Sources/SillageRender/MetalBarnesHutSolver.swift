import Foundation
import Metal
import SillageCore
import simd

/// Light tracers as the solver holds them (#238): the front of its position and velocity
/// buffers, 16 bytes each, the formation time in the w of the one and the `TracerWord` in the
/// w of the other. Filled a chunk at a time while the scene is sampled, so the drawn count is
/// never held as full particles; the massive particles go in after them.
public final class LightTracerStore {
    public let positions: MTLBuffer
    public let velocities: MTLBuffer
    /// Tracers and massive particles together.
    public let capacity: Int
    public private(set) var count = 0
    /// Left for a checkpoint to fill (#240): their saved velocities carry the first half kick.
    public private(set) var awaitsCheckpoint = false

    public init(device: MTLDevice, capacity: Int) throws {
        self.capacity = max(capacity, 1)
        guard
            let positions = device.makeBuffer(length: self.capacity * 16, options: .storageModeShared),
            let velocities = device.makeBuffer(length: self.capacity * 16, options: .storageModeShared)
        else { throw RenderError.textureAllocation }
        self.positions = positions
        self.velocities = velocities
    }

    /// Room for `tracers` light tracers that a checkpoint fills, so a resumed run samples none.
    public convenience init(device: MTLDevice? = nil, capacity: Int, awaiting tracers: Int) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else { throw RenderError.noDevice }
        try self.init(device: device, capacity: capacity)
        count = min(max(tracers, 0), self.capacity)
        awaitsCheckpoint = true
    }

    public func append(_ chunk: LightTracerChunk) {
        let taken = min(chunk.count, capacity - count)
        guard taken > 0 else { return }
        chunk.states.withUnsafeBytes {
            positions.contents().advanced(by: count * 16).copyMemory(
                from: $0.baseAddress!, byteCount: taken * 16)
        }
        chunk.motions.withUnsafeBytes {
            velocities.contents().advanced(by: count * 16).copyMemory(
                from: $0.baseAddress!, byteCount: taken * 16)
        }
        count += taken
    }
}

/// What the renderer needs to draw light tracers (#238), read afresh every frame: the tree
/// their kernels come from may have been rebuilt into new buffers since the last one.
public protocol TracerDrawing: AnyObject {
    var tracerCount: Int { get }
    /// Tracer positions first, with their formation times in w.
    var positions: MTLBuffer { get }
    /// Tracer velocities first, with their `TracerWord` in w.
    var velocities: MTLBuffer { get }
    /// The massive tree's spacing cell by cell, the frame its codes are taken in and its
    /// depth, nil before there is one.
    var tracerSpacing: (cells: MTLBuffer, frame: MTLBuffer, depth: Int)? { get }
}

/// Level 2: self-gravitating particles on a Barnes-Hut tree, with the dark halo left as a
/// rigid analytic potential that follows its own galaxy's centre of mass.
///
/// The rigid halo is the honest limitation of this solver. It carries most of the mass but
/// none of the inertia, so there is no dynamical friction against it and two galaxies keep
/// orbiting instead of settling into a merger. Live halos would fix that at the cost of five
/// to ten times more particles, none of which are visible.
public final class MetalBarnesHutSolver: Solver {
    public let kind: SolverKind = .barnesHut
    public var scene: SceneConfig { host.scene }
    public var time: Float { host.time }
    public let device: MTLDevice
    /// The solver's CPU side, which the CUDA engine shares: its counters, centres, disk frames,
    /// parameters and checkpoint state (#274).
    let host: BarnesHutHost

    /// Opening angle. Smaller is more accurate and slower; 0.5 to 0.7 is the usual range.
    public var openingAngle: Float {
        get { host.openingAngle }
        set { host.openingAngle = newValue }
    }
    /// Force softening in kpc, which should sit near the mean interparticle separation.
    public var softening: Float {
        get { host.softening }
        set { host.softening = newValue }
    }

    /// The longest single hold on the GPU since it was last read. A step is chunked so the
    /// display can get in between the pieces, which means the piece is what matters and the
    /// whole step is not: a window that is visible waits on a free drawable, and one dispatch
    /// longer than a frame stalls that wait for its whole length.
    public var longestDispatchMilliseconds = 0.0
    public var lastDriftMilliseconds: Double {
        get { host.lastDriftMilliseconds }
        set { host.lastDriftMilliseconds = newValue }
    }
    public var lastTreeMilliseconds: Double {
        get { host.lastTreeMilliseconds }
        set { host.lastTreeMilliseconds = newValue }
    }
    /// The tree build by the GPU clock.
    public private(set) var lastBuildMilliseconds = 0.0
    public var lastForceMilliseconds: Double { host.lastForceMilliseconds }
    /// Times every phase of a step into `takeProfile()`, and submits each GPU pass on its own
    /// so the GPU clock can say what each one cost.
    public var profiling = false
    private let profiler = StepProfiler()

    /// What the steps since the last call cost, phase by phase.
    public func takeProfile() -> StepProfile { profiler.take() }
    /// Read back once each build has run, so that nothing reads the counter while one runs.
    public private(set) var nodeCount = 0

    private let queue: MTLCommandQueue
    private let kickDrift: MTLComputePipelineState
    private let kick: MTLComputePipelineState
    private let force: MTLComputePipelineState
    /// The light tracers' force pass, kicks and cooling fused, and their drift (#238).
    private let tracerStep: MTLComputePipelineState?
    private let tracerDrift: MTLComputePipelineState?
    private let tracerFormStars: MTLComputePipelineState?
    private let gather: MTLComputePipelineState
    private let dissipate: MTLComputePipelineState?
    private let formStars: MTLComputePipelineState

    /// Every particle's position and velocity, `[tracers | massive visible | massive halo]`.
    /// Everything else is the massive particles' alone.
    private let positionBuffer: MTLBuffer
    private let velocityBuffer: MTLBuffer
    private let accelerationBuffer: MTLBuffer
    private let massBuffer: MTLBuffer
    /// Position and mass by Morton slot, gathered before each force pass.
    private let sortedBuffer: MTLBuffer
    /// When each particle's stars formed. Written by the solver, read by the renderer, and
    /// the one per-particle attribute that is not fixed for the life of a run.
    public let formationBuffer: MTLBuffer
    /// Node evaluations each traversal actually performed, indexed by Morton slot. A
    /// diagnostic, not state: nothing reads it but the divergence measurement.
    private let costBuffer: MTLBuffer
    /// The tree, built on the GPU from the positions in place. It used to be built on every
    /// core while the GPU sat idle, 13.7 % of a step at five million visible particles (#38).
    private let builder: GPUTreeBuilder
    private var componentBuffer: MTLBuffer?
    private var galaxyBuffer: MTLBuffer?

    private var particleMass: [Float] { host.particleMass }
    private var holes: [HoleGPU] { host.holes }
    private let holePull: MTLComputePipelineState?
    private let holeSettle: MTLComputePipelineState?
    private let holePartial: MTLBuffer?
    private static let holeLimit = 4
    private static let holeGroupWidth = 256
    private var template: ParticleSystem { host.template }
    private var count: Int { host.count }
    public var tracerCount: Int { host.tracerCount }
    private var massive: Int { host.massive }
    private var massiveVisible: Int { host.massiveVisible }
    public var tracerOpeningAngle: Float {
        get { host.tracerOpeningAngle }
        set { host.tracerOpeningAngle = newValue }
    }
    /// The tracers in Morton order, so that neighbours in a SIMD group walk alike: sorted a
    /// chunk of `sortChunk` at a time every `tracerSortInterval` steps, each chunk's entries
    /// counting from its start.
    private let tracerOrder: MTLBuffer?
    private let tracerSorter: GPUTreeBuilder?
    private var sortChunk: Int { host.sortChunk }
    private var stepsSinceTracerSort: Int { host.stepsSinceTracerSort }
    private var tracerOrderAge: Int { host.tracerOrderAge }
    private var lastCoolingDisks: [DiskCoolingGPU]? { host.lastCoolingDisks }
    /// The chance each massive gas particle had of forming stars this step, by Morton slot.
    private let slotChances: MTLBuffer?
    public let quadrupole: Bool
    public let opensHoldingCells: Bool
    var massCenters: [SIMD3<Float>] { host.massCenters }

    public var positions: MTLBuffer { positionBuffer }
    /// Read in place by the disk probe, which needs every velocity and must not copy them.
    public var velocities: MTLBuffer { velocityBuffer }
    public var formation: MTLBuffer { formationBuffer }
    public var centers: [SIMD3<Float>] { host.centers }
    public var diskFrames: [DiskState] { host.diskFrames }

    /// Every particle as it stands, tracers first. Rebuilt on every access, and with tracers
    /// their light, kernel and birth radius come back at the steps they are kept at, their
    /// velocity half a kick ahead of the massive ones'.
    public var particles: ParticleSystem {
        var system = template
        let p = positionBuffer.contents().advanced(by: tracerCount * 16)
            .bindMemory(to: SIMD3<Float>.self, capacity: massive)
        let v = velocityBuffer.contents().advanced(by: tracerCount * 16)
            .bindMemory(to: SIMD3<Float>.self, capacity: massive)
        system.positions = Array(UnsafeBufferPointer(start: p, count: massive))
        system.velocities = Array(UnsafeBufferPointer(start: v, count: massive))
        let f = formationBuffer.contents().bindMemory(to: Float.self, capacity: massive)
        system.formation = Array(UnsafeBufferPointer(start: f, count: massive))
        guard tracerCount > 0 else { return system }
        var traced = ParticleSystem(capacity: count)
        let states = UnsafeRawPointer(positionBuffer.contents())
        let motions = UnsafeRawPointer(velocityBuffer.contents())
        for index in 0..<tracerCount {
            let state = states.load(fromByteOffset: index * 16, as: SIMD4<Float>.self)
            let motion = motions.load(fromByteOffset: index * 16, as: SIMD4<UInt32>.self)
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
        traced.setVisibleCount(tracerCount + massiveVisible)
        return traced
    }

    public convenience init(device: MTLDevice? = nil, scene: SceneConfig) throws {
        try self.init(
            device: device, scene: scene,
            particles: RestrictedSolver.sampleParticles(for: scene))
    }

    /// Over `particles` laid out `[tracers | massive visible | massive halo]`, the first
    /// `tracers` of them light tracers, packed here as `lightTracers(drawn:massive:)` packs
    /// them while sampling.
    public convenience init(
        device: MTLDevice? = nil, scene: SceneConfig, particles: ParticleSystem,
        quadrupole: Bool = MetalBarnesHutSolver.quadrupole, tracers: Int = 0,
        opensHoldingCells: Bool = true
    ) throws {
        let tracers = min(max(tracers, 0), max(particles.visibleCount, 0))
        guard tracers > 0 else {
            try self.init(
                device: device, scene: scene, massive: particles, tracers: nil,
                quadrupole: quadrupole, opensHoldingCells: opensHoldingCells)
            return
        }
        guard let device = device ?? MTLCreateSystemDefaultDevice() else {
            throw RenderError.noDevice
        }
        let store = try LightTracerStore(device: device, capacity: particles.count)
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
        store.append(chunk)
        try self.init(
            device: device, scene: scene, massive: particles.slice(tracers..<particles.count),
            tracers: store, quadrupole: quadrupole, opensHoldingCells: opensHoldingCells)
    }

    /// Over `massive`, laid out `[visible | halo]`, and the light tracers `tracers` holds in
    /// front of where it puts them. `opensHoldingCells: false` walks the tree as before #221,
    /// when only the leaf holding a massive particle was kept from standing in for it; kept to
    /// measure against.
    public init(
        device: MTLDevice? = nil, scene: SceneConfig, massive particles: ParticleSystem,
        tracers store: LightTracerStore?, quadrupole: Bool = MetalBarnesHutSolver.quadrupole,
        opensHoldingCells: Bool = true
    ) throws {
        guard let device = device ?? store?.positions.device ?? MTLCreateSystemDefaultDevice()
        else {
            throw RenderError.noDevice
        }
        self.device = device
        let tracers = store?.count ?? 0
        let host = BarnesHutHost(scene: scene, massive: particles, tracers: tracers)
        self.host = host
        let massive = host.massive
        let count = host.count
        self.quadrupole = quadrupole
        self.opensHoldingCells = opensHoldingCells
        let holes = host.holes
        let treeMass = host.treeMass

        let library: MTLLibrary
        do {
            library = try ShaderCache.library(BarnesHutShaders.source, on: device)
        } catch {
            throw RenderError.shaderCompilation("\(error)")
        }
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw RenderError.pipelineCreation("missing kernel \(name)")
            }
            do { return try device.makeComputePipelineState(function: function) } catch {
                throw RenderError.pipelineCreation("\(name): \(error)")
            }
        }
        kickDrift = try pipeline("bhKickDrift")
        kick = try pipeline("bhKick")
        func specialised(_ name: String, _ values: [(index: Int, value: Bool)]) throws
            -> MTLComputePipelineState
        {
            let constants = MTLFunctionConstantValues()
            for (index, value) in values {
                var flag = value
                constants.setConstantValue(&flag, type: .bool, index: index)
            }
            do {
                return try device.makeComputePipelineState(
                    function: library.makeFunction(name: name, constantValues: constants))
            } catch {
                throw RenderError.pipelineCreation("\(name): \(error)")
            }
        }
        let tracing = tracers > 0
        force = try specialised("bhAcceleration", [(0, quadrupole), (3, opensHoldingCells)])
        tracerStep =
            tracing
            ? try specialised("bhTracerStep", [(0, quadrupole), (3, opensHoldingCells)]) : nil
        tracerDrift = tracing ? try pipeline("bhTracerDrift") : nil
        gather = try pipeline("bhGather")
        dissipate =
            scene.galaxies.contains { $0.dissipationTime > 0 }
            ? try pipeline("bhDissipate") : nil
        formStars = try specialised("bhFormStars", [(2, tracing)])
        tracerFormStars = tracing ? try pipeline("bhTracerFormStars") : nil
        holePull = holes.isEmpty ? nil : try pipeline("bhHolePull")
        holeSettle = holes.isEmpty ? nil : try pipeline("bhHoleSettle")

        guard let queue = device.makeCommandQueue() else { throw RenderError.noDevice }
        self.queue = queue

        let stride = MemoryLayout<SIMD3<Float>>.stride
        if let store, store.capacity < count {
            throw RenderError.unsupported(
                "light tracers' buffers hold \(store.capacity) particles, not \(count)")
        }
        guard
            let positionBuffer = store?.positions
                ?? device.makeBuffer(length: count * stride, options: .storageModeShared),
            let velocityBuffer = store?.velocities
                ?? device.makeBuffer(length: count * stride, options: .storageModeShared),
            let accelerationBuffer = device.makeBuffer(
                length: massive * stride, options: .storageModeShared),
            let massBuffer = device.makeBuffer(
                bytes: treeMass, length: massive * 4, options: .storageModeShared),
            let sortedBuffer = device.makeBuffer(
                length: massive * MemoryLayout<SIMD4<Float>>.stride, options: .storageModePrivate),
            let costBuffer = device.makeBuffer(
                length: massive * 4, options: .storageModeShared),
            let formationBuffer = device.makeBuffer(
                bytes: particles.formation.count == massive
                    ? particles.formation
                    : [Float](repeating: ParticleSystem.ancient, count: massive),
                length: massive * 4, options: .storageModeShared)
        else {
            throw RenderError.textureAllocation
        }
        self.positionBuffer = positionBuffer
        self.velocityBuffer = velocityBuffer
        self.accelerationBuffer = accelerationBuffer
        self.massBuffer = massBuffer
        self.sortedBuffer = sortedBuffer
        self.formationBuffer = formationBuffer
        self.costBuffer = costBuffer
        holePartial =
            holes.isEmpty
            ? nil
            : device.makeBuffer(
                length: ((massive + Self.holeGroupWidth - 1) / Self.holeGroupWidth) * Self.holeLimit
                    * MemoryLayout<SIMD4<Float>>.stride,
                options: .storageModePrivate)
        builder = try GPUTreeBuilder(
            device: device, count: massive, leafCapacity: Self.leafCapacity,
            maximumDepth: Self.maximumTreeDepth, quadrupole: quadrupole,
            nodeCapacity: massive / 2 + 1024, first: tracers)
        let sortChunk = host.sortChunk
        tracerOrder =
            tracing ? device.makeBuffer(length: tracers * 4, options: .storageModePrivate) : nil
        tracerSorter =
            tracing
            ? try GPUTreeBuilder(device: device, count: sortChunk, nodeCapacity: 1, ownOrder: false)
            : nil
        if tracing, tracerOrder == nil { throw RenderError.textureAllocation }
        slotChances =
            tracing ? device.makeBuffer(length: massive * 4, options: .storageModePrivate) : nil

        func attribute(_ values: [UInt32], _ fallback: UInt32) -> [UInt32] {
            values.count == massive ? values : [UInt32](repeating: fallback, count: massive)
        }
        // Star formation needs to know what a particle is; dissipation also needs whose it is.
        componentBuffer = device.makeBuffer(
            bytes: attribute(particles.component, 0), length: massive * 4,
            options: .storageModeShared)
        if dissipate != nil {
            galaxyBuffer = device.makeBuffer(
                bytes: attribute(particles.galaxyIndex, 0), length: massive * 4,
                options: .storageModeShared)
        }

        if !particles.positions.isEmpty {
            particles.positions.withUnsafeBytes {
                positionBuffer.contents().advanced(by: tracers * 16).copyMemory(
                    from: $0.baseAddress!, byteCount: $0.count)
            }
            particles.velocities.withUnsafeBytes {
                velocityBuffer.contents().advanced(by: tracers * 16).copyMemory(
                    from: $0.baseAddress!, byteCount: $0.count)
            }
        }

        BarnesHutStep.seed(
            host, on: self, tracersAwaitCheckpoint: store?.awaitsCheckpoint == true)
    }

    public func step() { step(count: 1) }

    public func step(count steps: Int) { BarnesHutStep.run(host, on: self, steps: steps) }

    /// Turns gas into stars where the tree says it has been compressed.
    ///
    /// Dispatched over nodes rather than particles: the density estimate lives on the leaves,
    /// and a leaf holds at most `leafCapacity` of them, so one thread does the reading and the
    /// drawing for all of its own. Nothing here is read back — the buffer it writes is the one
    /// the renderer draws from.
    private func encodeStarFormation(into buffer: MTLCommandBuffer) {
        guard componentBuffer != nil, var params = host.drawFormation(nodeCount: nodeCount) else {
            return
        }
        let first = tracerCount
        encode(into: buffer, formStars, threads: nodeCount) { encoder in
            encoder.setBuffer(formationBuffer, offset: 0, index: 0)
            encoder.setBuffer(componentBuffer, offset: 0, index: 1)
            encoder.setBuffer(massBuffer, offset: 0, index: 2)
            encoder.setBuffer(builder.nodes, offset: 0, index: 3)
            encoder.setBuffer(builder.order, offset: 0, index: 4)
            encoder.setBytes(
                &params, length: MemoryLayout<StarFormationGPU>.stride, index: 5)
            encoder.setBuffer(positionBuffer, offset: first * 16, index: 6)
            encoder.setBuffer(velocityBuffer, offset: first * 16, index: 7)
            encoder.setBuffer(slotChances ?? massBuffer, offset: 0, index: 8)
        }
    }

    /// The tracers' gas, at the chances the massive pass just wrote from the same tree and
    /// the same positions.
    private func encodeTracerStarFormation(into buffer: MTLCommandBuffer) {
        guard let tracerFormStars, let slotChances, componentBuffer != nil, nodeCount > 0 else {
            return
        }
        var params = host.formationParams(nodeCount: nodeCount)
        var counts = SIMD2<UInt32>(UInt32(tracerCount), UInt32(massive))
        encode(into: buffer, tracerFormStars, threads: tracerCount) { encoder in
            encoder.setBuffer(positionBuffer, offset: 0, index: 0)
            encoder.setBuffer(velocityBuffer, offset: 0, index: 1)
            encoder.setBuffer(builder.codes, offset: 0, index: 3)
            encoder.setBuffer(builder.frame, offset: 0, index: 4)
            encoder.setBuffer(slotChances, offset: 0, index: 5)
            encoder.setBytes(&params, length: MemoryLayout<StarFormationGPU>.stride, index: 6)
            encoder.setBytes(&counts, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 7)
        }
    }

    /// Writes the smoothing lengths of the first `drawn` massive particles from the live tree,
    /// so the renderer needs no tree of its own. With light tracers each massive particle
    /// stands for its share of everything drawn, and the spacing the tracers' kernels read is
    /// written beside (#238). False before there is a tree.
    public func writeSmoothing(into lengths: MTLBuffer, drawn: Int) -> Bool {
        guard nodeCount > 0, let buffer = queue.makeCommandBuffer() else { return false }
        if tracerCount > 0 {
            let ratio = Float(tracerCount + massiveVisible) / Float(max(massiveVisible, 1))
            builder.encodeSmoothing(
                into: buffer, lengths: lengths, drawn: min(drawn, massiveVisible), ratio: ratio)
            builder.encodeSpacing(into: buffer, drawn: massiveVisible, ratio: ratio)
        } else {
            builder.encodeSmoothing(into: buffer, lengths: lengths, drawn: drawn)
        }
        buffer.commit()
        buffer.waitUntilCompleted()
        return true
    }

    /// Pulls the disk back towards circular orbits, standing in for the gas that a real disk
    /// cools through. Runs after the kick so the accelerations it reads are this step's.
    private func encodeShedRandomMotion(into buffer: MTLCommandBuffer, disks: [DiskCoolingGPU]?) {
        guard let dissipate, var disks else { return }
        var p = params
        let first = tracerCount * 16
        encode(into: buffer, dissipate) { encoder in
            encoder.setBuffer(positionBuffer, offset: first, index: 0)
            encoder.setBuffer(velocityBuffer, offset: first, index: 1)
            encoder.setBuffer(accelerationBuffer, offset: 0, index: 2)
            encoder.setBuffer(componentBuffer, offset: 0, index: 3)
            encoder.setBuffer(galaxyBuffer, offset: 0, index: 4)
            encoder.setBytes(
                &disks, length: disks.count * MemoryLayout<DiskCoolingGPU>.stride, index: 5)
            encoder.setBytes(&p, length: MemoryLayout<BHParams>.stride, index: 6)
        }
    }

    private var params: BHParams { host.params }

    private func params(over particles: Int) -> BHParams { host.params(over: particles) }

    /// Encodes a pass into a command buffer without submitting it.
    ///
    /// Submitting each pass on its own and waiting for it cost far more than the passes did:
    /// `waitUntilCompleted` waits for everything already queued on the device, the renderer's
    /// frame included, so five round trips a step meant five frames' worth of latency for
    /// twenty-five milliseconds of actual work. Measured at 450 000 particles: a step of
    /// 128 ms of which the tree was 16 and the forces 9.
    private func encode(
        into buffer: MTLCommandBuffer, _ pipeline: MTLComputePipelineState, threads: Int? = nil,
        width: Int? = nil, _ configure: (MTLComputeCommandEncoder) -> Void
    ) {
        let total = threads ?? massive
        guard total > 0, let encoder = buffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(pipeline)
        configure(encoder)
        let widest = pipeline.maxTotalThreadsPerThreadgroup
        let group = (width ?? 0) > 0 ? min(width ?? widest, widest) : widest
        encoder.dispatchThreads(
            MTLSize(width: total, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: group, height: 1, depth: 1))
        encoder.endEncoding()
    }

    /// One pass on its own, for the callers that are not inside a step.
    private func dispatch(
        _ pipeline: MTLComputePipelineState, threads: Int? = nil,
        _ configure: (MTLComputeCommandEncoder) -> Void
    ) {
        guard let buffer = queue.makeCommandBuffer() else { return }
        encode(into: buffer, pipeline, threads: threads, configure)
        submit(buffer)
    }

    private func timed(_ phase: String, _ work: () -> Void) {
        guard profiling else { return work() }
        let clock = Date()
        work()
        let spent = Date().timeIntervalSince(clock) * 1000
        profiler.update { $0.add(phase, spent) }
    }

    private func profiledPass(_ phase: String, _ encodePass: (MTLCommandBuffer) -> Void) {
        guard let buffer = queue.makeCommandBuffer() else { return }
        encodePass(buffer)
        submit(buffer)
        let spent = max(buffer.gpuEndTime - buffer.gpuStartTime, 0) * 1000
        profiler.update { $0.add(phase, spent) }
    }

    private func submit(_ buffer: MTLCommandBuffer) {
        let clock = Date()
        buffer.commit()
        buffer.waitUntilCompleted()
        longestDispatchMilliseconds = max(
            longestDispatchMilliseconds, Date().timeIntervalSince(clock) * 1000)
    }

    // The solver's settings are `BarnesHutHost`'s, which the CUDA engine reads too (#274); they
    // keep the names they had here.
    public static var forceChunk: Int {
        get { BarnesHutHost.forceChunk }
        set { BarnesHutHost.forceChunk = newValue }
    }
    public static var leafCapacity: Int {
        get { BarnesHutHost.leafCapacity }
        set { BarnesHutHost.leafCapacity = newValue }
    }

    /// Threads per group in the force pass; zero takes the pipeline's maximum. The kernel keeps
    /// a 32 entry stack per thread, and 64 beat the maximum by 2% at 5M visible particles
    /// (363 against 370 ms) while the widths in between were level with it.
    nonisolated(unsafe) public static var forceThreadgroupWidth = 64

    public static var maximumTreeDepth: Int {
        get { BarnesHutHost.maximumTreeDepth }
        set { BarnesHutHost.maximumTreeDepth = newValue }
    }
    public static var treeReuse: Int {
        get { BarnesHutHost.treeReuse }
        set { BarnesHutHost.treeReuse = newValue }
    }
    public static var quadrupole: Bool {
        get { BarnesHutHost.quadrupole }
        set { BarnesHutHost.quadrupole = newValue }
    }
    public static var frameSample: Int {
        get { BarnesHutHost.frameSample }
        set { BarnesHutHost.frameSample = newValue }
    }
    public static var tidalFloor: Float {
        get { BarnesHutHost.tidalFloor }
        set { BarnesHutHost.tidalFloor = newValue }
    }
    public static var tidalCeiling: Float {
        get { BarnesHutHost.tidalCeiling }
        set { BarnesHutHost.tidalCeiling = newValue }
    }
    public static var tracerSortInterval: Int {
        get { BarnesHutHost.tracerSortInterval }
        set { BarnesHutHost.tracerSortInterval = newValue }
    }
    public static var tracerSortChunk: Int {
        get { BarnesHutHost.tracerSortChunk }
        set { BarnesHutHost.tracerSortChunk = newValue }
    }

    /// The massive particles' half kick and drift, and the tracers' drift: their half kick
    /// came with the last force pass.
    private func encodeIntegrate(into buffer: MTLCommandBuffer) {
        var p = params
        let first = tracerCount * 16
        encode(into: buffer, kickDrift) { encoder in
            encoder.setBuffer(positionBuffer, offset: first, index: 0)
            encoder.setBuffer(velocityBuffer, offset: first, index: 1)
            encoder.setBuffer(accelerationBuffer, offset: 0, index: 2)
            encoder.setBytes(&p, length: MemoryLayout<BHParams>.stride, index: 3)
        }
        guard let tracerDrift else { return }
        var light = params(over: tracerCount)
        encode(into: buffer, tracerDrift, threads: tracerCount) { encoder in
            encoder.setBuffer(positionBuffer, offset: 0, index: 0)
            encoder.setBuffer(velocityBuffer, offset: 0, index: 1)
            encoder.setBytes(&light, length: MemoryLayout<BHParams>.stride, index: 2)
        }
    }

    private func encodeKick(into buffer: MTLCommandBuffer) {
        var p = params
        encode(into: buffer, kick) { encoder in
            encoder.setBuffer(velocityBuffer, offset: tracerCount * 16, index: 0)
            encoder.setBuffer(accelerationBuffer, offset: 0, index: 1)
            encoder.setBytes(&p, length: MemoryLayout<BHParams>.stride, index: 2)
        }
    }

    /// The massive particles' positions as the GPU left them. The CPU passes read them in
    /// place rather than from a copy: only the drift writes them, and it has landed before
    /// anything reads them.
    private var currentPositions: UnsafeBufferPointer<SIMD3<Float>> {
        UnsafeBufferPointer(start: massiveState(positionBuffer), count: massive)
    }

    private func massiveState(_ buffer: MTLBuffer) -> UnsafeMutablePointer<SIMD3<Float>> {
        buffer.contents().advanced(by: tracerCount * 16)
            .bindMemory(to: SIMD3<Float>.self, capacity: massive)
    }

    /// Builds the tree from the positions and gathers the particles for the force pass on the
    /// way, `work` running on the CPU meanwhile.
    public func buildTree(
        sortingTracers sortTracers: Bool, meanwhile work: [BarnesHutWork], profiled: Bool
    ) {
        if profiling, profiled {
            for item in work { timed(item.phase, item.run) }
            repeat {
                for phase in GPUTreeBuilder.Phase.allCases {
                    profiledPass(phase.rawValue) {
                        builder.encode(
                            phase, into: $0, positions: positionBuffer, mass: massBuffer,
                            sorted: sortedBuffer)
                    }
                }
            } while grewAfterOverflow()
            if sortTracers { profiledPass("tracer sort") { encodeTracerSort(into: $0) } }
            profiler.update { $0.treeBuilds += 1 }
        } else if let buffer = queue.makeCommandBuffer() {
            builder.encode(
                into: buffer, positions: positionBuffer, mass: massBuffer, sorted: sortedBuffer)
            buffer.commit()
            // The centres read the positions the build is reading, so they are taken meanwhile.
            for item in work { item.run() }
            buffer.waitUntilCompleted()
            var spent = max(buffer.gpuEndTime - buffer.gpuStartTime, 0) * 1000
            longestDispatchMilliseconds = max(longestDispatchMilliseconds, spent)
            while grewAfterOverflow(), let again = queue.makeCommandBuffer() {
                builder.encode(
                    into: again, positions: positionBuffer, mass: massBuffer, sorted: sortedBuffer)
                submit(again)
                spent += max(again.gpuEndTime - again.gpuStartTime, 0) * 1000
            }
            lastBuildMilliseconds = spent
            if sortTracers, let sort = queue.makeCommandBuffer() {
                encodeTracerSort(into: sort)
                submit(sort)
            }
        }
        nodeCount = builder.nodeCount
    }

    /// True when the build ran out of nodes, once there is room for it to run again.
    private func grewAfterOverflow() -> Bool {
        guard builder.overflowed else { return false }
        do { try builder.grow() } catch {
            preconditionFailure("no room for a tree of \(builder.nodeCapacity * 2) nodes: \(error)")
        }
        return true
    }

    /// The black holes' pull on everything, and everything's back on them. After the whole
    /// force pass, which leaves each hole the analytic halos' pull and nothing else that is
    /// kept: the tree saw it as a test particle, at the stars' softening.
    private func encodeHoles(into buffer: MTLCommandBuffer) {
        guard let holePull, let holeSettle, let holePartial, !holes.isEmpty else { return }
        var list = haloList
        var count = UInt32(holes.count)
        // Over the massive particles alone, their indices counted from the first of them, so a
        // run with tracers sums the reactions as the same run without does (#239). The tracers
        // feel the holes in their own pass.
        var groups = UInt32((massive + Self.holeGroupWidth - 1) / Self.holeGroupWidth)
        var p = params
        let first = tracerCount * 16
        encode(into: buffer, holePull, width: Self.holeGroupWidth) { encoder in
            encoder.setBuffer(positionBuffer, offset: first, index: 0)
            encoder.setBuffer(accelerationBuffer, offset: 0, index: 1)
            encoder.setBuffer(massBuffer, offset: 0, index: 2)
            encoder.setBuffer(componentBuffer, offset: 0, index: 3)
            encoder.setBytes(holes, length: holes.count * MemoryLayout<HoleGPU>.stride, index: 4)
            encoder.setBytes(&count, length: 4, index: 5)
            encoder.setBytes(&p, length: MemoryLayout<BHParams>.stride, index: 6)
            encoder.setBuffer(holePartial, offset: 0, index: 7)
        }
        encode(into: buffer, holeSettle, threads: 1, width: 1) { encoder in
            encoder.setBuffer(positionBuffer, offset: first, index: 0)
            encoder.setBuffer(accelerationBuffer, offset: 0, index: 1)
            encoder.setBytes(holes, length: holes.count * MemoryLayout<HoleGPU>.stride, index: 2)
            encoder.setBytes(&count, length: 4, index: 3)
            encoder.setBytes(&groups, length: 4, index: 4)
            encoder.setBuffer(holePartial, offset: 0, index: 5)
            encoder.setBytes(&list, length: list.count * MemoryLayout<HaloGPU>.stride, index: 6)
            encoder.setBytes(&p, length: MemoryLayout<BHParams>.stride, index: 7)
        }
    }

    private var haloList: [HaloGPU] { host.haloList }

    /// A reused tree still needs this step's positions in its order.
    private func encodeGather(into buffer: MTLCommandBuffer) {
        var p = params
        let first = tracerCount * 16
        encode(into: buffer, gather, threads: massive) { encoder in
            encoder.setBuffer(sortedBuffer, offset: 0, index: 0)
            encoder.setBuffer(positionBuffer, offset: first, index: 1)
            encoder.setBuffer(massBuffer, offset: 0, index: 2)
            encoder.setBuffer(builder.order, offset: 0, index: 3)
            encoder.setBytes(&p, length: MemoryLayout<BHParams>.stride, index: 4)
        }
    }

    /// Particles are taken by Morton slot, so `pieces` is a range of slots.
    private func encodeAccelerations(into buffer: MTLCommandBuffer, pieces: Range<Int>? = nil) {
        var p = params
        let list = haloList
        let slots = pieces ?? 0..<massive
        var start = slots.lowerBound
        while start < slots.upperBound {
            let span = min(max(Self.forceChunk, 1), slots.upperBound - start)
            p.chunkStart = UInt32(start)
            encode(into: buffer, force, threads: span, width: Self.forceThreadgroupWidth) { encoder in
                encoder.setBuffer(sortedBuffer, offset: 0, index: 0)
                encoder.setBuffer(accelerationBuffer, offset: 0, index: 1)
                encoder.setBuffer(builder.nodes, offset: 0, index: 2)
                encoder.setBuffer(builder.order, offset: 0, index: 3)
                encoder.setBytes(list, length: list.count * MemoryLayout<HaloGPU>.stride, index: 4)
                encoder.setBytes(&p, length: MemoryLayout<BHParams>.stride, index: 5)
                encoder.setBuffer(costBuffer, offset: 0, index: 6)
                // A placeholder when the pipeline is the monopole's, which never reads it.
                encoder.setBuffer(builder.moments, offset: 0, index: 7)
                encoder.setBuffer(builder.codes, offset: 0, index: 10)
            }
            start += span
        }
    }

    /// The tracers' fused force pass over `pieces` of their walk order (#238). It reads the
    /// massive particles the last massive pass gathered, so it runs after it and before
    /// anything moves. `mode` 0 takes the first half kick, 1 closes this step and opens the
    /// next, 2 writes the acceleration into `probe` and moves nothing.
    private func encodeTracerStep(
        into buffer: MTLCommandBuffer, mode: UInt32, pieces: Range<Int>? = nil,
        disks: [DiskCoolingGPU]? = nil, probe: MTLBuffer? = nil, motions: MTLBuffer? = nil
    ) {
        guard let tracerStep, let tracerOrder, tracerCount > 0 else { return }
        let list = haloList
        var p = tracerStepParams(mode: mode, disks: disks)
        let cooling = disks ?? [DiskCoolingGPU(center: .zero, motion: .zero, axis: .zero, reach: .zero)]
        let pulls = holes.isEmpty ? [HoleGPU(massG: .zero, shape: .zero)] : holes
        let slots = pieces ?? 0..<tracerCount
        var start = slots.lowerBound
        while start < slots.upperBound {
            let span = min(max(Self.forceChunk, 1), slots.upperBound - start)
            p.chunkStart = UInt32(start)
            encode(into: buffer, tracerStep, threads: span, width: Self.forceThreadgroupWidth) {
                encoder in
                encoder.setBuffer(positionBuffer, offset: 0, index: 0)
                encoder.setBuffer(motions ?? velocityBuffer, offset: 0, index: 1)
                encoder.setBuffer(sortedBuffer, offset: 0, index: 2)
                encoder.setBuffer(builder.nodes, offset: 0, index: 3)
                encoder.setBuffer(builder.moments, offset: 0, index: 4)
                encoder.setBuffer(tracerOrder, offset: 0, index: 5)
                encoder.setBuffer(builder.frame, offset: 0, index: 6)
                encoder.setBytes(list, length: list.count * MemoryLayout<HaloGPU>.stride, index: 7)
                encoder.setBytes(pulls, length: pulls.count * MemoryLayout<HoleGPU>.stride, index: 8)
                encoder.setBuffer(positionBuffer, offset: tracerCount * 16, index: 9)
                encoder.setBytes(
                    cooling, length: cooling.count * MemoryLayout<DiskCoolingGPU>.stride, index: 10)
                encoder.setBytes(&p, length: MemoryLayout<TracerStepGPU>.stride, index: 11)
                encoder.setBuffer(probe ?? accelerationBuffer, offset: 0, index: 12)
            }
            start += span
        }
    }

    private func tracerStepParams(mode: UInt32, disks: [DiskCoolingGPU]?) -> TracerStepGPU {
        host.tracerStepParams(mode: mode, disks: disks)
    }

    /// The tracers in Morton order, which only decides how alike neighbouring walks are, a
    /// chunk of `sortChunk` at a time.
    private func encodeTracerSort(into buffer: MTLCommandBuffer) {
        guard let tracerSorter, let tracerOrder else { return }
        for start in stride(from: 0, to: tracerCount, by: sortChunk) {
            tracerSorter.encodeOrder(
                into: buffer, positions: positionBuffer, offset: start,
                points: min(sortChunk, tracerCount - start), order: tracerOrder, targetOffset: start)
        }
    }

    /// Total momentum. With live halos nothing external acts on the system, so this must be
    /// constant; a rigid halo that follows the disk makes it drift. Tracers weigh nothing.
    public func momentum() -> SIMD3<Float> { host.momentum(velocities: massiveVelocities) }

    /// What each massive traversal cost, in node evaluations, by Morton slot.
    public var traversalCosts: [UInt32] {
        Array(
            UnsafeBufferPointer(
                start: costBuffer.contents().bindMemory(to: UInt32.self, capacity: massive),
                count: massive))
    }

    /// Accelerations as computed by the GPU, tracers first, for validation against direct
    /// summation. A tracer keeps none, so theirs are walked again from the same tree.
    public var accelerations: [SIMD3<Float>] {
        let stored = accelerationBuffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: massive)
        let heavy = Array(UnsafeBufferPointer(start: stored, count: massive))
        guard tracerCount > 0,
            let probe = device.makeBuffer(length: tracerCount * 16, options: .storageModeShared),
            let buffer = queue.makeCommandBuffer()
        else { return heavy }
        encodeTracerStep(into: buffer, mode: 2, probe: probe)
        submit(buffer)
        let light = probe.contents().bindMemory(to: SIMD3<Float>.self, capacity: tracerCount)
        return Array(UnsafeBufferPointer(start: light, count: tracerCount)) + heavy
    }

    /// Every buffer `bhTracerStep` reads, as this step's tracer pass bound them, with Metal's
    /// probe on that same state and one more mode 1 pass run on a copy of the motions (#271).
    /// Moves nothing: a run that dumps goes on as one that does not.
    public func walkDump() -> TracerWalkDump? {
        guard tracerCount > 0, nodeCount > 0, let tracerOrder,
            let order = device.makeBuffer(length: tracerCount * 4, options: .storageModeShared),
            let sorted = device.makeBuffer(length: massive * 16, options: .storageModeShared),
            let probe = device.makeBuffer(length: tracerCount * 16, options: .storageModeShared),
            let stepped = device.makeBuffer(
                bytes: velocityBuffer.contents(), length: tracerCount * 16,
                options: .storageModeShared),
            let buffer = queue.makeCommandBuffer(), let blit = buffer.makeBlitCommandEncoder()
        else { return nil }
        blit.copy(from: sortedBuffer, sourceOffset: 0, to: sorted, destinationOffset: 0, size: massive * 16)
        blit.copy(from: tracerOrder, sourceOffset: 0, to: order, destinationOffset: 0, size: tracerCount * 4)
        blit.endEncoding()
        encodeTracerStep(into: buffer, mode: 2, probe: probe)
        encodeTracerStep(into: buffer, mode: 1, disks: lastCoolingDisks, motions: stepped)
        buffer.commit()
        buffer.waitUntilCompleted()
        guard buffer.status == .completed else { return nil }

        func bytes(_ source: MTLBuffer, from offset: Int = 0, _ length: Int) -> Data {
            Data(bytes: source.contents().advanced(by: offset), count: length)
        }
        func bytes<T>(_ values: [T]) -> Data { values.withUnsafeBytes { Data($0) } }
        let halos = haloList
        let pulls = holes.isEmpty ? [HoleGPU(massG: .zero, shape: .zero)] : holes
        let cooling =
            lastCoolingDisks ?? [DiskCoolingGPU(center: .zero, motion: .zero, axis: .zero, reach: .zero)]
        let params = tracerStepParams(mode: 1, disks: lastCoolingDisks)
        let nodeStride = MemoryLayout<BHNode>.stride
        let moments = quadrupole ? nodeCount * 2 : 0
        typealias Entry = TracerWalkDump.Buffer
        return TracerWalkDump(
            buffers: [
                Entry("states", 0, "float4", 16, tracerCount, bytes(positionBuffer, tracerCount * 16)),
                Entry("motions", 1, "uint4", 16, tracerCount, bytes(velocityBuffer, tracerCount * 16)),
                Entry("sorted", 2, "float4", 16, massive, bytes(sorted, massive * 16)),
                Entry(
                    "nodes", 3, "BHNode", nodeStride, nodeCount,
                    bytes(builder.nodes, nodeCount * nodeStride)),
                Entry("moments", 4, "float4", 16, moments, bytes(builder.moments, moments * 16)),
                Entry("order", 5, "uint", 4, tracerCount, bytes(order, tracerCount * 4)),
                Entry("frame", 6, "float", 4, 8, bytes(builder.frame, 8 * 4)),
                Entry("halos", 7, "HaloGPU", MemoryLayout<HaloGPU>.stride, halos.count, bytes(halos)),
                Entry("holes", 8, "HoleGPU", MemoryLayout<HoleGPU>.stride, pulls.count, bytes(pulls)),
                Entry(
                    "massive", 9, "float3", 16, massive,
                    bytes(positionBuffer, from: tracerCount * 16, massive * 16)),
                Entry(
                    "disks", 10, "DiskCooling", MemoryLayout<DiskCoolingGPU>.stride, cooling.count,
                    bytes(cooling)),
                Entry(
                    "params", 11, "TracerStepParams", MemoryLayout<TracerStepGPU>.stride, 1,
                    bytes([params])),
                Entry("accelerations", 12, "float3", 16, tracerCount, bytes(probe, tracerCount * 16)),
                Entry("motions-mode1", 1, "uint4", 16, tracerCount, bytes(stepped, tracerCount * 16)),
            ],
            params: params,
            counts: [
                "tracers": tracerCount, "massive": massive, "massiveVisible": massiveVisible,
                "nodes": nodeCount, "halos": Int(params.haloCount), "holes": holes.count,
                "disks": lastCoolingDisks?.count ?? 0,
            ],
            functionConstants: ["bhQuadrupole": quadrupole, "bhOpensHoldingCells": opensHoldingCells],
            tracerSort: .init(
                interval: max(Self.tracerSortInterval, 1), counter: stepsSinceTracerSort,
                stepsSinceSort: tracerOrderAge))
    }

    /// The tracer's attributes, `index` counting from the first tracer.
    public func tracerWord(_ index: Int) -> TracerWord {
        TracerWord(
            bits: UnsafeRawPointer(velocityBuffer.contents()).load(
                fromByteOffset: index * 16 + 12, as: UInt32.self))
    }

    /// Everything a take keeps of the drawn particles besides their paths, `[tracers | massive
    /// visible]`, with the formation times the run has reached. Positions and velocities are
    /// left empty: 28 bytes a drawn particle, made once at the end of a run.
    public func drawnAttributes() -> ParticleSystem {
        let drawn = tracerCount + massiveVisible
        var system = ParticleSystem(capacity: 0)
        system.galaxyIndex.reserveCapacity(drawn)
        system.birthRadius.reserveCapacity(drawn)
        system.population.reserveCapacity(drawn)
        system.luminosity.reserveCapacity(drawn)
        system.formation.reserveCapacity(drawn)
        system.component.reserveCapacity(drawn)
        system.kernelScale.reserveCapacity(drawn)
        let states = UnsafeRawPointer(positionBuffer.contents())
        for index in 0..<tracerCount {
            let word = tracerWord(index)
            system.galaxyIndex.append(word.galaxy)
            system.birthRadius.append(word.birthRadius)
            system.population.append(0.5)
            system.luminosity.append(word.luminosity)
            system.formation.append(states.load(fromByteOffset: index * 16 + 12, as: Float.self))
            system.component.append(word.component)
            system.kernelScale.append(word.kernelScale)
        }
        let times = formationBuffer.contents().bindMemory(to: Float.self, capacity: massive)
        for index in 0..<min(massiveVisible, template.galaxyIndex.count) {
            system.galaxyIndex.append(template.galaxyIndex[index])
            system.birthRadius.append(template.birthRadius[index])
            system.population.append(template.population[index])
            system.luminosity.append(template.luminosity[index])
            system.formation.append(times[index])
            system.component.append(template.component[index])
            system.kernelScale.append(template.kernelScale[index])
        }
        return system
    }

    /// Drawn particles whose stars formed after `start` and by `end`, tracers included.
    public func formed(after start: Float, until end: Float) -> Int {
        let block = 1 << 20
        let tracers = tracerCount
        let drawn = tracers + massiveVisible
        let blocks = (drawn + block - 1) / block
        var counts = [Int](repeating: 0, count: max(blocks, 1))
        let states = UnsafeRawPointer(positionBuffer.contents())
        let times = UnsafeRawPointer(formationBuffer.contents())
        counts.withUnsafeMutableBufferPointer { counts in
            DispatchQueue.concurrentPerform(iterations: blocks) { chunk in
                var formed = 0
                for index in (chunk * block)..<min((chunk + 1) * block, drawn) {
                    let time =
                        index < tracers
                        ? states.load(fromByteOffset: index * 16 + 12, as: Float.self)
                        : times.load(fromByteOffset: (index - tracers) * 4, as: Float.self)
                    if time > start && time <= end { formed += 1 }
                }
                counts[chunk] = formed
            }
        }
        return counts.reduce(0, +)
    }

    /// The distance from the origin of one particle in `step`, tracers first, dark matter
    /// included.
    public func radii(every step: Int = 1) -> [Float] {
        let states = UnsafeRawPointer(positionBuffer.contents())
        return stride(from: 0, to: count, by: max(step, 1)).map {
            let p = states.load(fromByteOffset: $0 * 16, as: SIMD4<Float>.self)
            return simd_length(SIMD3(p.x, p.y, p.z))
        }
    }

    /// Samples `drawn` with `massive` carrying its mass (#187), the light tracers packed while
    /// the sampler draws, a chunk at a time, into the buffers a solver over the massive set
    /// steps them in: the drawn count is never held as particles (#238).
    public static func lightTracers(
        device: MTLDevice? = nil, drawn: SceneConfig, massive: SceneConfig
    ) throws -> (tracers: LightTracerStore, massive: ParticleSystem) {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else {
            throw RenderError.noDevice
        }
        guard drawn.galaxies.count <= TracerWord.galaxyLimit else {
            throw RenderError.unsupported(
                "light tracers carry at most \(TracerWord.galaxyLimit) galaxies, not \(drawn.galaxies.count)")
        }
        let store = try LightTracerStore(
            device: device, capacity: ParticleSystem.lightTracerTotal(drawn: drawn, massive: massive))
        let (set, tracers) = ParticleSystem.streamingLightTracers(drawn: drawn, massive: massive) {
            store.append($0)
        }
        guard store.count == tracers, tracers + set.count <= store.capacity else {
            throw RenderError.unsupported(
                "light tracers: \(tracers) drawn and \(set.count) massive, room for \(store.capacity)")
        }
        return (store, set)
    }
}

extension MetalBarnesHutSolver: TracerDrawing {
    public var tracerSpacing: (cells: MTLBuffer, frame: MTLBuffer, depth: Int)? {
        guard tracerCount > 0, let spacing = builder.spacing else { return nil }
        return (spacing, builder.frame, builder.maximumDepth)
    }
}

// MARK: - Checkpoint

extension MetalBarnesHutSolver {
    public typealias State = SolverState

    public typealias CheckpointError = RunCheckpointError

    public var state: State { host.state }

    /// The bytes `writeParticles` writes.
    public var particleBytes: Int { count * 32 + massive * 4 }

    /// What changes of each particle: every position and velocity as the buffers hold them,
    /// tracers first with their formation time and their `TracerWord` in w (#238), then the
    /// massive particles' formation times. The rest of a massive particle never changes.
    private var changing: [(buffer: MTLBuffer, length: Int)] {
        [(positionBuffer, count * 16), (velocityBuffer, count * 16), (formationBuffer, massive * 4)]
    }

    public func writeParticles(to handle: FileHandle) throws {
        for (buffer, length) in changing {
            try RunCheckpoint.write(buffer.contents(), length, to: handle)
        }
    }

    /// Puts the run back where a checkpoint of it left it: its buffers read back, its counters,
    /// centres and disks set, and the tree and the accelerations the next step starts from
    /// built again from the positions, as the last step built them. Exact with one tree a step.
    public func restore(_ state: State, from handle: FileHandle) throws {
        try host.accepts(state)
        for (buffer, length) in changing {
            var read = 0
            while read < length {
                let piece = min(length - read, 256 << 20)
                guard let data = try handle.read(upToCount: piece), data.count == piece else {
                    throw CheckpointError.truncated
                }
                data.withUnsafeBytes {
                    buffer.contents().advanced(by: read).copyMemory(
                        from: $0.baseAddress!, byteCount: piece)
                }
                read += piece
            }
        }
        host.take(state)
        BarnesHutStep.restored(host, on: self)
    }
}

// MARK: - The step's passes

extension MetalBarnesHutSolver: BarnesHutPasses {
    public var massivePositions: UnsafeBufferPointer<SIMD3<Float>> { currentPositions }

    public var massiveVelocities: UnsafeBufferPointer<SIMD3<Float>> {
        UnsafeBufferPointer(start: massiveState(velocityBuffer), count: massive)
    }

    /// One command buffer for `passes`, committed and waited for.
    public func run(_ passes: [BarnesHutPass]) {
        guard let buffer = queue.makeCommandBuffer() else { return }
        for pass in passes { encode(pass, into: buffer) }
        submit(buffer)
    }

    public func profile(_ phase: String, _ passes: [BarnesHutPass]) {
        profiledPass(phase) { buffer in
            for pass in passes { encode(pass, into: buffer) }
        }
    }

    public func stepped(milliseconds: Double) {
        profiler.update {
            $0.steps += 1
            $0.add("step", milliseconds)
        }
    }

    private func encode(_ pass: BarnesHutPass, into buffer: MTLCommandBuffer) {
        switch pass {
        case .starFormation: encodeStarFormation(into: buffer)
        case .tracerStarFormation: encodeTracerStarFormation(into: buffer)
        case .drift: encodeIntegrate(into: buffer)
        case .gather: encodeGather(into: buffer)
        case .accelerations(let pieces): encodeAccelerations(into: buffer, pieces: pieces)
        case .holes: encodeHoles(into: buffer)
        case .kick: encodeKick(into: buffer)
        case .dissipation(let disks): encodeShedRandomMotion(into: buffer, disks: disks)
        case .tracerStep(let mode, let pieces, let disks):
            encodeTracerStep(into: buffer, mode: mode, pieces: pieces, disks: disks)
        }
    }
}
