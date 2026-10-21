import Foundation
import Metal
import SillageCore
import simd

struct HaloGPU {
    var centerBefore: SIMD4<Float>
    var centerAfter: SIMD4<Float>
    /// Mass carrying G, scale radius, profile index, unused.
    var shape: SIMD4<Float>
}

struct StarFormationGPU {
    var efficiency: Float
    var threshold: Float
    var timeStep: Float
    var time: Float
    var gravitationalConstant: Float
    var compressionBoost: Float
    var compressionFloor: Float
    var seed: UInt32
    var nodeCount: UInt32
}

struct DiskCoolingGPU {
    var center: SIMD4<Float>
    var motion: SIMD4<Float>
    var axis: SIMD4<Float>
    var reach: SIMD4<Float>
}

struct BHParams {
    var particleCount: UInt32
    var haloCount: UInt32
    var timeStep: Float
    var openingAngleSquared: Float
    var softeningSquared: Float
    var gravitationalConstant: Float
    /// First particle of the piece being dispatched. The force pass is split so the display
    /// is not locked out for the length of one very large kernel.
    var chunkStart: UInt32 = 0
    var pad1: Float = 0
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
    public let scene: SceneConfig
    public private(set) var time: Float = 0
    public let device: MTLDevice

    /// Opening angle. Smaller is more accurate and slower; 0.5 to 0.7 is the usual range.
    public var openingAngle: Float
    /// Force softening in kpc, which should sit near the mean interparticle separation.
    public var softening: Float

    /// The longest single hold on the GPU since it was last read. A step is chunked so the
    /// display can get in between the pieces, which means the piece is what matters and the
    /// whole step is not: a window that is visible waits on a free drawable, and one dispatch
    /// longer than a frame stalls that wait for its whole length.
    public var longestDispatchMilliseconds = 0.0
    public var lastDriftMilliseconds = 0.0
    public var lastTreeMilliseconds = 0.0
    /// The tree build by the GPU clock.
    public private(set) var lastBuildMilliseconds = 0.0
    public private(set) var lastForceMilliseconds = 0.0
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
    private let gather: MTLComputePipelineState
    private let dissipate: MTLComputePipelineState?
    private let formStars: MTLComputePipelineState
    private let smooth: MTLComputePipelineState

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
    /// The last build gathered the particles into Morton order, so the force pass need not.
    private var gathered = false
    private var componentBuffer: MTLBuffer?
    private var galaxyBuffer: MTLBuffer?

    /// Masses never change, so they are read once.
    private let particleMass: [Float]
    private let template: ParticleSystem
    private let count: Int
    private let galaxyOf: [UInt32]
    private let componentOf: [UInt32]
    private let liveHalos: Bool
    public let quadrupole: Bool
    private var stepsSinceTree = 0
    /// Only ever used to vary the per-step random draw in the star formation pass.
    private var stepsSinceFormation = 0
    private var haloCenters: [SIMD3<Float>]
    private var galaxyMotion: [SIMD3<Float>]
    private var diskStates: [DiskState]
    private let centersLock = NSLock()

    public var positions: MTLBuffer { positionBuffer }
    public var formation: MTLBuffer { formationBuffer }
    /// Written on whichever queue is stepping and read by the renderer on the main thread,
    /// so the array is handed over under a lock rather than copied out from under the write.
    public var centers: [SIMD3<Float>] {
        centersLock.lock()
        defer { centersLock.unlock() }
        return haloCenters
    }

    /// The axis each disk is currently turning about, and how much of its material still
    /// turns that way. Both are measured from the particles rather than taken from the setup,
    /// and both are what decides whether the disk is still cooled. Exposed because a run that
    /// wrongly keeps cooling a wrecked disk looks perfectly healthy from anywhere else.
    public var diskFrames: [DiskState] {
        centersLock.lock()
        defer { centersLock.unlock() }
        return diskStates
    }

