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
    /// And which way each disk was turning, and how much of a disk was left of it. Measured
    /// by the solver, and there is no solver behind a replay, so a take that did not carry
    /// this would paint the arms in the plane the scene was written with — the very thing
    /// the live run stopped doing.
    private var storedDisks: [DiskState] = []
    /// A run captures on the simulation queue and is read back on the main actor. The two
    /// overlap by exactly one batch when a capture is stopped, which is enough to be reading
    /// an array while it grows.
    private let lock = NSLock()
    /// A batch already in flight lands after a capture is stopped, so the frame count the
    /// interface shows would sit one behind what a file then holds. Closing the take settles
    /// it: nothing more goes in until it is opened again.
    private var closed = false
    /// Where the frames go once the memory budget is spent.
    ///
    /// The budget bounds what a take holds in *memory*; it does not bound the take. Nothing
    /// captured is ever dropped or resampled, so a ten-thousand-megayear run comes back at
    /// the cadence it was taken at, however long it ran. What that costs is disk, and the
    /// take says how much.
    private var spill: SpillFile?
    /// The first frame that lives in the scratch file. Everything before it stays in memory,
    /// where the budget already paid for it: the take fills its allowance once and then runs
    /// on disk, rather than handing the whole allowance back and copying gigabytes out of it
    /// in one go at exactly the moment a long run is going well.
    private var spilledFrom = Int.max
    /// Set if the scratch file could not be opened at all. The capture then keeps going in
    /// memory, because losing frames is the one outcome that is not on offer — but somebody
    /// should be told, so it is asked for.
    public private(set) var spillFailure: String?
    /// One frame's quantised positions, reused, so a capture allocates nothing per frame.
    private var staging: [UInt16] = []

    public init(particleCount: Int, galaxyCount: Int = 1) {
        self.particleCount = max(particleCount, 1)
        self.galaxyCount = max(galaxyCount, 1)
    }

    /// Rebuilt from a file rather than captured, over memory the file still owns.
    public init(
        particleCount: Int, galaxyCount: Int, frames: [Frame], centers: [SIMD3<Float>],
        disks: [DiskState] = [], mapped: Data
    ) {
        self.particleCount = max(particleCount, 1)
        self.galaxyCount = max(galaxyCount, 1)
        self.storedFrames = frames
        self.storedCenters = centers
        self.storedDisks = disks
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
            storedDisks.reserveCapacity(frames * galaxyCount)
        }
    }

    /// One frame's quantised positions, wherever they live. Never escapes the lock.
    private func withFrameStorage<T>(_ index: Int, _ body: (UnsafeBufferPointer<UInt16>) -> T)
        -> T?
    {
        let span = particleCount * 3
        if let mapped {
            return mapped.withUnsafeBytes {
                let all = $0.bindMemory(to: UInt16.self)
                return body(UnsafeBufferPointer(rebasing: all[(index * span)..<((index + 1) * span)]))
            }
        }
        if let spill, index >= spilledFrom {
            var block = [UInt16](repeating: 0, count: span)
            do {
                try block.withUnsafeMutableBytes {
                    try spill.read(
                        into: $0.baseAddress!, count: span * 2,
                        at: (index - spilledFrom) * span * 2)
                }
            } catch { return nil }
            return block.withUnsafeBufferPointer(body)
        }
        return storage.withUnsafeBufferPointer {
            body(UnsafeBufferPointer(rebasing: $0[(index * span)..<((index + 1) * span)]))
        }
    }

    /// Hands the positions to a writer in bounded pieces, from wherever they live.
    ///
    /// Pieces rather than one block, because the whole of a take is the one thing here that
    /// does not fit anywhere twice: copying it into a `Data` first cost a second copy of the
    /// run, and a take that spilled has most of itself on disk and nothing to hand over at
    /// all. Sixty-four megabytes at a time reads and writes at the same speed as one block
    /// would and needs a millionth of the room.
    public func streamPositionBytes(_ body: (UnsafeRawBufferPointer) throws -> Void) rethrows {
        lock.lock()
        defer { lock.unlock() }
        let chunk = 64 << 20
        if let mapped {
            try mapped.withUnsafeBytes { source in
                var offset = 0
                while offset < source.count {
                    let length = Swift.min(chunk, source.count - offset)
                    try body(UnsafeRawBufferPointer(rebasing: source[offset..<(offset + length)]))
                    offset += length
                }
            }
            return
        }
        // Memory first and then the file, which is the order the frames are in.
        try storage.withUnsafeBytes { source in
            var offset = 0
            while offset < source.count {
                let length = Swift.min(chunk, source.count - offset)
                try body(UnsafeRawBufferPointer(rebasing: source[offset..<(offset + length)]))
                offset += length
            }
        }
        if let spill {
            var block = [UInt8](repeating: 0, count: Swift.min(chunk, max(spill.byteCount, 1)))
            var offset = 0
            while offset < spill.byteCount {
                let length = Swift.min(block.count, spill.byteCount - offset)
                do {
                    try block.withUnsafeMutableBytes {
                        try spill.read(into: $0.baseAddress!, count: length, at: offset)
                    }
                } catch { return }
                try block.withUnsafeBytes {
                    try body(UnsafeRawBufferPointer(rebasing: $0[0..<length]))
                }
                offset += length
            }
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

    /// What each galaxy's disk was doing on a given frame. Empty for a take written before
    /// the field existed, which the renderer reads as "fall back to the natal plane".
    public func disks(at index: Int) -> [DiskState] {
        locked {
            guard !storedFrames.isEmpty else { return [] }
            let frame = min(max(index, 0), storedFrames.count - 1)
            let base = frame * galaxyCount
            guard base + galaxyCount <= storedDisks.count else { return [] }
            return Array(storedDisks[base..<(base + galaxyCount)])
        }
    }

    /// The small parts a file needs, taken under the lock in one go. The positions are far
    /// too large to hand back as an array and go out through `withPositionBytes`.
    public func contents() -> (frames: [Frame], centers: [SIMD3<Float>], disks: [DiskState]) {
        locked { (storedFrames, storedCenters, storedDisks) }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public var frames: [Frame] { locked { storedFrames } }
    /// Whether the take has run past its memory budget and is continuing on disk.
    public var isSpilling: Bool { locked { spill != nil } }
    /// What the take holds in memory, which is what the budget bounds.
    public var memoryByteCount: Int { locked { memoryBytes() } }
    /// And what it holds on disk, which is bounded by the volume and nothing else.
    public var diskByteCount: Int { locked { spill?.byteCount ?? 0 } }
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

    /// Offers a frame to the take, which keeps it. Every one of them.
    ///
    /// Returns whether the take has moved to disk, which is the only thing the interface
    /// needs to say about it.
    @discardableResult
    public func offer(
        positions: UnsafePointer<SIMD3<Float>>, time: Float, centers: [SIMD3<Float>],
        disks: [DiskState] = [], budget: Int
    ) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, mapped == nil else { return spill != nil }

        // Two frames always stay in memory: playback interpolates between a pair, and a take
        // that spilled from the very first frame would have nothing to show while it fills.
        if budget > 0, spill == nil, memoryBytes() >= budget, storedFrames.count >= 2 {
            beginSpilling()
        }
        appendLocked(positions: positions, time: time, centers: centers, disks: disks)
        return spill != nil
    }

    /// Moves what is already held into a scratch file and keeps going there.
    ///
    /// A failure here is not allowed to cost a frame: the capture simply stays in memory and
    /// says why. Running out of address space is a worse outcome than running out of disk,
    /// but resampling a run somebody waited hours for is worse than either.
    private func beginSpilling() {
        do {
            spill = try SpillFile()
            spilledFrom = storedFrames.count
            spillFailure = nil
        } catch {
            spillFailure = "\(error)"
        }
    }

    /// What the take occupies in memory, which is what the budget bounds.
    private func memoryBytes() -> Int {
        (mapped?.count ?? storage.count * 2) + storedFrames.count * MemoryLayout<Frame>.stride
    }

    /// What the take occupies altogether, memory and scratch file, which is what it costs.
    private func heldBytes() -> Int { memoryBytes() + (spill?.byteCount ?? 0) }

    public func append(
        positions: UnsafePointer<SIMD3<Float>>, time: Float, centers: [SIMD3<Float>] = [],
        disks: [DiskState] = []
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !closed, mapped == nil else { return }
        appendLocked(positions: positions, time: time, centers: centers, disks: disks)
    }

    private func appendLocked(
        positions: UnsafePointer<SIMD3<Float>>, time: Float, centers: [SIMD3<Float>],
        disks: [DiskState]
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
        let span = particleCount * 3
        if staging.count != span { staging = [UInt16](repeating: 0, count: span) }
        staging.withUnsafeMutableBufferPointer { target in
            for index in 0..<particleCount {
                let local = (positions[index] - lower) * scale
                target[index * 3] = UInt16(min(max(local.x, 0), 65535))
                target[index * 3 + 1] = UInt16(min(max(local.y, 0), 65535))
                target[index * 3 + 2] = UInt16(min(max(local.z, 0), 65535))
            }
        }
        // The bytes land before the frame that describes them does, so a reader on another
        // queue never sees a frame whose positions are not yet there to be read.
        if let spill, storedFrames.count >= spilledFrom {
            do {
                try staging.withUnsafeBytes { try spill.append($0) }
            } catch {
                spillFailure = "\(error)"
                return
            }
        } else {
            storage.append(contentsOf: staging)
        }
        storedFrames.append(Frame(time: time, origin: lower, extent: extent))
        for galaxy in 0..<galaxyCount {
            storedCenters.append(galaxy < centers.count ? centers[galaxy] : .zero)
            storedDisks.append(
                galaxy < disks.count
                    ? disks[galaxy] : DiskState(axis: SIMD3<Float>(0, 0, 1)))
        }
    }

    public func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        storedFrames.removeAll(keepingCapacity: true)
        storedCenters.removeAll(keepingCapacity: true)
        storedDisks.removeAll(keepingCapacity: true)
        storage.removeAll(keepingCapacity: true)
        mapped = nil
        // Closing the descriptor is what gives the volume its space back, so a take that is
        // cleared does not sit on eighty gigabytes until the application quits.
        spill = nil
        spilledFrom = .max
        spillFailure = nil
    }

    /// Decodes one frame back to positions, for framing a camera or reseeding a renderer.
    public func positions(at index: Int) -> [SIMD3<Float>] {
        locked {
            guard !storedFrames.isEmpty else { return [] }
            let frame = min(max(index, 0), storedFrames.count - 1)
            let box = storedFrames[frame]
            let scale = box.extent / 65535
            var decoded = [SIMD3<Float>](repeating: .zero, count: particleCount)
            let filled: Void? = withFrameStorage(frame) { source in
                for particle in 0..<particleCount {
                    let slot = particle * 3
                    decoded[particle] =
                        box.origin
                        + SIMD3<Float>(
                            Float(source[slot]) * scale,
                            Float(source[slot + 1]) * scale,
                            Float(source[slot + 2]) * scale)
                }
            }
            return filled == nil ? [] : decoded
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
        let stride = particleCount * 3
        lock.lock()
        guard index >= 0, index < storedFrames.count else {
            lock.unlock()
            return nil
        }
        let frame = storedFrames[index]
        let mapping = mapped
        let spilling = spill
        let from = spilledFrom
        lock.unlock()

        let destination = buffer.contents().advanced(by: offset).bindMemory(
            to: UInt16.self, capacity: stride)
        // A take read from a file is finished: every frame is already in it and the mapping
        // never moves, so the bulk copy has no business holding the lock. It used to, and the
        // main actor waited behind twenty-eight megabytes of memcpy on every played-back
        // frame — not in `fetch`, which the reader keeps ahead of the playhead, but in
        // `frame(at:)`, which only ever wanted a struct.
        if let mapping {
            mapping.withUnsafeBytes { raw in
                let source = raw.bindMemory(to: UInt16.self)
                destination.update(from: source.baseAddress! + index * stride, count: stride)
            }
            return frame
        }
        // A spilled frame is finished the moment its own frame record exists — the bytes go
        // in first — and the file only ever grows, so this needs no lock either. The read
        // lands straight in the Metal buffer, which is what keeps playback off the heap.
        if let file = spilling, index >= from {
            do {
                try file.read(
                    into: .init(destination), count: stride * 2,
                    at: (index - from) * stride * 2)
            } catch { return nil }
            return frame
        }
        // A capture still growing is the other case, and there the array behind the positions
        // can be reallocated by the next batch mid-copy. That one does have to hold the lock.
        lock.lock()
        defer { lock.unlock() }
        guard index < storedFrames.count else { return nil }
        storage.withUnsafeBufferPointer { source in
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
