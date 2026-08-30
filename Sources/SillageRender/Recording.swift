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
    /// Galaxies whose centres are carried alongside each frame.
    public let galaxyCount: Int
    private var storedFrames: [Frame] = []
    private var storage: [UInt16] = []
    /// A take read from a file stays mapped rather than being copied in. Reopening a run of
    /// several gigabytes should cost the pages the viewer actually touches, not a second copy
    /// of the whole thing.
    private var mapped: Data?
    /// Where each galaxy sat on each frame, flattened. The spiral pattern is painted about
    /// these, so without them a replay draws the arms wherever the galaxies ended up rather
    /// than where they were.
    private var storedCenters: [SIMD3<Float>] = []
    /// A run captures on the simulation queue and is read back on the main actor. The two
    /// overlap by exactly one batch when a capture is stopped, which is enough to be reading
    /// an array while it grows.
    private let lock = NSLock()
    /// A batch already in flight lands after a capture is stopped, so the frame count the
    /// interface shows would sit one behind what a file then holds. Closing the take settles
    /// it: nothing more goes in until it is opened again.
    private var closed = false
    /// Batches skipped between captured frames. A long run should come back whole at a
    /// coarser cadence rather than stopping halfway, so when the take fills its budget it
    /// throws away every other frame and captures half as often from then on.
    public private(set) var stride = 1
    private var sinceCapture = 0

    public init(particleCount: Int, galaxyCount: Int = 1) {
        self.particleCount = max(particleCount, 1)
        self.galaxyCount = max(galaxyCount, 1)
    }

    /// Rebuilt from a file rather than captured, over memory the file still owns.
    public init(
        particleCount: Int, galaxyCount: Int, frames: [Frame], centers: [SIMD3<Float>],
        mapped: Data
    ) {
        self.particleCount = max(particleCount, 1)
        self.galaxyCount = max(galaxyCount, 1)
        self.storedFrames = frames
        self.storedCenters = centers
        self.mapped = mapped
    }

    /// Room for a whole run up front. Growing into it a frame at a time doubles the array
    /// whenever it fills, and for a moment the old copy and the new one are both resident:
    /// measured at two gigabytes held, the peak was three and a half.
    public func reserve(frames: Int) {
        locked {
            guard mapped == nil, frames > 0 else { return }
            storage.reserveCapacity(frames * particleCount * 3)
            storedFrames.reserveCapacity(frames)
            storedCenters.reserveCapacity(frames * galaxyCount)
        }
    }

    /// The quantised positions, wherever they live. Never escapes the lock.
    private func withStorage<T>(_ body: (UnsafeBufferPointer<UInt16>) -> T) -> T {
        if let mapped {
            return mapped.withUnsafeBytes { body($0.bindMemory(to: UInt16.self)) }
        }
        return storage.withUnsafeBufferPointer(body)
    }

    /// Hands the positions to a writer without copying them anywhere first.
    public func withPositionBytes<T>(_ body: (UnsafeRawBufferPointer) -> T) -> T {
        locked {
            if let mapped { return mapped.withUnsafeBytes(body) }
            return storage.withUnsafeBytes(body)
        }
    }

    /// Where the galaxies were on a given frame.
    public func centers(at index: Int) -> [SIMD3<Float>] {
        locked {
            guard !storedFrames.isEmpty else { return [] }
            let frame = min(max(index, 0), storedFrames.count - 1)
            let base = frame * galaxyCount
            guard base + galaxyCount <= storedCenters.count else { return [] }
            return Array(storedCenters[base..<(base + galaxyCount)])
        }
    }

    /// The small parts a file needs, taken under the lock in one go. The positions are far
    /// too large to hand back as an array and go out through `withPositionBytes`.
    public func contents() -> (frames: [Frame], centers: [SIMD3<Float>]) {
        locked { (storedFrames, storedCenters) }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public var frames: [Frame] { locked { storedFrames } }
    public var count: Int { locked { storedFrames.count } }
    public var isEmpty: Bool { count == 0 }
    public var byteCount: Int { locked { heldBytes() } }

    public var duration: Float {
        locked { storedFrames.last.map { $0.time - storedFrames[0].time } ?? 0 }
    }

    /// Memory a run of the given length would take, so the setup screen can warn before it
    /// rather than after.
    public static func estimatedBytes(particleCount: Int, frames: Int) -> Int {
        particleCount * 6 * frames
    }

    public func close() { locked { closed = true } }
    public func reopen() { locked { closed = false } }

    /// Offers a frame to the take, which decides whether to keep it.
    ///
    /// Returns whether the take has had to coarsen at least once, which is the only thing the
    /// interface needs to say about it.
    @discardableResult
    public func offer(
        positions: UnsafePointer<SIMD3<Float>>, time: Float, centers: [SIMD3<Float>],
        budget: Int
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, mapped == nil else { return stride > 1 }

        sinceCapture += 1
        guard sinceCapture >= stride else { return stride > 1 }
        sinceCapture = 0

        // Two frames always get through: playback interpolates between a pair.
        if budget > 0, heldBytes() >= budget, storedFrames.count >= 4 {
            halve()
            stride *= 2
        }
        appendLocked(positions: positions, time: time, centers: centers)
        return stride > 1
    }

    /// Keeps every other frame, in place. The positions are gigabytes, so they are moved down
    /// over themselves rather than copied into a second buffer.
    private func halve() {
        let span = particleCount * 3
        var kept = 0
        storage.withUnsafeMutableBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for frame in Swift.stride(from: 0, to: storedFrames.count, by: 2) {
                if kept != frame {
                    (base + kept * span).update(from: base + frame * span, count: span)
                }
                kept += 1
            }
        }
        storage.removeLast(storage.count - kept * span)

        var frames: [Frame] = []
        var centers: [SIMD3<Float>] = []
        frames.reserveCapacity(kept)
        centers.reserveCapacity(kept * galaxyCount)
        for frame in Swift.stride(from: 0, to: storedFrames.count, by: 2) {
            frames.append(storedFrames[frame])
            let base = frame * galaxyCount
            for galaxy in 0..<galaxyCount {
                centers.append(base + galaxy < storedCenters.count ? storedCenters[base + galaxy] : .zero)
            }
        }
        storedFrames = frames
        storedCenters = centers
    }

    private func heldBytes() -> Int {
        (mapped?.count ?? storage.count * 2) + storedFrames.count * MemoryLayout<Frame>.stride
    }

    public func append(
        positions: UnsafePointer<SIMD3<Float>>, time: Float, centers: [SIMD3<Float>] = []
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, mapped == nil else { return }
        appendLocked(positions: positions, time: time, centers: centers)
    }

    private func appendLocked(
        positions: UnsafePointer<SIMD3<Float>>, time: Float, centers: [SIMD3<Float>]
    ) {
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
        for galaxy in 0..<galaxyCount {
            storedCenters.append(galaxy < centers.count ? centers[galaxy] : .zero)
        }
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        storedFrames.removeAll(keepingCapacity: true)
        storedCenters.removeAll(keepingCapacity: true)
        storage.removeAll(keepingCapacity: true)
        mapped = nil
    }

    /// Decodes one frame back to positions, for framing a camera or reseeding a renderer.
    public func positions(at index: Int) -> [SIMD3<Float>] {
        locked {
            guard !storedFrames.isEmpty else { return [] }
            let frame = min(max(index, 0), storedFrames.count - 1)
            let box = storedFrames[frame]
            let scale = box.extent / 65535
            let base = frame * particleCount * 3
            var decoded = [SIMD3<Float>](repeating: .zero, count: particleCount)
            withStorage { source in
                for particle in 0..<particleCount {
                    let slot = base + particle * 3
                    decoded[particle] =
                        box.origin
                        + SIMD3<Float>(
                            Float(source[slot]) * scale,
                            Float(source[slot + 1]) * scale,
                            Float(source[slot + 2]) * scale)
                }
            }
            return decoded
        }
    }

    /// What a snapshot was taken at, without touching its positions.
    public func frame(at index: Int) -> Frame? {
        locked {
            guard index >= 0, index < storedFrames.count else { return nil }
            return storedFrames[index]
        }
    }

    /// Copies one snapshot's quantised positions into a Metal buffer at a byte offset. One
    /// snapshot rather than a pair: at playback speed the playhead crosses a snapshot only
    /// every other frame, so copying both surrounding ones every displayed frame was mostly
    /// recopying what was already there. `SnapshotStream` keeps them and calls this once each.
    @discardableResult
    public func copy(frame index: Int, into buffer: MTLBuffer, atByteOffset offset: Int)
        -> Frame?
    {
        lock.lock()
        defer { lock.unlock() }
        guard index >= 0, index < storedFrames.count else { return nil }
        let stride = particleCount * 3
        let destination = buffer.contents().advanced(by: offset).bindMemory(
            to: UInt16.self, capacity: stride)
        withStorage { source in
            destination.update(from: source.baseAddress! + index * stride, count: stride)
        }
        return storedFrames[index]
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
    private let particleCount: Int

    public init(device: MTLDevice, particleCount: Int) throws {
        self.device = device
        self.particleCount = max(particleCount, 1)

        let library: MTLLibrary
        do {
            library = try ShaderCache.library(RecordingShaders.source, on: device)
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
        guard let queue = device.makeCommandQueue() else { throw RenderError.noDevice }
        self.queue = queue
    }

    /// Blends two snapshots, each held wherever it happens to sit in `source`, into world
    /// positions. The wait is what lets the reader overwrite those slots afterwards without
    /// racing the GPU, and costs about two milliseconds at five million particles.
    public func expand(
        first: Recording.Frame, at firstOffset: Int,
        second: Recording.Frame, at secondOffset: Int,
        from source: MTLBuffer, blend: Float, into positions: MTLBuffer
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
        encoder.setBuffer(source, offset: firstOffset, index: 0)
        encoder.setBuffer(source, offset: secondOffset, index: 1)
        encoder.setBuffer(positions, offset: 0, index: 2)
        encoder.setBytes(&params, length: MemoryLayout<ExpandParams>.stride, index: 3)
        encoder.dispatchThreads(
            MTLSize(width: particleCount, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(
                width: pipeline.maxTotalThreadsPerThreadgroup, height: 1, depth: 1))
        encoder.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
    }
}
