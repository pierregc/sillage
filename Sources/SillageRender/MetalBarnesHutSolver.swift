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
    public private(set) var lastBuildMilliseconds = 0.0
    public private(set) var lastForceMilliseconds = 0.0
    public private(set) var nodeCount = 0

    private let queue: MTLCommandQueue
    private let kickDrift: MTLComputePipelineState
    private let kick: MTLComputePipelineState
    private let force: MTLComputePipelineState
    private let dissipate: MTLComputePipelineState?
    private let formStars: MTLComputePipelineState

    private let positionBuffer: MTLBuffer
    private let velocityBuffer: MTLBuffer
    private let accelerationBuffer: MTLBuffer
    private let massBuffer: MTLBuffer
    /// When each particle's stars formed. Written by the solver, read by the renderer, and
    /// the one per-particle attribute that is not fixed for the life of a run.
    public let formationBuffer: MTLBuffer
    private var nodeBuffer: MTLBuffer?
    private var orderBuffer: MTLBuffer?
    private var componentBuffer: MTLBuffer?
    private var galaxyBuffer: MTLBuffer?

    private let tree = BarnesHutTree(
        leafCapacity: MetalBarnesHutSolver.leafCapacity,
        maximumDepth: MetalBarnesHutSolver.maximumTreeDepth)
    /// Reused across steps. Masses never change, so they are read once.
    private var scratchPositions: [SIMD3<Float>]
    private let particleMass: [Float]
    private let template: ParticleSystem
    private let count: Int
    private let galaxyOf: [UInt32]
    private let componentOf: [UInt32]
    private let liveHalos: Bool
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

    public init(device: MTLDevice? = nil, scene: SceneConfig, particles: ParticleSystem) throws {
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
        self.haloCenters = scene.galaxies.map(\.position)
        self.galaxyMotion = scene.galaxies.map(\.velocity)
        self.diskStates = DiskState.natal(scene)
        self.scratchPositions = [SIMD3<Float>](repeating: .zero, count: self.count)
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
        force = try pipeline("bhAcceleration")
        dissipate =
            scene.galaxies.contains { $0.dissipationTime > 0 }
            ? try pipeline("bhDissipate") : nil
        formStars = try pipeline("bhFormStars")

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
        self.formationBuffer = formationBuffer

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
            // Two submissions rather than five. The tree is built on the CPU from the drifted
            // positions, so the drift has to have landed before it runs; everything after it
            // goes in one buffer, where the encoders are ordered against each other anyway.
            var clock = Date()
            if let drift = queue.makeCommandBuffer() {
                encodeIntegrate(into: drift)
                submit(drift)
            }
            lastDriftMilliseconds = Date().timeIntervalSince(clock) * 1000
            clock = Date()
            if stepsSinceTree <= 0 {
                rebuildTree()
                stepsSinceTree = max(Self.treeReuse, 1)
            }
            stepsSinceTree -= 1
            lastTreeMilliseconds = Date().timeIntervalSince(clock) * 1000
            if let forces = queue.makeCommandBuffer() {
                encodeAccelerations(into: forces)
                encodeKick(into: forces)
                encodeShedRandomMotion(into: forces)
                encodeStarFormation(into: forces)
                let clock = Date()
                submit(forces)
                lastForceMilliseconds = Date().timeIntervalSince(clock) * 1000
            }
            time += scene.timeStep
        }
    }

    /// Turns gas into stars where the tree says it has been compressed.
    ///
    /// Dispatched over nodes rather than particles: the density estimate lives on the leaves,
    /// and a leaf holds at most `leafCapacity` of them, so one thread does the reading and the
    /// drawing for all of its own. Nothing here is read back — the buffer it writes is the one
    /// the renderer draws from.
    private func encodeStarFormation(into buffer: MTLCommandBuffer) {
        guard nodeCount > 0, let nodeBuffer, let orderBuffer, componentBuffer != nil else {
            return
        }
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
            encoder.setBuffer(nodeBuffer, offset: 0, index: 3)
            encoder.setBuffer(orderBuffer, offset: 0, index: 4)
            encoder.setBytes(
                &params, length: MemoryLayout<StarFormationGPU>.stride, index: 5)
            encoder.setBuffer(positionBuffer, offset: 0, index: 6)
            encoder.setBuffer(velocityBuffer, offset: 0, index: 7)
        }
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
        _ configure: (MTLComputeCommandEncoder) -> Void
    ) {
        guard let encoder = buffer.makeComputeCommandEncoder() else { return }
        encoder.setComputePipelineState(pipeline)
        configure(encoder)
        encoder.dispatchThreads(
            MTLSize(width: threads ?? count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: pipeline.maxTotalThreadsPerThreadgroup, height: 1, depth: 1))
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

    private func submit(_ buffer: MTLCommandBuffer) {
        let clock = Date()
        buffer.commit()
        buffer.waitUntilCompleted()
        longestDispatchMilliseconds = max(
            longestDispatchMilliseconds, Date().timeIntervalSince(clock) * 1000)
    }

    /// Particles per force dispatch. A whole large scene in one kernel keeps the GPU to
    /// itself long enough that the pointer stutters; in pieces the display gets in between.
    public static var forceChunk = 1_000_000

    /// Particles a leaf may hold before it splits. Bigger leaves mean far fewer nodes and a
    /// much cheaper build — the node split is serial and it is what a concentrated scene makes
    /// expensive — at the cost of more direct summation in the force pass. That trade only
    /// became worth taking once leaves started respecting the opening criterion, since a
    /// distant leaf now costs one evaluation whatever it holds.
    public static var leafCapacity = 16

    /// How deep the tree may go. A merged core subdivides to the ceiling and the node split
    /// is serial, so this is most of what a build costs on a concentrated scene. Twenty is
    /// right when accuracy matters; thirteen puts the smallest cell at a few tens of parsecs,
    /// far below any softening length used here, and builds far faster.
    public static var maximumTreeDepth = 20

    /// Steps a tree is reused for. The build is most of what a step costs, and what decides
    /// whether motion looks continuous is how *often* positions change, not how far they move
    /// each time: a few large steps a second make the galaxies jump while the starfield, which
    /// only follows the camera, glides. Reusing the tree buys the step rate that fixes that,
    /// and costs nothing at these step sizes — a particle crosses a fraction of a leaf cell
    /// in the interval, which is well inside what the opening angle already approximates.
    public static var treeReuse = 1

    /// Particles a galaxy contributes to its own disk frame. The axis and the coherence are
    /// mass-weighted sums over a hundred thousand-odd stars; fifty thousand of them give the
    /// same answer, and this runs on every tree rebuild.
    public static var frameSample = 50_000

    /// Where a companion stops leaving the disk alone, as the disk's radius over its tidal
    /// radius. Below the floor the disk sits well inside the tidal radius and its gas is
    /// undisturbed; past the ceiling the companion is cutting into the disk itself.
    public static var tidalFloor: Float = 0.7
    public static var tidalCeiling: Float = 1.4

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

    /// Reads positions straight out of the shared buffer, so the build costs no transfer.
    private func rebuildTree() {
        let clock = Date()
        let pointer = positionBuffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: count)
        // Copied into storage that lives as long as the solver: a fresh array here allocated
        // and freed sixteen megabytes every step, at a hundred steps a second.
        scratchPositions.withUnsafeMutableBufferPointer { destination in
            destination.baseAddress!.update(from: pointer, count: count)
        }
        let positions = scratchPositions
        let mass = particleMass

        tree.build(positions: positions, mass: mass)
        nodeCount = tree.nodes.count
        updateHaloCenters(positions: positions, mass: mass)
        if dissipate != nil { updateDiskFrames(positions: positions, mass: mass) }

        let nodeLength = max(tree.nodes.count, 1) * MemoryLayout<BHNode>.stride
        if nodeBuffer == nil || nodeBuffer!.length < nodeLength {
            nodeBuffer = device.makeBuffer(length: nodeLength * 2, options: .storageModeShared)
        }
        if !tree.nodes.isEmpty {
            tree.nodes.withUnsafeBytes {
                nodeBuffer?.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count)
            }
        }
        let orderLength = max(tree.order.count, 1) * 4
        if orderBuffer == nil || orderBuffer!.length < orderLength {
            orderBuffer = device.makeBuffer(length: orderLength * 2, options: .storageModeShared)
        }
        if !tree.order.isEmpty {
            tree.order.withUnsafeBytes {
                orderBuffer?.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count)
            }
        }
        lastBuildMilliseconds = Date().timeIntervalSince(clock) * 1000
    }

    /// Each halo rides on the centre of mass of its own galaxy's particles, and so does the
    /// frame the dissipation pass cools towards: cooling in the wrong frame would drag two
    /// galaxies to a halt instead of letting them orbit.
    private func updateHaloCenters(positions: [SIMD3<Float>], mass: [Float]) {
        var weighted = [SIMD3<Float>](repeating: .zero, count: scene.galaxies.count)
        var drift = [SIMD3<Float>](repeating: .zero, count: scene.galaxies.count)
        var totals = [Float](repeating: 0, count: scene.galaxies.count)
        let velocities =
            dissipate == nil
            ? nil
            : velocityBuffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: count)
        // Halo particles outnumber the disk, so including them would put the centre at the
        // halo's centroid rather than at the visible galaxy's.
        for index in 0..<min(count, galaxyOf.count) {
            let galaxy = Int(galaxyOf[index])
            guard galaxy < totals.count else { continue }
            if index < componentOf.count,
                componentOf[index] == ParticleComponent.halo.rawValue
            {
                continue
            }
            let m = max(mass[index], 1e-20)
            weighted[galaxy] += positions[index] * m
            if let velocities { drift[galaxy] += velocities[index] * m }
            totals[galaxy] += m
        }
        var updated = centers
        for galaxy in updated.indices where totals[galaxy] > 0 {
            updated[galaxy] = weighted[galaxy] / totals[galaxy]
            if velocities != nil { galaxyMotion[galaxy] = drift[galaxy] / totals[galaxy] }
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
    private func updateDiskFrames(positions: [SIMD3<Float>], mass: [Float]) {
        let galaxies = scene.galaxies.count
        guard galaxies > 0 else { return }
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
            // being cooled: no dark matter, and no bulge, which has no plane to speak of.
            let dark = kind == ParticleComponent.halo.rawValue
            if dark || kind == ParticleComponent.bulge.rawValue { continue }
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

    private func encodeAccelerations(into buffer: MTLCommandBuffer) {
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

        var start = 0
        while start < count {
            let span = min(max(Self.forceChunk, 1), count - start)
            p.chunkStart = UInt32(start)
            encode(into: buffer, force, threads: span) { encoder in
                encoder.setBuffer(positionBuffer, offset: 0, index: 0)
                encoder.setBuffer(accelerationBuffer, offset: 0, index: 1)
                encoder.setBuffer(nodeBuffer, offset: 0, index: 2)
                encoder.setBuffer(orderBuffer, offset: 0, index: 3)
                encoder.setBuffer(massBuffer, offset: 0, index: 4)
                encoder.setBytes(list, length: list.count * MemoryLayout<HaloGPU>.stride, index: 5)
                encoder.setBytes(&p, length: MemoryLayout<BHParams>.stride, index: 6)
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

    /// Accelerations as computed by the GPU, for validation against direct summation.
    public var accelerations: [SIMD3<Float>] {
        Array(
            UnsafeBufferPointer(
                start: accelerationBuffer.contents().bindMemory(
                    to: SIMD3<Float>.self, capacity: count), count: count))
    }
}
