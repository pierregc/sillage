import Metal
import SillageCore
import simd

struct GalaxyGPU {
    var centerBefore: SIMD3<Float>
    var centerAfter: SIMD3<Float>
    var mass: Float
    var scaleRadius: Float
    var profile: UInt32
    var pad: UInt32 = 0
}

struct IntegrateParams {
    var particleCount: UInt32
    var galaxyCount: UInt32
    var timeStep: Float
    var pad: Float = 0
}

/// Level 1 solver running entirely on the GPU. Particle state lives in Metal buffers that the
/// renderer binds directly, so positions never travel across the bus. The galaxy centres stay
/// on the CPU in double precision: there are only a handful and they set the encounter geometry.
public final class MetalSolver: Solver {
    public let kind: SolverKind = .restricted
    public let scene: SceneConfig
    public private(set) var time: Float = 0
    public let device: MTLDevice

    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let positionBuffer: MTLBuffer
    private let formationBuffer: MTLBuffer
    private let velocityBuffer: MTLBuffer
    private var galaxyCenters: GalaxyCenters
    private let centersLock = NSLock()
    private let template: ParticleSystem
    private let count: Int

    public var positions: MTLBuffer { positionBuffer }
    public var formation: MTLBuffer { formationBuffer }
    /// Advanced by whichever queue is stepping, read by the renderer on the main thread.
    public var centers: [SIMD3<Float>] {
        centersLock.lock()
        defer { centersLock.unlock() }
        return galaxyCenters.float
    }

    /// Reads particle state back from the GPU. Unified memory makes this a memcpy, but it is
    /// still per-particle work, so callers should not do it every frame.
    public var particles: ParticleSystem {
        var system = template
        let positions = positionBuffer.contents().bindMemory(
            to: SIMD3<Float>.self, capacity: count)
        let velocities = velocityBuffer.contents().bindMemory(
            to: SIMD3<Float>.self, capacity: count)
        system.positions = Array(UnsafeBufferPointer(start: positions, count: count))
        system.velocities = Array(UnsafeBufferPointer(start: velocities, count: count))
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
        self.galaxyCenters = GalaxyCenters(scene: scene)

        var stripped = particles
        stripped.positions = []
        stripped.velocities = []
        self.template = stripped

        let library: MTLLibrary
        do {
            library = try ShaderCache.library(SolverShaders.source, on: device)
        } catch {
            throw RenderError.shaderCompilation("\(error)")
        }
        guard let function = library.makeFunction(name: "integrate") else {
            throw RenderError.pipelineCreation("missing kernel integrate")
        }
        do {
            pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            throw RenderError.pipelineCreation("integrate: \(error)")
        }

        guard let queue = device.makeCommandQueue() else { throw RenderError.noDevice }
        self.queue = queue

        let stride = MemoryLayout<SIMD3<Float>>.stride
        guard
            let positionBuffer = device.makeBuffer(
                length: count * stride, options: .storageModeShared),
            let velocityBuffer = device.makeBuffer(
                length: count * stride, options: .storageModeShared),
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
        self.formationBuffer = formationBuffer

        if !particles.positions.isEmpty {
            particles.positions.withUnsafeBytes {
                positionBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count)
            }
            particles.velocities.withUnsafeBytes {
                velocityBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count)
            }
        }
    }

    public func step() { step(count: 1) }

    /// Encodes several steps into one command buffer, which keeps the GPU busy instead of
    /// paying a submission round trip per step. Galaxy centres go through `setBytes` rather
    /// than a shared buffer: `setBytes` copies at encode time, so each dispatch sees the
    /// centres belonging to its own step.
    public func step(count stepCount: Int) {
        guard stepCount > 0, let buffer = queue.makeCommandBuffer(),
            let encoder = buffer.makeComputeCommandEncoder()
        else { return }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(positionBuffer, offset: 0, index: 0)
        encoder.setBuffer(velocityBuffer, offset: 0, index: 1)

        let threadWidth = pipeline.maxTotalThreadsPerThreadgroup
        var params = IntegrateParams(
            particleCount: UInt32(count),
            galaxyCount: UInt32(scene.galaxies.count),
            timeStep: scene.timeStep)
        encoder.setBytes(&params, length: MemoryLayout<IntegrateParams>.stride, index: 3)

        var descriptors = scene.galaxies.map { galaxy in
            GalaxyGPU(
                centerBefore: .zero, centerAfter: .zero,
                mass: galaxy.potential.mass * Physics.gravitationalConstant,
                scaleRadius: galaxy.potential.scaleRadius,
                profile: galaxy.potential.profile == .plummer ? 0 : 1)
        }

        for _ in 0..<stepCount {
            centersLock.lock()
            let (before, after) = galaxyCenters.step(timeStep: Double(scene.timeStep))
            centersLock.unlock()
            for index in descriptors.indices {
                descriptors[index].centerBefore = before[index]
                descriptors[index].centerAfter = after[index]
            }
            encoder.setBytes(
                descriptors, length: descriptors.count * MemoryLayout<GalaxyGPU>.stride, index: 2)
            encoder.dispatchThreads(
                MTLSize(width: count, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: threadWidth, height: 1, depth: 1))
            time += scene.timeStep
        }

        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
    }

    public func centerEnergy() -> Double { galaxyCenters.energy() }
    public func centerMomentum() -> SIMD3<Double> { galaxyCenters.momentum() }
}

/// A solver whose particle state already lives in a Metal buffer, so the renderer can bind it
/// directly instead of uploading a copy every frame.
///
/// Marked `Sendable` without checking because recording steps the solver on a background
/// queue while the renderer reads its position buffer on the main one. Only the recording
/// queue ever mutates the solver, and a renderer that catches particles mid-update draws a
/// frame a fraction of a step stale, which is invisible in a point cloud.
public protocol GPUSolver: Solver, Sendable {
    var positions: MTLBuffer { get }
    /// When each particle's stars formed. Fixed for a tracer run, which has no gas rule and
    /// no way to compress anything; written as the run goes for a self-gravitating one.
    var formation: MTLBuffer { get }
}

extension MetalSolver: GPUSolver, @unchecked Sendable {}
extension MetalBarnesHutSolver: GPUSolver, @unchecked Sendable {}

public enum GPUSolverFactory {
    public static func make(
        device: MTLDevice? = nil, scene: SceneConfig, particles: ParticleSystem
    ) throws -> any GPUSolver {
        switch scene.solver {
        case .restricted:
            return try MetalSolver(device: device, scene: scene, particles: particles)
        case .barnesHut:
            return try MetalBarnesHutSolver(device: device, scene: scene, particles: particles)
        }
    }
}
