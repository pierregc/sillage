import Foundation
import simd

/// One cell of the tree, laid out for a Metal buffer.
///
/// Thirty-two bytes rather than forty-eight: the cell centre is only needed while building,
/// and the child and particle ranges never both apply, so they share two slots. Counts fit
/// exactly in a float below sixteen million. The node array is the hottest thing the force
/// kernel reads, so its size is its speed.
public struct BHNode: Sendable {
    /// Centre of mass in xyz, total mass in w.
    public var comMass: SIMD4<Float>
    /// Width squared, range start, signed count, unused. A positive count means that many
    /// children; a negative one means a leaf holding that many particles.
    public var packed: SIMD4<Float>

    public init() {
        comMass = .zero
        packed = .zero
    }

    public var isLeaf: Bool { packed.z <= 0 }
    public var childOffset: Int { Int(packed.y) }
    public var childCount: Int { max(Int(packed.z), 0) }
    public var particleStart: Int { Int(packed.y) }
    public var particleCount: Int { max(Int(-packed.z), 0) }
}

/// Barnes-Hut octree, built on the CPU and traversed on the GPU.
///
/// Building the tree is the awkward half of a GPU N-body solver: it wants a radix sort and a
/// pointerless hierarchy. On unified memory the CPU can read the same buffer the GPU writes,
/// so the build happens here in Morton order while the traversal, which is where the time
/// actually goes, stays on the GPU.
public final class BarnesHutTree {
    /// Wall time of each build phase, for profiling.
    public private(set) var phaseMilliseconds: [String: Double] = [:]
    public private(set) var nodes: [BHNode] = []
    /// Particle indices in Morton order. Leaves address particles through this.
    public private(set) var order: [UInt32] = []

    public let leafCapacity: Int
    public let maximumDepth: Int

    private var scratch: [UInt32] = []
    private var primary: [UInt32] = []
    private var histogram: [Int] = []
    private var sortedCodes: [UInt64] = []
    private var scratchCodes: [UInt64] = []
    private var offsets = [Int](repeating: 0, count: 9)
    private var parents: [Int32] = []

    /// Twenty-one bits an axis is what a sixty-four bit code holds, so the tree can go
    /// twenty-one levels deep. Ten was the old ceiling, and an evolving collision hit it
    /// immediately: the disks concentrate while tidal debris stretches the root box, so the
    /// cells at the bottom cover more and more space and fill with hundreds of particles
    /// each, which the force pass then has to sum one by one.
    public init(leafCapacity: Int = 16, maximumDepth: Int = 20) {
        self.leafCapacity = max(leafCapacity, 1)
        self.maximumDepth = min(max(maximumDepth, 1), 21)
    }

    /// Spreads the low 21 bits of a value so three of them interleave into a Morton code.
    static func spread(_ value: UInt32) -> UInt64 {
        var x = UInt64(value) & 0x1F_FFFF
        x = (x | (x << 32)) & 0x001F_0000_0000_FFFF
        x = (x | (x << 16)) & 0x001F_0000_FF00_00FF
        x = (x | (x << 8)) & 0x100F_00F0_0F00_F00F
        x = (x | (x << 4)) & 0x10C3_0C30_C30C_30C3
        x = (x | (x << 2)) & 0x1249_2492_4924_9249
        return x
    }

