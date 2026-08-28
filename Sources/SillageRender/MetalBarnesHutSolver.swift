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

struct BHParams {
    var particleCount: UInt32
    var haloCount: UInt32
    var timeStep: Float
    var openingAngleSquared: Float
    var softeningSquared: Float
    var gravitationalConstant: Float
    var pad0: Float = 0
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

    public private(set) var lastBuildMilliseconds = 0.0
    public private(set) var lastForceMilliseconds = 0.0
    public private(set) var nodeCount = 0

    private let queue: MTLCommandQueue
    private let kickDrift: MTLComputePipelineState
    private let kick: MTLComputePipelineState
    private let force: MTLComputePipelineState

    private let positionBuffer: MTLBuffer
    private let velocityBuffer: MTLBuffer
    private let accelerationBuffer: MTLBuffer
    private let massBuffer: MTLBuffer
    private var nodeBuffer: MTLBuffer?
    private var orderBuffer: MTLBuffer?

    private let tree = BarnesHutTree()
    private let template: ParticleSystem
    private let count: Int
    private let galaxyOf: [UInt32]
    private let componentOf: [UInt32]
    private let liveHalos: Bool
    private var haloCenters: [SIMD3<Float>]
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

        var stripped = particles
        stripped.positions = []
        stripped.velocities = []
        self.template = stripped

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: BarnesHutShaders.source, options: nil)
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
        computeAccelerations()
    }

    public func step() { step(count: 1) }

    public func step(count steps: Int) {
        for _ in 0..<max(steps, 0) {
            integrate()
            rebuildTree()
            computeAccelerations()
            applyKick()
            time += scene.timeStep
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

    private func dispatch(
        _ pipeline: MTLComputePipelineState, _ configure: (MTLComputeCommandEncoder) -> Void
    ) {
        guard let buffer = queue.makeCommandBuffer(),
            let encoder = buffer.makeComputeCommandEncoder()
        else { return }
        encoder.setComputePipelineState(pipeline)
        configure(encoder)
        encoder.dispatchThreads(
            MTLSize(width: count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: pipeline.maxTotalThreadsPerThreadgroup, height: 1, depth: 1))
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
    }

    private func integrate() {
        var p = params
        dispatch(kickDrift) { encoder in
            encoder.setBuffer(positionBuffer, offset: 0, index: 0)
            encoder.setBuffer(velocityBuffer, offset: 0, index: 1)
            encoder.setBuffer(accelerationBuffer, offset: 0, index: 2)
            encoder.setBytes(&p, length: MemoryLayout<BHParams>.stride, index: 3)
        }
    }

    private func applyKick() {
        var p = params
        dispatch(kick) { encoder in
            encoder.setBuffer(velocityBuffer, offset: 0, index: 0)
            encoder.setBuffer(accelerationBuffer, offset: 0, index: 1)
            encoder.setBytes(&p, length: MemoryLayout<BHParams>.stride, index: 2)
        }
    }

    /// Reads positions straight out of the shared buffer, so the build costs no transfer.
    private func rebuildTree() {
        let clock = Date()
        let pointer = positionBuffer.contents().bindMemory(to: SIMD3<Float>.self, capacity: count)
        let positions = Array(UnsafeBufferPointer(start: pointer, count: count))
        let mass = Array(
            UnsafeBufferPointer(
                start: massBuffer.contents().bindMemory(to: Float.self, capacity: count),
                count: count))

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

    /// Each halo rides on the centre of mass of its own galaxy's particles.
    private func updateHaloCenters(positions: [SIMD3<Float>], mass: [Float]) {
        var weighted = [SIMD3<Float>](repeating: .zero, count: scene.galaxies.count)
        var totals = [Float](repeating: 0, count: scene.galaxies.count)
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
            totals[galaxy] += m
        }
        var updated = centers
        for galaxy in updated.indices where totals[galaxy] > 0 {
            updated[galaxy] = weighted[galaxy] / totals[galaxy]
        }
        centersLock.lock()
        haloCenters = updated
        centersLock.unlock()
    }

    private func computeAccelerations() {
        let clock = Date()
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

        dispatch(force) { encoder in
            encoder.setBuffer(positionBuffer, offset: 0, index: 0)
            encoder.setBuffer(accelerationBuffer, offset: 0, index: 1)
            encoder.setBuffer(nodeBuffer, offset: 0, index: 2)
            encoder.setBuffer(orderBuffer, offset: 0, index: 3)
            encoder.setBuffer(massBuffer, offset: 0, index: 4)
            encoder.setBytes(list, length: list.count * MemoryLayout<HaloGPU>.stride, index: 5)
            encoder.setBytes(&p, length: MemoryLayout<BHParams>.stride, index: 6)
        }
        lastForceMilliseconds = Date().timeIntervalSince(clock) * 1000
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
