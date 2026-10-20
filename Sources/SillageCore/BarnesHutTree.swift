import Foundation
import simd

/// One cell of the tree, laid out for a Metal buffer.
///
/// Thirty-two bytes rather than forty-eight: the cell centre is only needed while building,
/// and the child and particle ranges never both apply, so they share two slots. The node
/// array is the hottest thing the force kernel reads, so its size is its speed.
///
/// The two range slots carry *integers* through a float-shaped buffer, bit for bit, and that
/// is the whole reason this type has accessors at all. They used to hold `Float(start)`, and
/// a float stops being able to count past 16 777 216: a run of eighteen million simulated
/// particles rounded its leaf starts to the nearest even index, so the last leaf in the tree
/// read one slot beyond `order`, picked up whatever the allocator had put there, and used it
/// as a particle number. Which is a segmentation fault about fifty gigabytes into nothing,
/// after three quarters of an hour of a run, with the take still in memory and nothing
/// written. Nothing about the layout changes; only the reading of it is now exact.
public struct BHNode: Sendable {
    /// Centre of mass in xyz, total mass in w.
    public var comMass: SIMD4<Float>
    /// Width squared, then the range start and the signed count as bit patterns, then unused.
    /// A positive count means that many children; a negative one means a leaf holding that
    /// many particles.
    public var packed: SIMD4<Float>

    public init() {
        comMass = .zero
        packed = .zero
    }

    /// The range start, as an index rather than as a magnitude.
    public var range: Int32 {
        get { Int32(bitPattern: packed.y.bitPattern) }
        set { packed.y = Float(bitPattern: UInt32(bitPattern: newValue)) }
    }

    /// Children when positive, minus the particles held when a leaf.
    public var signedCount: Int32 {
        get { Int32(bitPattern: packed.z.bitPattern) }
        set { packed.z = Float(bitPattern: UInt32(bitPattern: newValue)) }
    }

    public var isLeaf: Bool { signedCount <= 0 }
    public var childOffset: Int { Int(range) }
    public var childCount: Int { max(Int(signedCount), 0) }
    public var particleStart: Int { Int(range) }
    public var particleCount: Int { max(Int(-Int64(signedCount)), 0) }
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
    private(set) var sortedCodes: [UInt64] = []
    private var scratchCodes: [UInt64] = []
    private var spareNodes: [BHNode] = []
    private var top: [BHNode] = []
    private var topIndices: [Int] = []
    private var subtrees: [Subtree] = []
    private var schedule: [Int] = []
    private var blocks: [[BHNode]] = []
    /// How small a cell has to be to go to a core of its own. Tests lower it.
    var subtreeParticles: Int?

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
        // Started before the bounds pass, which used to go untimed and always read zero.
        var clock = Date()
        func mark(_ name: String) {
            phaseMilliseconds[name] = Date().timeIntervalSince(clock) * 1000
            clock = Date()
        }
        let count = positions.count
        guard count > 0 else {
            nodes.removeAll(keepingCapacity: true)
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
            nodes.removeAll(keepingCapacity: true)
            order = []
            return
        }

        // A cube, so a cell's opening angle does not depend on direction.
        let center = (lower + upper) * 0.5
        let half = max((upper - lower).max() * 0.5, 1e-3) * 1.001

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
        sortByCode(count: count)
        mark("sort")
        buildNodes(count: count, half: half)
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
    /// Every pass runs on every core. Each contiguous block counts its own digits, the counts
    /// are laid out bucket by bucket and block by block, and each block then scatters into
    /// the slots that leaves it. A block keeps its order and blocks keep theirs, so the sort
    /// stays stable and the result is the serial one to the bit.
    ///
    /// Six passes of eleven bits measured fastest, against eight of eight, four of sixteen and
    /// three of twenty-one: 26 ms at 12.5 million codes where sixteen took 49 and twenty-one 161,
    /// because a wide digit means a histogram per block too large to stay in cache.
    func sort(codes: [UInt64]) {
        sortedCodes = codes
        sortByCode(count: codes.count)
    }

