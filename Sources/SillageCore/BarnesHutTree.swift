import simd

/// One cell of the tree, laid out for a Metal buffer.
public struct BHNode: Sendable {
    /// Centre of mass in xyz, total mass in w.
    public var comMass: SIMD4<Float>
    /// Cell centre in xyz, half width in w.
    public var bounds: SIMD4<Float>
    /// First child, child count, first particle, particle count.
    public var links: SIMD4<Int32>

    public init() {
        comMass = .zero
        bounds = .zero
        links = SIMD4<Int32>(-1, 0, 0, 0)
    }
}

/// Barnes-Hut octree, built on the CPU and traversed on the GPU.
///
/// Building the tree is the awkward half of a GPU N-body solver: it wants a radix sort and a
/// pointerless hierarchy. On unified memory the CPU can read the same buffer the GPU writes,
/// so the build happens here in Morton order while the traversal, which is where the time
/// actually goes, stays on the GPU.
public final class BarnesHutTree {
    public private(set) var nodes: [BHNode] = []
    /// Particle indices in Morton order. Leaves address particles through this.
    public private(set) var order: [UInt32] = []

    public let leafCapacity: Int
    public let maximumDepth: Int

    private var codes: [UInt32] = []
    private var scratch: [UInt32] = []
    private var parents: [Int32] = []

    public init(leafCapacity: Int = 16, maximumDepth: Int = 10) {
        self.leafCapacity = max(leafCapacity, 1)
        self.maximumDepth = min(max(maximumDepth, 1), 10)
    }

    /// Spreads the low 10 bits of a value so three of them interleave into a Morton code.
    static func spread(_ value: UInt32) -> UInt32 {
        var x = value & 0x3FF
        x = (x | (x << 16)) & 0x0300_00FF
        x = (x | (x << 8)) & 0x0300_F00F
        x = (x | (x << 4)) & 0x030C_30C3
        x = (x | (x << 2)) & 0x0924_9249
        return x
    }

    static func morton(_ x: UInt32, _ y: UInt32, _ z: UInt32) -> UInt32 {
        (spread(x) << 2) | (spread(y) << 1) | spread(z)
    }

    /// The octant digit a code takes at a given depth, as (x, y, z) bits.
    static func octant(_ code: UInt32, depth: Int) -> Int {
        Int((code >> UInt32(27 - 3 * depth)) & 7)
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

        codes = [UInt32](repeating: 0, count: count)
        let resolution: Float = 1023
        let inverse = resolution / (2 * half)
        for index in 0..<count {
            let local = (positions[index] - (center - SIMD3<Float>(repeating: half))) * inverse
            let x = UInt32(min(max(local.x, 0), resolution))
            let y = UInt32(min(max(local.y, 0), resolution))
            let z = UInt32(min(max(local.z, 0), resolution))
            codes[index] = BarnesHutTree.morton(x, y, z)
        }

        order = sortedByCode(count: count)
        buildNodes(count: count, center: center, half: half)
        accumulate(positions: positions, mass: mass)
    }

    /// Least significant digit radix sort, eight bits per pass.
    private func sortedByCode(count: Int) -> [UInt32] {
        var current = [UInt32](repeating: 0, count: count)
        for index in 0..<count { current[index] = UInt32(index) }
        if scratch.count != count { scratch = [UInt32](repeating: 0, count: count) }

        var histogram = [Int](repeating: 0, count: 256)
        for shift in stride(from: 0, to: 32, by: 8) {
            for bucket in 0..<256 { histogram[bucket] = 0 }
            for index in current { histogram[Int((codes[Int(index)] >> UInt32(shift)) & 255)] += 1 }
            var total = 0
            for bucket in 0..<256 {
                let value = histogram[bucket]
                histogram[bucket] = total
                total += value
            }
            for index in current {
                let bucket = Int((codes[Int(index)] >> UInt32(shift)) & 255)
                scratch[histogram[bucket]] = index
                histogram[bucket] += 1
            }
            swap(&current, &scratch)
        }
        return current
    }

    private struct Work {
        var start: Int
        var count: Int
        var depth: Int
        var center: SIMD3<Float>
        var half: Float
        var node: Int
    }

    private func makeNode(center: SIMD3<Float>, half: Float, start: Int, count: Int, parent: Int32)
        -> Int
    {
        var node = BHNode()
        node.bounds = SIMD4<Float>(center.x, center.y, center.z, half)
        node.links = SIMD4<Int32>(-1, 0, Int32(start), Int32(count))
        nodes.append(node)
        parents.append(parent)
        return nodes.count - 1
    }

    private func buildNodes(count: Int, center: SIMD3<Float>, half: Float) {
        nodes.reserveCapacity(count / max(leafCapacity, 1) * 2 + 16)
        let root = makeNode(center: center, half: half, start: 0, count: count, parent: -1)
        var stack = [Work(start: 0, count: count, depth: 0, center: center, half: half, node: root)]

        while let work = stack.popLast() {
            if work.count <= leafCapacity || work.depth >= maximumDepth { continue }

            // Morton order means the eight octants are already contiguous runs.
            var offsets = [Int](repeating: work.start + work.count, count: 9)
            offsets[0] = work.start
            var digit = 0
            for position in work.start..<(work.start + work.count) {
                let value = BarnesHutTree.octant(codes[Int(order[position])], depth: work.depth)
                while digit < value {
                    digit += 1
                    offsets[digit] = position
                }
            }
            while digit < 8 {
                digit += 1
                offsets[digit] = work.start + work.count
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
                    center: childCenter, half: childHalf, start: start, count: size,
                    parent: Int32(work.node))
                if firstChild < 0 { firstChild = index }
                childCount += 1
                stack.append(
                    Work(
                        start: start, count: size, depth: work.depth + 1, center: childCenter,
                        half: childHalf, node: index))
            }
            nodes[work.node].links.x = Int32(firstChild)
            nodes[work.node].links.y = childCount
        }
    }

    /// Leaves sum their own particles, then every node folds into its parent. Children are
    /// always created after their parent, so one reverse pass is enough.
    private func accumulate(positions: [SIMD3<Float>], mass: [Float]) {
        for index in nodes.indices { nodes[index].comMass = .zero }

        for index in nodes.indices where nodes[index].links.y == 0 {
            let start = Int(nodes[index].links.z)
            let count = Int(nodes[index].links.w)
            var weighted = SIMD3<Float>.zero
            var total: Float = 0
            for position in start..<(start + count) {
                let particle = Int(order[position])
                let m = mass.isEmpty ? 1 : mass[particle]
                weighted += positions[particle] * m
                total += m
            }
            nodes[index].comMass = SIMD4<Float>(weighted.x, weighted.y, weighted.z, total)
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
