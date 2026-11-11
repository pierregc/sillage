/// How a tree another engine built compares with a `BarnesHutTree` over the same positions:
/// both are walked from the root, so the two layouts may differ; masses and moments are
/// compared to the bit. `GPUTreeBuilder` and `CUDATreeBuilder` both report it (#273).
public struct TreeComparison: Sendable {
    /// The engine's node count, then the CPU's.
    public var nodes = (gpu: 0, cpu: 0)
    public var orderMatches = false
    public var firstDifference: String?
    public var massesCompared = 0
    public var massesDiffering = 0
    public var largestRelativeGap: Float = 0
    public var momentsCompared = 0
    public var momentsDiffering = 0

    public init() {}
}

extension BarnesHutTree {
    /// Compares an engine's buffers with this tree: its `nodes` in any layout whose siblings
    /// are contiguous and in octant order, its `order`, and its `moments`, two a node, or nil
    /// when it built none.
    public func compare(
        nodes engineNodes: UnsafeBufferPointer<BHNode>, order engineOrder: UnsafeBufferPointer<UInt32>,
        moments engineMoments: UnsafeBufferPointer<SIMD4<Float>>?
    ) -> TreeComparison {
        var result = TreeComparison()
        let engineCount = engineNodes.count
        result.nodes = (engineCount, nodes.count)
        result.orderMatches = order.count == engineOrder.count && order.elementsEqual(engineOrder)
        let cpuNodes = nodes
        guard engineCount > 0, !cpuNodes.isEmpty else {
            if engineCount != cpuNodes.count { result.firstDifference = "one tree is empty" }
            return result
        }
        let compareMoments =
            engineMoments.map { $0.count >= engineCount * 2 } == true
            && quadrupoles.count == cpuNodes.count * 2
        var stack = [(0, 0)]
        while let (g, c) = stack.popLast() {
            guard g < engineCount, c < cpuNodes.count else {
                result.firstDifference = "gpu node \(g) or cpu node \(c) is out of range"
                return result
            }
            let a = engineNodes[g]
            let b = cpuNodes[c]
            if a.packed.x.bitPattern != b.packed.x.bitPattern || a.signedCount != b.signedCount
                || a.digit != b.digit || (a.isLeaf && a.range != b.range)
            {
                result.firstDifference =
                    "gpu node \(g) (\(a.packed.x), \(a.range), \(a.signedCount), \(a.digit)) against"
                    + " cpu node \(c) (\(b.packed.x), \(b.range), \(b.signedCount), \(b.digit))"
                return result
            }
            result.massesCompared += 1
            if !Self.identical(a.comMass, b.comMass) {
                result.massesDiffering += 1
                for axis in 0..<4 {
                    let gap = abs(a.comMass[axis] - b.comMass[axis])
                    let scale = axis == 3 ? abs(b.comMass[3]) : max(abs(b.comMass[axis]), 1e-3)
                    if scale > 0 { result.largestRelativeGap = max(result.largestRelativeGap, gap / scale) }
                }
            }
            if compareMoments, let engineMoments {
                result.momentsCompared += 1
                if !Self.identical(engineMoments[2 * g], quadrupoles[2 * c])
                    || !Self.identical(engineMoments[2 * g + 1], quadrupoles[2 * c + 1])
                {
                    result.momentsDiffering += 1
                }
            }
            if !a.isLeaf {
                for k in 0..<a.childCount { stack.append((a.childOffset + k, b.childOffset + k)) }
            }
        }
        return result
    }

    static func identical(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Bool {
        unsafeBitCast(a, to: SIMD4<UInt32>.self) == unsafeBitCast(b, to: SIMD4<UInt32>.self)
    }
}
