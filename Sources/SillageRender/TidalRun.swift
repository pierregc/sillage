import Foundation
import Metal
import SillageCore

/// What `holeStep` reads; mirrors `HoleStepParams` in `HoleShaders`.
struct HoleStepParams {
    var count: UInt32
    var timeStep: Float
    var swallow: Float
    var subStepAngle: Float
    var maximumSubSteps: UInt32
    var gridRadii: UInt32
    var gridAngles: UInt32
    var gridHeights: UInt32
    var logInner: Float
    var logScale: Float
    var heightCell: Float
    var stickiness: Float
    var crossing: Float
    var viscosity: Float
    var cooling: Float
}

/// The grid of the mean flow the gas is made of: cells in log r by angle by height over the
/// radius, as tall as wide. One layer is the spike's (#314), where a stream squeezed through the
/// plane counts as streams crossing.
public struct GasGrid: Sendable, Equatable {
    public var radii = 192
    public var angles = 384
    public var heights = 32
    /// How tall a cell is, over its distance from the axis.
    public var heightCell: Float = 1.0 / 64
    public var outer: Float = 200

    public init() {}

    var cells: Int { radii * angles * heights }
}

/// A `TidalDisruption` stepped on the GPU (#314). The tracers are those of `RestrictedSolver`,
/// massless in a rigid potential, and the gas is a grid of the mean flow they deposit each step,
/// that the step pulls them towards where streams cross.
public final class TidalRun {
    public let scene: TidalDisruption
    public let device: MTLDevice
    public let releaseTime: Double
    /// Steps taken since the release.
    public private(set) var stepsTaken = 0
    public var time: Double { releaseTime + Double(stepsTaken) * Double(scene.timeStep) }

    public let gas: GasGrid
    let positions: MTLBuffer
    let velocities: MTLBuffer
    private let fixed: MTLBuffer
    private let grid: MTLBuffer
    private let column: MTLBuffer
    private let queue: MTLCommandQueue
    private let clear: MTLComputePipelineState
    private let deposit: MTLComputePipelineState
    private let resolve: MTLComputePipelineState
    private let sum: MTLComputePipelineState
    private let advance: MTLComputePipelineState
    private let count: Int

