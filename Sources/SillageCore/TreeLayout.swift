#if canImport(simd)
    import simd
#endif

extension BarnesHutTree {
    /// Where each cell of the level order is in `nodes`: the root, then level by level, each
    /// level's cells in their parents' order and a parent's children as they are, contiguous
    /// and in octant order. It is `GPUTreeBuilder`'s layout without its freedom from run to
    /// run, so two builds of one tree give the same bytes whatever layout they came in (#281).
    /// Nil when a child lies outside `nodes` or the cells are not a tree.
    public static func levelOrder(of nodes: [BHNode]) -> [Int]? {
        guard !nodes.isEmpty else { return [] }
        var sources = [0]
        sources.reserveCapacity(nodes.count)
        var next = 0
        while next < sources.count {
            let node = nodes[sources[next]]
            next += 1
            guard !node.isLeaf else { continue }
            let first = node.childOffset
            guard first > 0, first + node.childCount <= nodes.count,
                sources.count + node.childCount <= nodes.count
            else { return nil }
            sources.append(contentsOf: first..<first + node.childCount)
        }
        return sources
    }

    /// `nodes` in the level order, a branch's `range` following its children, with their
    /// `moments`, two a node or none.
    public static func levelOrdered(
        _ nodes: [BHNode], moments: [SIMD4<Float>] = []
    ) -> (nodes: [BHNode], moments: [SIMD4<Float>])? {
        guard moments.isEmpty || moments.count == nodes.count * 2,
            let sources = levelOrder(of: nodes)
        else { return nil }
        var ordered: [BHNode] = []
        ordered.reserveCapacity(sources.count)
        var children = 1
        for source in sources {
            var node = nodes[source]
            if !node.isLeaf {
                node.range = Int32(children)
                children += node.childCount
            }
            ordered.append(node)
        }
        var moved: [SIMD4<Float>] = []
        if !moments.isEmpty {
            moved.reserveCapacity(sources.count * 2)
            for source in sources {
                moved.append(moments[2 * source])
                moved.append(moments[2 * source + 1])
            }
        }
        return (ordered, moved)
    }
}