    private func sortByCode(count: Int) {
        let radix = 11
        let buckets = 1 << radix
        let mask = UInt64(buckets - 1)
        let passes = (63 + radix - 1) / radix
        // More blocks than cores, so a block left on an efficiency core does not hold up the rest.
        let blocks = max(min(ProcessInfo.processInfo.activeProcessorCount * 4, count / 16_384), 1)
        let blockSize = (count + blocks - 1) / blocks
        if primary.count != count { primary = [UInt32](repeating: 0, count: count) }
        if scratch.count != count { scratch = [UInt32](repeating: 0, count: count) }
        if scratchCodes.count != count { scratchCodes = [UInt64](repeating: 0, count: count) }
        if histogram.count != blocks * buckets {
            histogram = [Int](repeating: 0, count: blocks * buckets)
        }

        primary.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: blocks) { block in
                for index in block * blockSize..<min((block + 1) * blockSize, count) {
                    buffer[index] = UInt32(index)
                }
            }
        }

        for pass in 0..<passes {
            let shift = UInt64(pass * radix)
            var moves = true
            sortedCodes.withUnsafeMutableBufferPointer { sourceKey in
                scratchCodes.withUnsafeMutableBufferPointer { targetKey in
                    primary.withUnsafeMutableBufferPointer { source in
                        scratch.withUnsafeMutableBufferPointer { target in
                            histogram.withUnsafeMutableBufferPointer { counts in
                                DispatchQueue.concurrentPerform(iterations: blocks) { block in
                                    let base = block * buckets
                                    for bucket in 0..<buckets { counts[base + bucket] = 0 }
                                    for position in block * blockSize..<min((block + 1) * blockSize, count) {
                                        counts[base + Int((sourceKey[position] >> shift) & mask)] += 1
                                    }
                                }
                                // Walked row by row: down the columns it misses the cache on every read.
                                var starts = [Int](repeating: 0, count: buckets)
                                starts.withUnsafeMutableBufferPointer { starts in
                                    for block in 0..<blocks {
                                        for bucket in 0..<buckets {
                                            starts[bucket] += counts[block * buckets + bucket]
                                        }
                                    }
                                    // Every code shares this digit, so the pass would move nothing.
                                    if starts.contains(count) {
                                        moves = false
                                        return
                                    }
                                    var running = 0
                                    for bucket in 0..<buckets {
                                        let total = starts[bucket]
                                        starts[bucket] = running
                                        running += total
                                    }
                                    for block in 0..<blocks {
                                        for bucket in 0..<buckets {
                                            let value = counts[block * buckets + bucket]
                                            counts[block * buckets + bucket] = starts[bucket]
                                            starts[bucket] += value
                                        }
                                    }
                                }
                                guard moves else { return }
                                DispatchQueue.concurrentPerform(iterations: blocks) { block in
                                    let base = block * buckets
                                    for position in block * blockSize..<min((block + 1) * blockSize, count) {
                                        let key = sourceKey[position]
                                        let bucket = base + Int((key >> shift) & mask)
                                        let slot = counts[bucket]
                                        targetKey[slot] = key
                                        target[slot] = source[position]
                                        counts[bucket] = slot + 1
                                    }
                                }
                            }
                        }
                    }
                }
            }
            if moves {
                swap(&primary, &scratch)
                swap(&sortedCodes, &scratchCodes)
            }
        }
        // Swapped rather than assigned: sharing the buffer made the next build copy it.
        swap(&order, &primary)
    }

    private struct Work {
        var start: Int
        var count: Int
        var depth: Int
        var half: Float
        var node: Int
    }

    /// A cell below the top levels, split on its own core.
    private struct Subtree {
        var work: Work
        /// How many top nodes existed when the serial split would have reached it.
        var insertion: Int
        var base = 0
        var size = 0
        var rootChildren: Int32 = 0
    }

    private static func makeNode(half: Float, start: Int, count: Int) -> BHNode {
        var node = BHNode()
        let width = half * 2
        node.packed.x = width * width
        node.range = Int32(start)
        node.signedCount = Int32(clamping: -count)
        return node
    }

    /// Where each octant of a cell starts. Morton order makes them contiguous runs, so a large
    /// cell is bisected rather than read code by code: the top levels would otherwise read the
    /// whole array once per level, on one core.
    private static func octants(
        _ keys: UnsafeBufferPointer<UInt64>, _ work: Work, _ offsets: UnsafeMutablePointer<Int>
    ) {
        let limit = work.start + work.count
        let shift = UInt64(60 - 3 * work.depth)
        offsets[0] = work.start
        offsets[8] = limit
        if work.count <= 64 {
            var digit = 0
            for position in work.start..<limit {
                let value = Int((keys[position] >> shift) & 7)
                while digit < value {
                    digit += 1
                    offsets[digit] = position
                }
            }
            while digit < 7 {
                digit += 1
                offsets[digit] = limit
            }
            return
        }
        var low = work.start
        for digit in 1..<8 {
            var high = limit
            while low < high {
                let middle = (low + high) / 2
                if Int((keys[middle] >> shift) & 7) < digit { low = middle + 1 } else { high = middle }
            }
            offsets[digit] = low
        }
    }

    /// The serial split. Children are appended in octant order and the last one is split first,
    /// which is the order the whole layout follows from. A cell of at most `divert` particles is
    /// handed on instead, with the number of nodes there were when it was reached. A root with a
    /// negative index is not in `out`, and its child count is returned instead.
    private static func split(
        _ root: Work, keys: UnsafeBufferPointer<UInt64>, leafCapacity: Int, maximumDepth: Int,
        divert: Int, into out: inout [BHNode], diverted: (Work, Int) -> Void
    ) -> Int32 {
        var rootChildren: Int32 = 0
        var stack = [root]
        withUnsafeTemporaryAllocation(of: Int.self, capacity: 9) { offsets in
            let offsets = offsets.baseAddress!
            while let work = stack.popLast() {
                if work.count <= leafCapacity || work.depth >= maximumDepth { continue }
                if work.count <= divert {
                    diverted(work, out.count)
                    continue
                }
                octants(keys, work, offsets)
                let childHalf = work.half * 0.5
                let first = out.count
                for octant in 0..<8 {
                    let start = offsets[octant]
                    let size = offsets[octant + 1] - start
                    if size <= 0 { continue }
                    out.append(makeNode(half: childHalf, start: start, count: size))
                    stack.append(
                        Work(
                            start: start, count: size, depth: work.depth + 1, half: childHalf,
                            node: out.count - 1))
                }
                let children = Int32(out.count - first)
                if work.node < 0 {
                    rootChildren = children
                } else {
                    out[work.node].range = Int32(first)
                    out[work.node].signedCount = children
                }
            }
        }
        return rootChildren
    }

    /// The top levels are split serially until every cell left is small, each of those is split
    /// on its own core, and the pieces are then laid out exactly where the serial split would
    /// have put them. That one's order is a depth first walk that appends a cell's children when
    /// it reaches the cell, so everything below a cell lands in one contiguous run, right after
    /// the nodes that existed when it was reached. Only the run's position depends on the rest
    /// of the tree, so the node array is the serial one to the bit.
    private func buildNodes(count: Int, half: Float) {
        let leafCapacity = self.leafCapacity
        let maximumDepth = self.maximumDepth
        // Several cells a core, so one left on an efficiency core does not hold up the rest.
        let divert =
            subtreeParticles ?? max(count / (ProcessInfo.processInfo.activeProcessorCount * 8), 4096)
        top.removeAll(keepingCapacity: true)
        subtrees.removeAll(keepingCapacity: true)
        top.append(Self.makeNode(half: half, start: 0, count: count))
        sortedCodes.withUnsafeBufferPointer { keys in
            _ = Self.split(
                Work(start: 0, count: count, depth: 0, half: half, node: 0), keys: keys,
                leafCapacity: leafCapacity, maximumDepth: maximumDepth, divert: divert, into: &top
            ) { work, insertion in
                subtrees.append(Subtree(work: work, insertion: insertion))
            }
        }

        // Largest first, so the long ones start early and the short ones fill in behind.
        schedule = subtrees.indices.sorted { subtrees[$0].work.count > subtrees[$1].work.count }
        while blocks.count < subtrees.count { blocks.append([]) }
        sortedCodes.withUnsafeBufferPointer { keys in
            subtrees.withUnsafeMutableBufferPointer { subtrees in
                blocks.withUnsafeMutableBufferPointer { blocks in
                    schedule.withUnsafeBufferPointer { schedule in
                        DispatchQueue.concurrentPerform(iterations: schedule.count) { turn in
                            let index = schedule[turn]
                            var work = subtrees[index].work
                            work.node = -1
                            blocks[index].removeAll(keepingCapacity: true)
                            subtrees[index].rootChildren = Self.split(
                                work, keys: keys, leafCapacity: leafCapacity,
                                maximumDepth: maximumDepth, divert: 0, into: &blocks[index]
                            ) { _, _ in }
                            subtrees[index].size = blocks[index].count
                        }
                    }
                }
            }
        }

        topIndices.removeAll(keepingCapacity: true)
        var inserted = 0
        var next = 0
        for index in top.indices {
            while next < subtrees.count && subtrees[next].insertion <= index {
                subtrees[next].base = subtrees[next].insertion + inserted
                inserted += subtrees[next].size
                next += 1
            }
            topIndices.append(index + inserted)
        }
        while next < subtrees.count {
            subtrees[next].base = subtrees[next].insertion + inserted
            inserted += subtrees[next].size
            next += 1
        }

        let total = top.count + inserted
        if spareNodes.count > total {
            spareNodes.removeLast(spareNodes.count - total)
        } else if spareNodes.count < total {
            spareNodes.append(contentsOf: repeatElement(BHNode(), count: total - spareNodes.count))
        }
        spareNodes.withUnsafeMutableBufferPointer { target in
            for index in top.indices {
                var node = top[index]
                if !node.isLeaf { node.range = Int32(topIndices[node.childOffset]) }
                target[topIndices[index]] = node
            }
            for subtree in subtrees {
                let root = topIndices[subtree.work.node]
                target[root].range = Int32(subtree.base)
                target[root].signedCount = subtree.rootChildren
            }
            let target = target
            subtrees.withUnsafeBufferPointer { subtrees in
                blocks.withUnsafeBufferPointer { blocks in
                    DispatchQueue.concurrentPerform(iterations: subtrees.count) { index in
                        let base = subtrees[index].base
                        let offset = Int32(base)
                        blocks[index].withUnsafeBufferPointer { block in
                            for position in block.indices {
                                var node = block[position]
                                if !node.isLeaf { node.range += offset }
                                target[base + position] = node
                            }
                        }
                    }
                }
            }
        }
        // Swapped rather than assigned, for the reason `order` is.
        swap(&nodes, &spareNodes)
    }

    /// A node holds the sum of its children taken last to first, which is the order the serial
    /// fold added them in, so the sums do not depend on how the work was shared out.
    private static func fold(_ nodes: UnsafeMutableBufferPointer<BHNode>, _ index: Int) {
        let node = nodes[index]
        guard !node.isLeaf else { return }
        var sum = SIMD4<Float>.zero
        for child in stride(
            from: node.childOffset + node.childCount - 1, through: node.childOffset, by: -1)
        {
            sum += nodes[child].comMass
        }
        nodes[index].comMass = sum
    }

    /// Leaves sum their own particles, each subtree folds itself on its own core, children
    /// before parents since they always come after them, and the top levels fold last.
    private func accumulate(positions: [SIMD3<Float>], mass: [Float]) {
        let limit = order.count
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
                                // Checked before the unchecked reads below, where a bad range
                                // is a wild address rather than a message. This is what the
                                // segmentation fault of 18 September looked like from the
                                // inside, and a run that has been going for an hour deserves
                                // to be told what went wrong with it.
                                precondition(
                                    start >= 0 && count >= 0 && start + count <= limit,
                                    "noeud \(index) couvre \(start)..<\(start + count) sur \(limit) particules"
                                )
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

        nodes.withUnsafeMutableBufferPointer { nodeBuffer in
            subtrees.withUnsafeBufferPointer { subtrees in
                schedule.withUnsafeBufferPointer { schedule in
                    DispatchQueue.concurrentPerform(iterations: schedule.count) { turn in
                        let subtree = subtrees[schedule[turn]]
                        for index in stride(
                            from: subtree.base + subtree.size - 1, through: subtree.base, by: -1)
                        {
                            Self.fold(nodeBuffer, index)
                        }
                    }
                }
            }
            for index in topIndices.reversed() { Self.fold(nodeBuffer, index) }

            DispatchQueue.concurrentPerform(iterations: chunks) { block in
                for index in block * chunk..<min((block + 1) * chunk, nodeCount) {
                    let total = nodeBuffer[index].comMass.w
                    if total > 0 {
                        let inverse = 1 / total
                        nodeBuffer[index].comMass.x *= inverse
                        nodeBuffer[index].comMass.y *= inverse
                        nodeBuffer[index].comMass.z *= inverse
                    }
                }
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
