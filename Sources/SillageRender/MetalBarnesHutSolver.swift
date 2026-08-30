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

    private let positionBuffer: MTLBuffer
    private let velocityBuffer: MTLBuffer
    private let accelerationBuffer: MTLBuffer
    private let massBuffer: MTLBuffer
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
    private var haloCenters: [SIMD3<Float>]
    private var galaxyMotion: [SIMD3<Float>]
    private let centersLock = NSLock()

    public var positions: MTLBuffer { positionBuffer }
    /// Written on whichever queue is stepping and read by the renderer on the main thread,
    /// so the array is handed over under a lock rather than copied out from under the write.
    public var centers: [SIMD3<Float>] {
        centersLock.lock()
        defer { centersLock.unlock() }
        return haloCenters
    }

    public var particles: ParticleSystem {
        var system = template
        let p = positionBuffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: count)
        let v = velocityBuffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: count)
        system.positions = Array(UnsafeBufferPointer(start: p, count: count))
        system.velocities = Array(UnsafeBufferPointer(start: v, count: count))
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
        self.scratchPositions = [SIMD3<Float>](repeating: .zero, count: self.count)
        var masses = particles.mass
        if masses.count != self.count {
            masses = [Float](repeating: 0, count: self.count)
        }
        self.particleMass = masses

        var stripped = particles
        stripped.positions = []
        stripped.velocities = []
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
                length: count * 4, options: .storageModeShared)
        else {
            throw RenderError.textureAllocation
        }
        self.positionBuffer = positionBuffer
        self.velocityBuffer = velocityBuffer
        self.accelerationBuffer = accelerationBuffer
        self.massBuffer = massBuffer

        // Only the dissipation pass needs to know what a particle is and whose it is.
        if dissipate != nil {
            func attribute(_ values: [UInt32], _ fallback: UInt32) -> [UInt32] {
                values.count == count ? values : [UInt32](repeating: fallback, count: count)
            }
            componentBuffer = device.makeBuffer(
                bytes: attribute(particles.component, 0), length: count * 4,
                options: .storageModeShared)
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
                let clock = Date()
                submit(forces)
                lastForceMilliseconds = Date().timeIntervalSince(clock) * 1000
            }
            time += scene.timeStep
        }
    }

    /// Pulls the disk back towards circular orbits, standing in for the gas that a real disk
    /// cools through. Runs after the kick so the accelerations it reads are this step's.
    private func encodeShedRandomMotion(into buffer: MTLCommandBuffer) {
        guard let dissipate else { return }
        let elapsed = scene.timeStep * Float(Physics.megayearsPerTimeUnit)
        var disks = scene.galaxies.enumerated().map { index, galaxy -> DiskCoolingGPU in
            let centre = index < haloCenters.count ? haloCenters[index] : galaxy.position
            let motion = index < galaxyMotion.count ? galaxyMotion[index] : galaxy.velocity
            let axis = galaxy.orientation * SIMD3<Float>(0, 0, 1)
            // The share of the gap to circular closed this step, from the time constant.
            let damping =
                galaxy.dissipationTime > 0 && galaxy.kind != .globular
                ? 1 - exp(-elapsed / galaxy.dissipationTime) : 0
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
                axis: SIMD4<Float>(axis.x, axis.y, axis.z, galaxy.spin.sign),
                // Generous on purpose. Halo and bulge are already excluded by component, so
                // the only thing these limits keep out is material genuinely thrown clear —
                // a tidal tail, not a disk star that has been heated. Cutting in at a few
                // scale heights did the opposite: it stopped cooling the stars that had
                // picked up the most motion, and the disk heated almost as fast as with no
                // dissipation at all.
                reach: SIMD4<Float>(edge * 5, edge * 9, edge, edge * 2))
        }
        if disks.isEmpty { return }

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
