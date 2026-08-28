import Foundation
import Metal
import SillageCore
import simd

/// A run captured into memory, one quantised snapshot at a time.
///
/// Self-gravity costs hundreds of milliseconds per step, so tying the display to it turns the
/// whole interface into a slideshow. Recording separates the two: the simulation advances at
/// whatever pace it can while the viewer plays back from memory at the display rate, with
/// scrubbing and no loss of physical accuracy.
///
/// Positions are stored as three 16-bit fixed-point values inside each snapshot's own
/// bounding box. Over a 200 kpc box that resolves 0.003 kpc, far below the force softening,
/// so nothing visible is lost for six bytes a particle instead of twelve.
public final class Recording: @unchecked Sendable {
    public struct Frame: Sendable {
        public var time: Float
        /// Box origin in xyz, and the extent that maps onto the full 16-bit range in w.
        public var origin: SIMD3<Float>
        public var extent: Float
    }

    public let particleCount: Int
    private var storedFrames: [Frame] = []
    private var storage: [UInt16] = []
    /// A run captures on the simulation queue and is read back on the main actor. The two
    /// overlap by exactly one batch when a capture is stopped, which is enough to be reading
    /// an array while it grows.
    private let lock = NSLock()

    public init(particleCount: Int) {
        self.particleCount = max(particleCount, 1)
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public var frames: [Frame] { locked { storedFrames } }
    public var count: Int { locked { storedFrames.count } }
    public var isEmpty: Bool { count == 0 }
    public var byteCount: Int {
        locked { storage.count * 2 + storedFrames.count * MemoryLayout<Frame>.stride }
    }

    public var duration: Float {
        locked { storedFrames.last.map { $0.time - storedFrames[0].time } ?? 0 }
    }

    /// Memory a run of the given length would take, so the setup screen can warn before it
    /// rather than after.
    public static func estimatedBytes(particleCount: Int, frames: Int) -> Int {
        particleCount * 6 * frames
    }

    public func append(positions: UnsafePointer<SIMD3<Float>>, time: Float) {
        lock.lock()
        defer { lock.unlock() }
        var lower = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var upper = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for index in 0..<particleCount {
            let position = positions[index]
            guard position.x.isFinite, position.y.isFinite, position.z.isFinite else { continue }
            lower = simd_min(lower, position)
            upper = simd_max(upper, position)
        }
        guard lower.x <= upper.x else { return }

        let extent = max((upper - lower).max(), 1e-3) * 1.0005
        let scale = 65535 / extent
        let base = storage.count
        storage.append(contentsOf: repeatElement(0, count: particleCount * 3))

        storage.withUnsafeMutableBufferPointer { target in
            for index in 0..<particleCount {
                let local = (positions[index] - lower) * scale
                target[base + index * 3] = UInt16(min(max(local.x, 0), 65535))
                target[base + index * 3 + 1] = UInt16(min(max(local.y, 0), 65535))
                target[base + index * 3 + 2] = UInt16(min(max(local.z, 0), 65535))
            }
        }
        storedFrames.append(Frame(time: time, origin: lower, extent: extent))
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        storedFrames.removeAll(keepingCapacity: true)
        storage.removeAll(keepingCapacity: true)
    }

    /// Copies two consecutive snapshots into a Metal buffer so the GPU can blend them.
    public func upload(pair index: Int, into buffer: MTLBuffer) -> (Frame, Frame) {
        lock.lock()
        defer { lock.unlock() }
        guard !storedFrames.isEmpty else {
            let empty = Frame(time: 0, origin: .zero, extent: 1)
            return (empty, empty)
        }
        let first = min(max(index, 0), storedFrames.count - 1)
        let second = min(first + 1, storedFrames.count - 1)
        let stride = particleCount * 3
        let destination = buffer.contents().bindMemory(to: UInt16.self, capacity: stride * 2)
        storage.withUnsafeBufferPointer { source in
            destination.update(from: source.baseAddress! + first * stride, count: stride)
            (destination + stride).update(from: source.baseAddress! + second * stride, count: stride)
        }
        return (storedFrames[first], storedFrames[second])
    }
}

struct ExpandParams {
    var originA: SIMD4<Float>
    var originB: SIMD4<Float>
    var particleCount: UInt32
    var blend: Float
    var pad0: Float = 0
    var pad1: Float = 0
}

/// Blends two quantised snapshots into the renderer's position buffer.
public final class SnapshotExpander {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let staging: MTLBuffer
    private let particleCount: Int

    public init(device: MTLDevice, particleCount: Int) throws {
        self.device = device
        self.particleCount = max(particleCount, 1)

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: RecordingShaders.source, options: nil)
        } catch {
            throw RenderError.shaderCompilation("\(error)")
        }
        guard let function = library.makeFunction(name: "expandSnapshots") else {
            throw RenderError.pipelineCreation("missing kernel expandSnapshots")
        }
        do {
            pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            throw RenderError.pipelineCreation("expandSnapshots: \(error)")
        }
        guard let queue = device.makeCommandQueue(),
            let staging = device.makeBuffer(
                length: self.particleCount * 3 * 2 * 2, options: .storageModeShared)
        else { throw RenderError.noDevice }
        self.queue = queue
        self.staging = staging
    }

    public var stagingBuffer: MTLBuffer { staging }

    public func expand(
        first: Recording.Frame, second: Recording.Frame, blend: Float, into positions: MTLBuffer
    ) {
        guard let buffer = queue.makeCommandBuffer(),
            let encoder = buffer.makeComputeCommandEncoder()
        else { return }
        var params = ExpandParams(
            originA: SIMD4<Float>(
                first.origin.x, first.origin.y, first.origin.z, first.extent / 65535),
            originB: SIMD4<Float>(
                second.origin.x, second.origin.y, second.origin.z, second.extent / 65535),
            particleCount: UInt32(particleCount),
            blend: min(max(blend, 0), 1))
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(staging, offset: 0, index: 0)
        encoder.setBuffer(positions, offset: 0, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<ExpandParams>.stride, index: 2)
        encoder.dispatchThreads(
            MTLSize(width: particleCount, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: pipeline.maxTotalThreadsPerThreadgroup, height: 1, depth: 1))
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
    }
}