    public init(scene: TidalDisruption, gas: GasGrid = GasGrid(), device: MTLDevice? = nil) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else { throw RenderError.noDevice }
        self.scene = scene
        self.gas = gas
        self.device = device
        let library = try HoleKernels.library(on: device)
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw RenderError.pipelineCreation("missing kernel \(name)")
            }
            return try device.makeComputePipelineState(function: function)
        }
        clear = try pipeline("holeClear")
        deposit = try pipeline("holeDeposit")
        resolve = try pipeline("holeResolve")
        sum = try pipeline("holeColumn")
        advance = try pipeline("holeStep")
        guard let queue = device.makeCommandQueue() else { throw RenderError.noDevice }
        self.queue = queue

        let released = scene.released()
        releaseTime = released.time
        count = released.positions.count
        let starts = released.positions.map { SIMD4<Float>($0, 0) }
        let velocity = SIMD4<Float>(released.velocity, 0)
        let length = max(count, 1) * MemoryLayout<SIMD4<Float>>.stride
        guard
            let positions = device.makeBuffer(bytes: starts, length: length, options: .storageModeShared),
            let velocities = device.makeBuffer(
                bytes: [SIMD4<Float>](repeating: velocity, count: max(count, 1)), length: length,
                options: .storageModeShared),
            let fixed = device.makeBuffer(length: gas.cells * 32, options: .storageModePrivate),
            let grid = device.makeBuffer(length: gas.cells * 16, options: .storageModePrivate),
            let column = device.makeBuffer(
                length: gas.radii * gas.angles * 4, options: .storageModePrivate)
        else { throw RenderError.textureAllocation }
        self.fixed = fixed
        self.positions = positions
        self.velocities = velocities
        self.grid = grid
        self.column = column
    }

    var parameters: HoleStepParams {
        let inner = log(scene.swallow)
        return HoleStepParams(
            count: UInt32(count), timeStep: scene.timeStep, swallow: scene.swallow,
            subStepAngle: TidalDisruption.subStepAngle,
            maximumSubSteps: UInt32(TidalDisruption.maximumSubSteps),
            gridRadii: UInt32(gas.radii), gridAngles: UInt32(gas.angles),
            gridHeights: UInt32(gas.heights), logInner: inner,
            logScale: Float(gas.radii) / (log(gas.outer) - inner), heightCell: gas.heightCell,
            stickiness: scene.stickiness, crossing: scene.crossingSpeed,
            viscosity: scene.viscousOrbits > 0 ? 1 / scene.viscousOrbits : 0,
            cooling: scene.coolingTime)
    }

    /// `steps` steps of the scene's time step, in one command buffer.
    public func step(_ steps: Int) {
        guard steps > 0, let buffer = queue.makeCommandBuffer(),
            let encoder = buffer.makeComputeCommandEncoder()
        else { return }
        var parameters = self.parameters
        var cells = UInt32(gas.cells)
        func dispatch(_ pipeline: MTLComputePipelineState, _ threads: Int) {
            encoder.setComputePipelineState(pipeline)
            encoder.dispatchThreads(
                MTLSize(width: threads, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(
                    width: min(pipeline.maxTotalThreadsPerThreadgroup, 256), height: 1, depth: 1))
        }
        encoder.setBuffer(positions, offset: 0, index: 0)
        encoder.setBuffer(velocities, offset: 0, index: 1)
        for _ in 0..<steps {
            encoder.setBuffer(fixed, offset: 0, index: 0)
            encoder.setBytes(&cells, length: 4, index: 1)
            dispatch(clear, 2 * Int(cells))
            encoder.setBuffer(positions, offset: 0, index: 0)
            encoder.setBuffer(velocities, offset: 0, index: 1)
            encoder.setBuffer(fixed, offset: 0, index: 2)
            encoder.setBytes(&parameters, length: MemoryLayout<HoleStepParams>.stride, index: 3)
            dispatch(deposit, count)
            encoder.setBuffer(fixed, offset: 0, index: 0)
            encoder.setBuffer(grid, offset: 0, index: 1)
            encoder.setBytes(&cells, length: 4, index: 2)
            dispatch(resolve, Int(cells))
            encoder.setBuffer(grid, offset: 0, index: 0)
            encoder.setBuffer(column, offset: 0, index: 1)
            encoder.setBytes(&parameters, length: MemoryLayout<HoleStepParams>.stride, index: 2)
            dispatch(sum, gas.radii * gas.angles)
            encoder.setBuffer(positions, offset: 0, index: 0)
            encoder.setBuffer(velocities, offset: 0, index: 1)
            encoder.setBuffer(grid, offset: 0, index: 2)
            encoder.setBytes(&parameters, length: MemoryLayout<HoleStepParams>.stride, index: 3)
            encoder.setBuffer(column, offset: 0, index: 4)
            dispatch(advance, count)
        }
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        stepsTaken += steps
    }

    /// Goes on from a frame of a take of the same scene, `step` steps after the release.
    func resume(from frame: TidalFrame, step: Int) {
        precondition(frame.count == count, "a frame of another scene")
        frame.positions.withUnsafeBytes {
            positions.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count)
        }
        frame.velocities.withUnsafeBytes {
            velocities.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count)
        }
        stepsTaken = step
    }

    /// The yardstick of #334 on the cloud as it stands now, to read later moments by.
    public func measure() -> TidalMeasure {
        let p = positions.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        let v = velocities.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        return TidalMeasure(
            scene: scene, positions: UnsafeBufferPointer(start: p, count: count),
            velocities: UnsafeBufferPointer(start: v, count: count))
    }

    /// One moment, read straight from the buffers.
    public func row(_ measure: TidalMeasure) -> TidalMeasure.Row {
        let p = positions.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        let v = velocities.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        return measure.row(
            time: time, positions: UnsafeBufferPointer(start: p, count: count),
            velocities: UnsafeBufferPointer(start: v, count: count), stride: max(count / 300_000, 1))
    }

    public var frame: TidalFrame {
        let p = positions.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        let v = velocities.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        return TidalFrame(
            time: time, positions: Array(UnsafeBufferPointer(start: p, count: count)),
            velocities: Array(UnsafeBufferPointer(start: v, count: count)))
    }
}

/// The library the hole's kernels and splat live in: `HoleShaders` after `Shaders`, whose black
/// body and post stages they share.
enum HoleKernels {
    static func library(on device: MTLDevice) throws -> MTLLibrary {
        do {
            return try ShaderCache.library(Shaders.source + HoleShaders.source, on: device)
        } catch {
            throw RenderError.shaderCompilation("\(error)")
        }
    }
}