    public var particles: ParticleSystem {
        var system = template
        let p = positionBuffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: count)
        let v = velocityBuffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: count)
        system.positions = Array(UnsafeBufferPointer(start: p, count: count))
        system.velocities = Array(UnsafeBufferPointer(start: v, count: count))
        let f = formationBuffer.contents().bindMemory(to: Float.self, capacity: count)
        system.formation = Array(UnsafeBufferPointer(start: f, count: count))
        return system
    }

    public convenience init(device: MTLDevice? = nil, scene: SceneConfig) throws {
        try self.init(
            device: device, scene: scene,
            particles: RestrictedSolver.sampleParticles(for: scene))
    }

    public init(
        device: MTLDevice? = nil, scene: SceneConfig, particles: ParticleSystem,
        quadrupole: Bool = MetalBarnesHutSolver.quadrupole
    ) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else {
            throw RenderError.noDevice
        }
        self.device = device
        self.scene = scene
        self.count = max(particles.count, 1)
        self.openingAngle = scene.openingAngle
        self.softening = scene.softening
        self.galaxyOf = particles.galaxyIndex
        self.componentOf = particles.component
        self.liveHalos = scene.hasLiveHalos
        self.quadrupole = quadrupole
        self.haloCenters = scene.galaxies.map(\.position)
        self.galaxyMotion = scene.galaxies.map(\.velocity)
        self.diskStates = DiskState.natal(scene)
        var masses = particles.mass
        if masses.count != self.count {
            masses = [Float](repeating: 0, count: self.count)
        }
        self.particleMass = masses

        var stripped = particles
        stripped.positions = []
        stripped.velocities = []
        // Read back from the buffer the solver writes, not from the sample it started with.
        stripped.formation = []
        self.template = stripped

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
        let constants = MTLFunctionConstantValues()
        var specialised = quadrupole
        constants.setConstantValue(&specialised, type: .bool, index: 0)
        do {
            force = try device.makeComputePipelineState(
                function: library.makeFunction(name: "bhAcceleration", constantValues: constants))
        } catch {
            throw RenderError.pipelineCreation("bhAcceleration: \(error)")
        }
        gather = try pipeline("bhGather")
        dissipate =
            scene.galaxies.contains { $0.dissipationTime > 0 }
            ? try pipeline("bhDissipate") : nil
        formStars = try pipeline("bhFormStars")
        smooth = try pipeline("bhSmoothing")

        guard let queue = device.makeCommandQueue() else { throw RenderError.noDevice }
        self.queue = queue

        let stride = MemoryLayout<SIMD3<Float>>.stride
        guard
            let positionBuffer = device.makeBuffer(
                length: count * stride, options: .storageModeShared),
            let velocityBuffer = device.makeBuffer(
                length: count * stride, options: .storageModeShared),
            let accelerationBuffer = device.makeBuffer(
                length: count * stride, options: .storageModeShared),
            let massBuffer = device.makeBuffer(
                bytes: particles.mass.isEmpty ? [Float(0)] : particles.mass,
                length: count * 4, options: .storageModeShared),
            let sortedBuffer = device.makeBuffer(
                length: count * MemoryLayout<SIMD4<Float>>.stride, options: .storageModePrivate),
            let costBuffer = device.makeBuffer(
                length: count * 4, options: .storageModeShared),
            let formationBuffer = device.makeBuffer(
                bytes: particles.formation.count == count
                    ? particles.formation
                    : [Float](repeating: ParticleSystem.ancient, count: count),
                length: count * 4, options: .storageModeShared)
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
        builder = try GPUTreeBuilder(
            device: device, count: count, leafCapacity: Self.leafCapacity,
            maximumDepth: Self.maximumTreeDepth, quadrupole: quadrupole,
            nodeCapacity: count / 2 + 1024)

        func attribute(_ values: [UInt32], _ fallback: UInt32) -> [UInt32] {
            values.count == count ? values : [UInt32](repeating: fallback, count: count)
        }
        // Star formation needs to know what a particle is; dissipation also needs whose it is.
        componentBuffer = device.makeBuffer(
            bytes: attribute(particles.component, 0), length: count * 4,
            options: .storageModeShared)
        if dissipate != nil {
            galaxyBuffer = device.makeBuffer(
                bytes: attribute(particles.galaxyIndex, 0), length: count * 4,
                options: .storageModeShared)
        }

        if !particles.positions.isEmpty {
            particles.positions.withUnsafeBytes {
                positionBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count)
            }
            particles.velocities.withUnsafeBytes {
                velocityBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count)
            }
        }

        // The first half kick needs an acceleration, so seed it before stepping.
        rebuildTree()
        if let buffer = queue.makeCommandBuffer() {
            encodeAccelerations(into: buffer)
            submit(buffer)
        }
    }

    public func step() { step(count: 1) }

    public func step(count steps: Int) {
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
            if profiling {
                profiledPass("star formation") { encodeStarFormation(into: $0) }
                profiledPass("drift") { encodeIntegrate(into: $0) }
            } else if let opening = queue.makeCommandBuffer() {
                encodeStarFormation(into: opening)
                encodeIntegrate(into: opening)
                submit(opening)
            }
            lastDriftMilliseconds = Date().timeIntervalSince(clock) * 1000
            clock = Date()
            if stepsSinceTree <= 0 {
                rebuildTree()
                stepsSinceTree = max(Self.treeReuse, 1)
            }
            stepsSinceTree -= 1
            lastTreeMilliseconds = Date().timeIntervalSince(clock) * 1000
            clock = Date()
            if profiling {
                profiledPass("force") { encodeAccelerations(into: $0) }
                profiledPass("kick") { encodeKick(into: $0) }
                profiledPass("dissipation") { encodeShedRandomMotion(into: $0) }
            } else {
                submitForces()
            }
            lastForceMilliseconds = Date().timeIntervalSince(clock) * 1000
            time += scene.timeStep
            if profiling {
                let spent = Date().timeIntervalSince(stepClock) * 1000
                profiler.update {
                    $0.steps += 1
                    $0.add("step", spent)
                }
            }
        }
    }

    /// The force pass, one command buffer a piece, with the kick and the cooling in the last.
    ///
    /// A frame queued behind the solver waits for the whole command buffer, not for the next
    /// piece encoded in it. The CPU build used to be the gap frames got in through; without it
    /// one buffer for the whole pass halved the live frame rate, 13 to 15 a second down to 8
    /// at two million visible particles. In pieces it was 17.5, and with nothing drawn the
    /// pieces cost nothing (#38).
    private func submitForces() {
        var start = 0
        repeat {
            guard let buffer = queue.makeCommandBuffer() else { return }
            let span = min(max(Self.forceChunk, 1), count - start)
            encodeAccelerations(into: buffer, pieces: start..<(start + span))
            start += span
            if start >= count {
                encodeKick(into: buffer)
                encodeShedRandomMotion(into: buffer)
            }
            submit(buffer)
        } while start < count
    }

    /// Turns gas into stars where the tree says it has been compressed.
    ///
    /// Dispatched over nodes rather than particles: the density estimate lives on the leaves,
    /// and a leaf holds at most `leafCapacity` of them, so one thread does the reading and the
    /// drawing for all of its own. Nothing here is read back — the buffer it writes is the one
    /// the renderer draws from.
    private func encodeStarFormation(into buffer: MTLCommandBuffer) {
        guard nodeCount > 0, componentBuffer != nil else { return }
        stepsSinceFormation &+= 1
        var params = StarFormationGPU(
            efficiency: StarFormation.efficiency,
            threshold: StarFormation.thresholdDensity,
            timeStep: scene.timeStep,
            time: time,
            gravitationalConstant: Physics.gravitationalConstant,
            compressionBoost: StarFormation.compressionBoost,
            compressionFloor: StarFormation.compressionFloor,
            seed: UInt32(truncatingIfNeeded: stepsSinceFormation),
            nodeCount: UInt32(nodeCount))
        encode(into: buffer, formStars, threads: nodeCount) { encoder in
            encoder.setBuffer(formationBuffer, offset: 0, index: 0)
            encoder.setBuffer(componentBuffer, offset: 0, index: 1)
            encoder.setBuffer(massBuffer, offset: 0, index: 2)
            encoder.setBuffer(builder.nodes, offset: 0, index: 3)
            encoder.setBuffer(builder.order, offset: 0, index: 4)
            encoder.setBytes(
                &params, length: MemoryLayout<StarFormationGPU>.stride, index: 5)
            encoder.setBuffer(positionBuffer, offset: 0, index: 6)
            encoder.setBuffer(velocityBuffer, offset: 0, index: 7)
        }
    }

    /// Writes the smoothing lengths of the first `drawn` particles from the live tree, so the
    /// renderer needs no tree of its own. False before there is one.
    public func writeSmoothing(into lengths: MTLBuffer, drawn: Int) -> Bool {
        guard nodeCount > 0, let buffer = queue.makeCommandBuffer() else { return false }
        var counts = SIMD2<UInt32>(
            UInt32(nodeCount), UInt32(min(drawn, count, lengths.length / 4)))
        encode(into: buffer, smooth, threads: nodeCount) { encoder in
            encoder.setBuffer(lengths, offset: 0, index: 0)
            encoder.setBuffer(builder.nodes, offset: 0, index: 1)
            encoder.setBuffer(builder.order, offset: 0, index: 2)
            encoder.setBytes(&counts, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 3)
        }
        buffer.commit()
        buffer.waitUntilCompleted()
        return true
    }

    /// Pulls the disk back towards circular orbits, standing in for the gas that a real disk
    /// cools through. Runs after the kick so the accelerations it reads are this step's.
    private func encodeShedRandomMotion(into buffer: MTLCommandBuffer) {
        guard let dissipate else { return }
        let elapsed = scene.timeStep * Float(Physics.megayearsPerTimeUnit)
        centersLock.lock()
        let frames = (haloCenters, galaxyMotion, diskStates)
        centersLock.unlock()
        var disks = scene.galaxies.enumerated().map { index, galaxy -> DiskCoolingGPU in
            let centre = index < frames.0.count ? frames.0[index] : galaxy.position
            let motion = index < frames.1.count ? frames.1[index] : galaxy.velocity
            let state = index < frames.2.count ? frames.2[index] : DiskState.natal(galaxy)
            let axis = state.axis
            // The share of the gap to circular closed this step, from the time constant,
            // taken away again by whatever is stopping this from being a quiet disk: a
            // companion close enough to be tearing at it now, and the memory of one that
            // already has.
            let disturbed = Self.smoothstep(
                Self.tidalFloor, Self.tidalCeiling, tidalStress(on: index, centers: frames.0))
            let wrecked = state.disruption
            let quiet = max((1 - disturbed) * (1 - wrecked), 0)
            let damping =
                galaxy.dissipationTime > 0 && galaxy.kind != .globular
                ? quiet * (1 - exp(-elapsed / galaxy.dissipationTime)) : 0
            let edge = max(galaxy.diskScaleLength, 0.1)
            // The floor the disk cools to, taken from the equilibrium it was sampled in so it
            // holds the Toomre parameter the galaxy asked for rather than a number picked by
            // hand. Read at two scale lengths and carried as a fraction of the circular
            // speed, which is close enough to constant across an exponential disk.
            let equilibrium = DiskEquilibrium(config: galaxy, selfGravitating: true)
            let reference = edge * 2
            let circular = max(equilibrium.circularSpeed(atRadius: reference), 1e-6)
            // The floor applies to the whole peculiar velocity, so it has to be the whole
            // equilibrium dispersion. Flooring the three-dimensional motion at the radial
            // component alone leaves the radial part below what Toomre asks and the disk
            // fragments anyway, which is what the first attempt did.
            let radial = equilibrium.radialDispersion(atRadius: reference)
            let azimuthal = equilibrium.azimuthalDispersion(atRadius: reference)
            let vertical = equilibrium.verticalDispersion(atRadius: reference)
            let dispersion =
                (radial * radial + azimuthal * azimuthal + vertical * vertical).squareRoot()
            let floorFraction = min(dispersion / circular, 0.5)
            return DiskCoolingGPU(
                center: SIMD4<Float>(centre.x, centre.y, centre.z, floorFraction),
                motion: SIMD4<Float>(motion.x, motion.y, motion.z, damping),
                axis: SIMD4<Float>(axis.x, axis.y, axis.z, 0),
                // Generous on purpose. Halo and bulge are already excluded by component, so
                // the only thing these limits keep out is material genuinely thrown clear —
                // a tidal tail, not a disk star that has been heated. Cutting in at a few
                // scale heights did the opposite: it stopped cooling the stars that had
                // picked up the most motion, and the disk heated almost as fast as with no
                // dissipation at all.
                reach: SIMD4<Float>(edge * 5, edge * 9, edge, edge * 2))
        }
        if disks.isEmpty { return }
        // Permanent once every disk is wrecked, which is where a merger ends up.
        if disks.allSatisfy({ $0.motion.w <= 0 }) { return }

        var p = params
        encode(into: buffer, dissipate) { encoder in
            encoder.setBuffer(positionBuffer, offset: 0, index: 0)
            encoder.setBuffer(velocityBuffer, offset: 0, index: 1)
            encoder.setBuffer(accelerationBuffer, offset: 0, index: 2)
            encoder.setBuffer(componentBuffer, offset: 0, index: 3)
            encoder.setBuffer(galaxyBuffer, offset: 0, index: 4)
            encoder.setBytes(
                &disks, length: disks.count * MemoryLayout<DiskCoolingGPU>.stride, index: 5)
            encoder.setBytes(&p, length: MemoryLayout<BHParams>.stride, index: 6)
        }
    }

    private var params: BHParams {
        BHParams(
            particleCount: UInt32(count),
            // With a live halo the dark matter is already in the tree; adding the analytic
            // potential on top would double its mass, and a rigid potential that follows the
            // disk does work on the system, which is why the old one leaked energy.
            haloCount: liveHalos ? 0 : UInt32(scene.galaxies.count),
            timeStep: scene.timeStep,
            openingAngleSquared: openingAngle * openingAngle,
            softeningSquared: softening * softening,
            gravitationalConstant: Physics.gravitationalConstant)
    }

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
        guard let encoder = buffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(pipeline)
        configure(encoder)
        let widest = pipeline.maxTotalThreadsPerThreadgroup
        let group = (width ?? 0) > 0 ? min(width ?? widest, widest) : widest
        encoder.dispatchThreads(
            MTLSize(width: threads ?? count, height: 1, depth: 1),
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

    // Deliberately mutable: the tests and the measurement probes set these to sweep them, and
    // nothing else ever writes one. Strict concurrency has no way to know that, so it is said
    // here rather than by making them lets that the tests could not move.
    //
    /// Particles per piece of the force pass, each committed on its own. A whole large scene
    /// in one kernel keeps the GPU to itself long enough that the pointer stutters, and frames
    /// only get in between command buffers.
    nonisolated(unsafe) public static var forceChunk = 1_000_000

    /// Particles a leaf may hold before it splits. Bigger leaves mean far fewer nodes and a
    /// cheaper build at the cost of more direct summation in the force pass. That trade only
    /// became worth taking once leaves started respecting the opening criterion, since a
    /// distant leaf now costs one evaluation whatever it holds.
    nonisolated(unsafe) public static var leafCapacity = 16

    /// Threads per group in the force pass; zero takes the pipeline's maximum. The kernel keeps
    /// a 32 entry stack per thread, and 64 beat the maximum by 2% at 5M visible particles
    /// (363 against 370 ms) while the widths in between were level with it.
    nonisolated(unsafe) public static var forceThreadgroupWidth = 64

    /// How deep the tree may go. A merged core subdivides to the ceiling, one dispatch a level.
    /// Twenty is right when accuracy matters; thirteen puts the smallest cell at a few tens of
    /// parsecs, far below any softening length used here.
    nonisolated(unsafe) public static var maximumTreeDepth = 20

    /// Steps a tree is reused for. The build is most of what a step costs, and what decides
    /// whether motion looks continuous is how *often* positions change, not how far they move
    /// each time: a few large steps a second make the galaxies jump while the starfield, which
    /// only follows the camera, glides. Reusing the tree buys the step rate that fixes that,
    /// and costs nothing at these step sizes — a particle crosses a fraction of a leaf cell
    /// in the interval, which is well inside what the opening angle already approximates.
    nonisolated(unsafe) public static var treeReuse = 1

    /// Whether an accepted cell adds its quadrupole to its monopole, which is what lets the
    /// opening angle be 0.9 rather than 0.7 for the same force error. The default for new
    /// solvers; the monopole stays for measuring against.
    nonisolated(unsafe) public static var quadrupole = true

    /// Particles a galaxy contributes to its own disk frame. The axis and the coherence are
    /// mass-weighted sums over a hundred thousand-odd stars; fifty thousand of them give the
    /// same answer, and this runs on every tree rebuild.
    nonisolated(unsafe) public static var frameSample = 50_000

    /// Where a companion stops leaving the disk alone, as the disk's radius over its tidal
    /// radius. Below the floor the disk sits well inside the tidal radius and its gas is
    /// undisturbed; past the ceiling the companion is cutting into the disk itself.
    nonisolated(unsafe) public static var tidalFloor: Float = 0.7
    nonisolated(unsafe) public static var tidalCeiling: Float = 1.4

    private func encodeIntegrate(into buffer: MTLCommandBuffer) {
        var p = params
        encode(into: buffer, kickDrift) { encoder in
            encoder.setBuffer(positionBuffer, offset: 0, index: 0)
            encoder.setBuffer(velocityBuffer, offset: 0, index: 1)
            encoder.setBuffer(accelerationBuffer, offset: 0, index: 2)
            encoder.setBytes(&p, length: MemoryLayout<BHParams>.stride, index: 3)
        }
    }

    private func encodeKick(into buffer: MTLCommandBuffer) {
        var p = params
        encode(into: buffer, kick) { encoder in
            encoder.setBuffer(velocityBuffer, offset: 0, index: 0)
            encoder.setBuffer(accelerationBuffer, offset: 0, index: 1)
            encoder.setBytes(&p, length: MemoryLayout<BHParams>.stride, index: 2)
        }
    }

    /// The positions as the GPU left them. The CPU passes read them in place rather than from
    /// a copy: only the drift writes them, and it has landed before anything reads them.
    private var currentPositions: UnsafeBufferPointer<SIMD3<Float>> {
        UnsafeBufferPointer(
            start: positionBuffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: count),
            count: count)
    }

    /// Builds the tree from the drifted positions, with the halo centres and the disk frames
    /// that go with it, and gathers the particles for the force pass on the way.
    private func rebuildTree() {
        if profiling {
            timed("halo centres") { updateHaloCenters() }
            if dissipate != nil { timed("disk frames") { updateDiskFrames() } }
            repeat {
                for phase in GPUTreeBuilder.Phase.allCases {
                    profiledPass(phase.rawValue) {
                        builder.encode(
                            phase, into: $0, positions: positionBuffer, mass: massBuffer,
                            sorted: sortedBuffer)
                    }
                }
            } while grewAfterOverflow()
            profiler.update { $0.treeBuilds += 1 }
        } else if let buffer = queue.makeCommandBuffer() {
            builder.encode(
                into: buffer, positions: positionBuffer, mass: massBuffer, sorted: sortedBuffer)
            buffer.commit()
            // The centres read the positions the build is reading, so they are taken meanwhile.
            updateHaloCenters()
            if dissipate != nil { updateDiskFrames() }
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
        }
        gathered = true
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

    /// Each halo rides on the centre of mass of its own galaxy's particles, and so does the
    /// frame the dissipation pass cools towards: cooling in the wrong frame would drag two
    /// galaxies to a halt instead of letting them orbit.
    ///
    /// Summed in fixed blocks on every core, in double precision. The single running float sum
    /// this replaced was not exact enough to be worth matching: by the time a galaxy's total
    /// mass is tens of thousands of times one particle's, every addition rounds the same way,
    /// and at sixty thousand particles a galaxy the centre came out scaled by 1.0008, 23 pc off
    /// at 30 kpc. Fixed blocks added in order also make the answer the same on any machine.
    private func updateHaloCenters() {
        let galaxies = scene.galaxies.count
        guard galaxies > 0 else { return }
        let positions = currentPositions
        let velocities =
            dissipate == nil
            ? nil
            : velocityBuffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: count)
        let limit = min(count, galaxyOf.count)
        let block = 65_536
        let blocks = (limit + block - 1) / block
        // Three sums a galaxy a block: position and velocity weighted by mass, then the mass.
        var partial = [SIMD3<Double>](repeating: .zero, count: blocks * galaxies * 3)
        let halo = ParticleComponent.halo.rawValue
        galaxyOf.withUnsafeBufferPointer { galaxyOf in
            componentOf.withUnsafeBufferPointer { componentOf in
                particleMass.withUnsafeBufferPointer { mass in
                    partial.withUnsafeMutableBufferPointer { partial in
                        DispatchQueue.concurrentPerform(iterations: blocks) { index in
                            var weighted = [SIMD3<Double>](repeating: .zero, count: galaxies)
                            var drift = weighted
                            var totals = [Double](repeating: 0, count: galaxies)
                            for particle in index * block..<min((index + 1) * block, limit) {
                                let galaxy = Int(galaxyOf[particle])
                                guard galaxy < galaxies else { continue }
                                // Halo particles outnumber the disk, so including them would
                                // put the centre at the halo's centroid rather than at the
                                // visible galaxy's.
                                if particle < componentOf.count, componentOf[particle] == halo {
                                    continue
                                }
                                let m = Double(max(mass[particle], 1e-20))
                                weighted[galaxy] += SIMD3<Double>(positions[particle]) * m
                                if let velocities {
                                    drift[galaxy] += SIMD3<Double>(velocities[particle]) * m
                                }
                                totals[galaxy] += m
                            }
                            for galaxy in 0..<galaxies {
                                let base = (index * galaxies + galaxy) * 3
                                partial[base] = weighted[galaxy]
                                partial[base + 1] = drift[galaxy]
                                partial[base + 2] = SIMD3<Double>(repeating: totals[galaxy])
                            }
                        }
                    }
                }
            }
        }
        var weighted = [SIMD3<Double>](repeating: .zero, count: galaxies)
        var drift = weighted
        var totals = [Double](repeating: 0, count: galaxies)
        for index in 0..<blocks {
            for galaxy in 0..<galaxies {
                let base = (index * galaxies + galaxy) * 3
                weighted[galaxy] += partial[base]
                drift[galaxy] += partial[base + 1]
                totals[galaxy] += partial[base + 2].x
            }
        }
        var updated = centers
        for galaxy in updated.indices where totals[galaxy] > 0 {
            updated[galaxy] = SIMD3<Float>(weighted[galaxy] / totals[galaxy])
            if velocities != nil {
                galaxyMotion[galaxy] = SIMD3<Float>(drift[galaxy] / totals[galaxy])
            }
        }
        centersLock.lock()
        haloCenters = updated
        centersLock.unlock()
    }

    /// The plane each disk is actually turning in, and how much of it still turns that way.
    ///
    /// Cooling towards the orientation the galaxy was *set up* with is a spring back to the
    /// natal plane: a disk thrown out of it by an encounter gets pulled back into it, and
    /// re-thins, which is the one thing a collisionless system cannot do. Measured on a run
    /// of three galaxies, the inclined one heated from 0.24 kpc thick to 11.7 through
    /// pericentre and was back to 1.04 four hundred megayears later, still within five degrees
    /// of the plane it was born in and eighty-three from the remnant it was supposed to have
    /// joined. The axis is now the mass-weighted angular momentum of the galaxy's own disk
    /// material about its own moving centre, so it tumbles, precesses and warps with the disk
    /// instead of holding it.
    ///
    /// `coherence` is |sum m l| / sum m |l|: one where every star turns the same way, near
    /// zero for a spheroid whose angular momenta cancel. It is what says a disk has stopped
    /// being a disk.
    ///
    /// Fifty thousand particles a galaxy answer both questions. Walking millions of them on
    /// every tree rebuild would cost more than the cooling it feeds.
    private func updateDiskFrames() {
        let galaxies = scene.galaxies.count
        guard galaxies > 0 else { return }
        let positions = currentPositions
        let mass = particleMass
        var angular = [SIMD3<Double>](repeating: .zero, count: galaxies)
        var scalar = [Double](repeating: 0, count: galaxies)
        var height = [Double](repeating: 0, count: galaxies)
        var across = [Double](repeating: 0, count: galaxies)
        let velocities = velocityBuffer.contents().bindMemory(
            to: SIMD3<Float>.self, capacity: count)
        centersLock.lock()
        let plane = diskStates.map(\.axis)
        centersLock.unlock()
        let limit = min(count, min(galaxyOf.count, componentOf.count))
        let step = max(limit / (Self.frameSample * galaxies), 1)
        for index in Swift.stride(from: 0, to: limit, by: step) {
            let kind = componentOf[index]
            // The same material the cooling touches, so the frame is the frame of the thing
            // being cooled: no dark matter, no bulge, which has no plane to speak of, and no
            // thick halo either. The cooling excludes everything from `halo` upward and this
            // has to say the same thing — when the thick component was added to one and not
            // the other, a spheroid reaching past thirty kiloparsecs and turning at a third of
            // the circular speed was being counted as disk, and the ordered-rotation fraction
            // it is measured by came out of a mixture of two populations.
            if kind >= ParticleComponent.halo.rawValue { continue }
            let galaxy = Int(galaxyOf[index])
            guard galaxy < galaxies else { continue }
            let offset = SIMD3<Double>(positions[index] - haloCenters[galaxy])
            let motion = SIMD3<Double>(velocities[index] - galaxyMotion[galaxy])
            let weight = Double(max(mass[index], 1e-20))
            angular[galaxy] += simd_cross(offset, motion) * weight
            // Against m|r||v| rather than m|r x v|. The cross product is already blind to
            // radial motion, so normalising by its own magnitude asks only whether the
            // angular momenta point the same way and answers yes for a swarm of plunging
            // radial orbits. What is wanted is whether the material is rotationally
            // supported, and this is the ratio that says so.
            scalar[galaxy] += simd_length(offset) * simd_length(motion) * weight
            let z = simd_dot(offset, SIMD3<Double>(plane[galaxy]))
            height[galaxy] += z * z * weight
            across[galaxy] += simd_length_squared(offset) * weight
        }

        centersLock.lock()
        for galaxy in 0..<galaxies {
            // A globular has no ordered rotation to lose and is never cooled, so leaving its
            // state alone keeps the reading worth looking at rather than pinned at one.
            guard scene.galaxies[galaxy].kind != .globular else { continue }
            diskStates[galaxy].fold(
                momentum: angular[galaxy], scalar: scalar[galaxy],
                height: height[galaxy], across: across[galaxy])
        }
        centersLock.unlock()
    }

    /// How hard the nearest companion is working on a disk, as the disk's own radius over its
    /// tidal radius in that companion's field: r_t = d (M / 3 M_companion)^(1/3).
    ///
    /// Cooling stands in for gas sitting in a quiet cold layer and forming stars on circular
    /// orbits. During an encounter that gas is being shocked, driven inward and burned, so
    /// the stand-in has no business running: this is what takes the cooling off *while* the
    /// galaxies are passing through each other, which is when the disk is meant to be
    /// destroyed and when holding it together does the most damage. It comes back on if the
    /// two separate again without wrecking each other, which is what a distant fly-by is.
    ///
    /// Scale-free, so a small satellite passing close does not switch off a large disk's
    /// cooling the way an equal-mass companion does.
    private func tidalStress(on index: Int, centers: [SIMD3<Float>]) -> Float {
        let galaxy = scene.galaxies[index]
        // Three scale lengths holds about four fifths of an exponential disk's mass, so it is
        // the radius at which "the disk is inside its tidal radius" means the disk.
        let radius = max(galaxy.diskScaleLength * 3, 0.1)
        let mass = max(galaxy.potential.mass, 1e-6)
        var worst: Float = 0
        for other in scene.galaxies.indices where other != index {
            let companion = max(scene.galaxies[other].potential.mass, 1e-6)
            let separation = max(simd_distance(centers[index], centers[other]), 1e-3)
            let tidalRadius = separation * cbrt(mass / (3 * companion))
            worst = max(worst, radius / max(tidalRadius, 1e-3))
        }
        return worst
    }

    private static func smoothstep(_ low: Float, _ high: Float, _ x: Float) -> Float {
        guard high > low else { return x < low ? 0 : 1 }
        let t = min(max((x - low) / (high - low), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Particles are taken by Morton slot, so `pieces` is a range of slots.
    private func encodeAccelerations(into buffer: MTLCommandBuffer, pieces: Range<Int>? = nil) {
        var p = params
        var list = scene.galaxies.enumerated().map { index, galaxy -> HaloGPU in
            let center = index < haloCenters.count ? haloCenters[index] : galaxy.position
            let haloMass =
                galaxy.potential.mass * (1 - galaxy.diskMassFraction)
                * Physics.gravitationalConstant
            let point = SIMD4<Float>(center.x, center.y, center.z, 0)
            return HaloGPU(
                centerBefore: point, centerAfter: point,
                shape: SIMD4<Float>(
                    haloMass, galaxy.potential.scaleRadius,
                    galaxy.potential.profile == .plummer ? 0 : 1, 0))
        }
        if list.isEmpty { list = [HaloGPU(centerBefore: .zero, centerAfter: .zero, shape: .zero)] }

        // A reused tree still needs this step's positions in its order.
        if !gathered {
            encode(into: buffer, gather) { encoder in
                encoder.setBuffer(sortedBuffer, offset: 0, index: 0)
                encoder.setBuffer(positionBuffer, offset: 0, index: 1)
                encoder.setBuffer(massBuffer, offset: 0, index: 2)
                encoder.setBuffer(builder.order, offset: 0, index: 3)
                encoder.setBytes(&p, length: MemoryLayout<BHParams>.stride, index: 4)
            }
            gathered = true
        }
        let slots = pieces ?? 0..<count
        if slots.upperBound >= count { gathered = false }
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
            }
            start += span
        }
    }

    /// Total momentum. With live halos nothing external acts on the system, so this must be
    /// constant; a rigid halo that follows the disk makes it drift.
    public func momentum() -> SIMD3<Float> {
        let velocities = velocityBuffer.contents().bindMemory(
            to: SIMD3<Float>.self, capacity: count)
        let masses = massBuffer.contents().bindMemory(to: Float.self, capacity: count)
        var total = SIMD3<Float>.zero
        for index in 0..<count { total += velocities[index] * masses[index] }
        return total
    }

    /// What each traversal cost, in node evaluations, by Morton slot.
    public var traversalCosts: [UInt32] {
        Array(
            UnsafeBufferPointer(
                start: costBuffer.contents().bindMemory(to: UInt32.self, capacity: count),
                count: count))
    }

    /// Accelerations as computed by the GPU, for validation against direct summation.
    public var accelerations: [SIMD3<Float>] {
        Array(
            UnsafeBufferPointer(
                start: accelerationBuffer.contents().bindMemory(
                    to: SIMD3<Float>.self, capacity: count), count: count))
    }
}