    static func morton(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt64 {
        (spread(x) << 2) | (spread(y) << 1) | spread(z)
    }

    /// The octant digit a code takes at a given depth, as (x, y, z) bits.
    static func octant(_ code: UInt64, depth: Int) -> Int {
        Int((code >> UInt64(60 - 3 * depth)) & 7)
    }

    public func build(positions: [SIMD3<Float>], mass: [Float]) {
        let count = positions.count
        nodes.removeAll(keepingCapacity: true)
        parents.removeAll(keepingCapacity: true)
        guard count > 0 else {
            order = []
            return
        }

        var lower = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var upper = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for position in positions where position.x.isFinite && position.y.isFinite && position.z.isFinite {
            lower = simd_min(lower, position)
            upper = simd_max(upper, position)
        }
        guard lower.x <= upper.x else {
            order = []
            return
        }

        // A cube, so a cell's opening angle does not depend on direction.
        let center = (lower + upper) * 0.5
        let half = max((upper - lower).max() * 0.5, 1e-3) * 1.001

        var clock = Date()
        func mark(_ name: String) {
            phaseMilliseconds[name] = Date().timeIntervalSince(clock) * 1000
            clock = Date()
        }
        mark("bounds")

        if sortedCodes.count != count { sortedCodes = [UInt64](repeating: 0, count: count) }
        let resolution: Float = 2_097_151
        let inverse = resolution / (2 * half)
        let origin = center - SIMD3<Float>(repeating: half)
        let codeChunk = max(count / (ProcessInfo.processInfo.activeProcessorCount * 4), 8192)
        let codeChunks = (count + codeChunk - 1) / codeChunk
        positions.withUnsafeBufferPointer { source in
            sortedCodes.withUnsafeMutableBufferPointer { target in
                DispatchQueue.concurrentPerform(iterations: codeChunks) { block in
                    let start = block * codeChunk
                    let end = min(start + codeChunk, count)
                    for index in start..<end {
                        let local = (source[index] - origin) * inverse
                        target[index] = BarnesHutTree.morton(
                            UInt32(min(max(local.x, 0), resolution)),
                            UInt32(min(max(local.y, 0), resolution)),
                            UInt32(min(max(local.z, 0), resolution)))
                    }
                }
            }
        }

        mark("morton")
        order = sortedByCode(count: count)
        mark("sort")
        buildNodes(count: count, center: center, half: half)
        mark("nodes")
        accumulate(positions: positions, mass: mass)
        mark("accumulate")
    }

    /// Least significant digit radix sort, over the codes themselves with the particle index
    /// carried alongside. Sorting indices alone and reading the key back through them made
    /// every count and every scatter a random access into a forty megabyte array, which was
    /// two thirds of the whole build at five million particles: moving twelve bytes in order
    /// beats moving four at random. The sorted codes fall out of the last pass, so the gather
    /// that used to materialise them is gone as well.
    ///
    /// Morton codes are 63 bits, so four passes of sixteen cover them, and an even number of
    /// passes leaves the result in the array it started in.
    private func sortedByCode(count: Int) -> [UInt32] {
        let radix = 16
        let buckets = 1 << radix
        if primary.count != count { primary = [UInt32](repeating: 0, count: count) }
        if scratch.count != count { scratch = [UInt32](repeating: 0, count: count) }
        if scratchCodes.count != count { scratchCodes = [UInt64](repeating: 0, count: count) }
        if histogram.count != buckets { histogram = [Int](repeating: 0, count: buckets) }

        primary.withUnsafeMutableBufferPointer { buffer in
            for index in 0..<count { buffer[index] = UInt32(index) }
        }

        let mask = UInt64(buckets - 1)
        for pass in 0..<4 {
            let shift = UInt64(pass * radix)
            sortedCodes.withUnsafeMutableBufferPointer { sourceKey in
                scratchCodes.withUnsafeMutableBufferPointer { targetKey in
                    primary.withUnsafeMutableBufferPointer { source in
                        scratch.withUnsafeMutableBufferPointer { target in
                            histogram.withUnsafeMutableBufferPointer { counts in
                                for bucket in 0..<buckets { counts[bucket] = 0 }
                                for position in 0..<count {
                                    counts[Int((sourceKey[position] >> shift) & mask)] += 1
                                }
                                var running = 0
                                for bucket in 0..<buckets {
                                    let value = counts[bucket]
                                    counts[bucket] = running
                                    running += value
                                }
                                for position in 0..<count {
                                    let key = sourceKey[position]
                                    let slot = counts[Int((key >> shift) & mask)]
                                    targetKey[slot] = key
                                    target[slot] = source[position]
                                    counts[Int((key >> shift) & mask)] = slot + 1
                                }
                            }
                        }
                    }
                }
            }
            swap(&primary, &scratch)
            swap(&sortedCodes, &scratchCodes)
        }
        return primary
    }

    private struct Work {
        var start: Int
        var count: Int
        var depth: Int
        var center: SIMD3<Float>
        var half: Float
        var node: Int
    }

    private func makeNode(half: Float, start: Int, count: Int, parent: Int32) -> Int {
        var node = BHNode()
        let width = half * 2
        node.packed = SIMD4<Float>(width * width, Float(start), Float(-count), 0)
        nodes.append(node)
        parents.append(parent)
        return nodes.count - 1
    }

    private func buildNodes(count: Int, center: SIMD3<Float>, half: Float) {
        nodes.reserveCapacity(count / max(leafCapacity, 1) * 2 + 16)
        let root = makeNode(half: half, start: 0, count: count, parent: -1)
        var stack = [Work(start: 0, count: count, depth: 0, center: center, half: half, node: root)]

        while let work = stack.popLast() {
            if work.count <= leafCapacity || work.depth >= maximumDepth { continue }

            // Morton order means the eight octants are already contiguous runs. The offset
            // table is reused: allocating one per node meant a heap allocation for every cell
            // in the tree, which dominated the build.
            let limit = work.start + work.count
            for slot in 0...8 { offsets[slot] = limit }
            offsets[0] = work.start
            var digit = 0
            let shift = UInt64(60 - 3 * work.depth)
            sortedCodes.withUnsafeBufferPointer { keys in
                for position in work.start..<limit {
                    let value = Int((keys[position] >> shift) & 7)
                    while digit < value {
                        digit += 1
                        offsets[digit] = position
                    }
                }
            }
            while digit < 8 {
                digit += 1
                offsets[digit] = limit
            }

            let childHalf = work.half * 0.5
            var firstChild = -1
            var childCount: Int32 = 0
            for octant in 0..<8 {
                let start = offsets[octant]
                let size = offsets[octant + 1] - start
                if size <= 0 { continue }
                let sign = SIMD3<Float>(
                    (octant & 4) != 0 ? 1 : -1,
                    (octant & 2) != 0 ? 1 : -1,
                    (octant & 1) != 0 ? 1 : -1)
                let childCenter = work.center + sign * childHalf
                let index = makeNode(
                    half: childHalf, start: start, count: size, parent: Int32(work.node))
                if firstChild < 0 { firstChild = index }
                childCount += 1
                stack.append(
                    Work(
                        start: start, count: size, depth: work.depth + 1, center: childCenter,
                        half: childHalf, node: index))
            }
            nodes[work.node].packed.y = Float(firstChild)
            nodes[work.node].packed.z = Float(childCount)
        }
    }

    /// Leaves sum their own particles, then every node folds into its parent. Children are
    /// always created after their parent, so one reverse pass is enough.
    private func accumulate(positions: [SIMD3<Float>], mass: [Float]) {
        for index in nodes.indices { nodes[index].comMass = .zero }

        let nodeCount = nodes.count
        let chunk = max(nodeCount / (ProcessInfo.processInfo.activeProcessorCount * 4), 1024)
        let chunks = (nodeCount + chunk - 1) / chunk
        positions.withUnsafeBufferPointer { positionBuffer in
            mass.withUnsafeBufferPointer { massBuffer in
                order.withUnsafeBufferPointer { orderBuffer in
                    nodes.withUnsafeMutableBufferPointer { nodeBuffer in
                        DispatchQueue.concurrentPerform(iterations: chunks) { block in
                            let first = block * chunk
                            let last = min(first + chunk, nodeCount)
                            for index in first..<last where nodeBuffer[index].isLeaf {
                                let start = nodeBuffer[index].particleStart
                                let count = nodeBuffer[index].particleCount
                                var weighted = SIMD3<Float>.zero
                                var total: Float = 0
                                for position in start..<(start + count) {
                                    let particle = Int(orderBuffer[position])
                                    let m = massBuffer.isEmpty ? 1 : massBuffer[particle]
                                    weighted += positionBuffer[particle] * m
                                    total += m
                                }
                                nodeBuffer[index].comMass = SIMD4<Float>(
                                    weighted.x, weighted.y, weighted.z, total)
                            }
                        }
                    }
                }
            }
        }

        for index in stride(from: nodes.count - 1, through: 1, by: -1) {
            let parent = Int(parents[index])
            guard parent >= 0 else { continue }
            nodes[parent].comMass += nodes[index].comMass
        }

        for index in nodes.indices {
            let total = nodes[index].comMass.w
            if total > 0 {
                let inverse = 1 / total
                nodes[index].comMass.x *= inverse
                nodes[index].comMass.y *= inverse
                nodes[index].comMass.z *= inverse
            }
        }
    }

    /// Direct-summation reference, used to check the traversal.
    public static func directAcceleration(
        at position: SIMD3<Float>,
        positions: [SIMD3<Float>],
        mass: [Float],
        softening: Float,
        skipping index: Int
    ) -> SIMD3<Float> {
        var total = SIMD3<Float>.zero
        let epsilon = softening * softening
        for other in positions.indices where other != index {
            let offset = positions[other] - position
            let distance = simd_length_squared(offset) + epsilon
            total += offset * (Physics.gravitationalConstant * mass[other] / (distance * sqrt(distance)))
        }
        return total
    }
}
