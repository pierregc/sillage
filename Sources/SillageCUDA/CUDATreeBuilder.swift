internal import CSillageCUDA
import SillageCore

/// The Barnes-Hut tree built on CUDA (#273), with `GPUTreeBuilder`'s kernels and dispatches: the
/// same tree as `BarnesHutTree` to the bit, laid out level by level.
///
/// On the CPU target the bounds, the sort and the split cannot run (block barriers and warp
/// functions): the cells come from a `BarnesHutTree` laid out in the same buffers, the CPU's
/// own reference, and every kernel after them runs from there.
public final class CUDATreeBuilder {
    public enum Phase: String, CaseIterable, Sendable {
        case bounds, morton, sort, nodes, masses
    }

    public let context: CUDAContext
    public let count: Int
    /// The first position of the buffer the tree is built over: `order` counts from it. The
    /// masses start at their buffer's start.
    public let first: Int
    public let leafCapacity: Int
    public let maximumDepth: Int
    public let quadrupole: Bool
    public let ownOrder: Bool
    let handle: OpaquePointer

    public init(
        context: CUDAContext, count: Int, leafCapacity: Int = 16, maximumDepth: Int = 20,
        quadrupole: Bool = false, nodeCapacity: Int? = nil, first: Int = 0, ownOrder: Bool = true
    ) throws {
        self.context = context
        self.count = max(count, 1)
        self.first = max(first, 0)
        self.leafCapacity = max(leafCapacity, 1)
        self.maximumDepth = min(max(maximumDepth, 1), 21)
        self.quadrupole = quadrupole
        self.ownOrder = ownOrder
        var config = sc_tree_config(
            count: UInt32(self.count), first: UInt32(self.first),
            leaf_capacity: UInt32(self.leafCapacity), maximum_depth: UInt32(self.maximumDepth),
            node_capacity: UInt32(max(nodeCapacity ?? self.count, 1)), quadrupole: quadrupole ? 1 : 0,
            own_order: ownOrder ? 1 : 0)
        var made: OpaquePointer?
        try check(sc_tree_create(context.handle, &config, &made), "a tree of \(count) particles")
        guard let made else { throw CUDAError(.unknown, "no tree") }
        handle = made
    }

    deinit { sc_tree_destroy(handle) }

    private func buffer(_ which: sc_tree_buffer) -> CUDABuffer? {
        sc_tree_buffer_of(handle, which).map {
            CUDABuffer(borrowing: $0, of: self, context: context)
        }
    }

    public var nodeCapacity: Int { Int(sc_tree_node_capacity(handle)) }
    /// `BHNode`s, up to the node capacity. A new buffer after `grow()`.
    public var nodes: CUDABuffer { buffer(SC_TREE_NODES_BUFFER)! }
    /// Two a node with `quadrupole`, as `BarnesHutTree.quadrupoles` lays them out.
    public var moments: CUDABuffer { buffer(SC_TREE_MOMENTS_BUFFER)! }
    /// Particle indices in Morton order, which the traversal reads as `order`.
    public var order: CUDABuffer { buffer(SC_TREE_ORDER_BUFFER)! }
    public var codes: CUDABuffer { buffer(SC_TREE_CODES_BUFFER)! }
    /// The root's corner, the codes' scale, the root's half width, then three zeros.
    public var frame: CUDABuffer { buffer(SC_TREE_FRAME_BUFFER)! }
    /// Per node, what a light tracer's kernel reads (#238), made by `buildSpacing`.
    public var spacing: CUDABuffer? { buffer(SC_TREE_SPACING_BUFFER) }

    private func state() throws -> (nodes: Int, overflowed: Bool) {
        var nodes: UInt32 = 0
        var overflowed: Int32 = 0
        try check(sc_tree_state(handle, &nodes, &overflowed), "the tree's state")
        return (Int(nodes), overflowed != 0)
    }

    public var nodeCount: Int { get throws { try state().nodes } }
    public var overflowed: Bool { get throws { try state().overflowed } }

    /// Where each level starts in `nodes`, the last entry being the node count.
    public var levelStarts: [Int] {
        get throws {
            var starts = [UInt32](repeating: 0, count: maximumDepth + 2)
            try check(
                sc_tree_level_starts(handle, &starts, UInt32(starts.count)), "the level starts")
            return starts.map { Int($0) }
        }
    }

    /// Doubles the node buffers after a build that ran out of them, which then has to run
    /// again: once the flag is up the mass passes stop, so an overflowed build leaves no tree.
    public func grow() throws {
        try check(sc_tree_grow(handle), "growing the tree past \(nodeCapacity) nodes")
    }

    /// The masses phase gathers the particles into `sorted` and sums the leaves from there,
    /// which leaves the force pass nothing to gather.
    public func build(positions: CUDABuffer, mass: CUDABuffer, sorted: CUDABuffer) throws {
        guard CUDAContext.target == .gpu else {
            try layOutCPUTree(positions: positions)
            return try build(.masses, positions: positions, mass: mass, sorted: sorted)
        }
        try check(
            sc_tree_build(handle, positions.handle, mass.handle, sorted.handle), "the tree build")
    }

    /// The cells alone, without the masses: all a smoothing length needs.
    public func buildCells(positions: CUDABuffer) throws {
        guard CUDAContext.target == .gpu else { return try layOutCPUTree(positions: positions) }
        try check(sc_tree_build(handle, positions.handle, nil, nil), "the tree's cells")
    }

    /// One phase, as `GPUTreeBuilder.encode(_:into:positions:mass:sorted:)` encodes it. On the
    /// CPU target the bounds, the sort and the split throw `CUDAError.Code.gpuOnly`.
    public func build(
        _ phase: Phase, positions: CUDABuffer, mass: CUDABuffer?, sorted: CUDABuffer?
    ) throws {
        let which: sc_tree_phase =
            switch phase {
            case .bounds: SC_TREE_BOUNDS
            case .morton: SC_TREE_MORTON
            case .sort: SC_TREE_SORT
            case .nodes: SC_TREE_NODES
            case .masses: SC_TREE_MASSES
            }
        try check(
            sc_tree_build_phase(handle, which, positions.handle, mass?.handle, sorted?.handle),
            "the tree's \(phase) phase")
    }

    /// The smoothing lengths of the first `drawn` particles, from the leaves of the last build,
    /// each standing for `ratio` drawn particles.
    public func buildSmoothing(into lengths: CUDABuffer, drawn: Int, ratio: Float = 1) throws {
        try check(
            sc_tree_smoothing(handle, lengths.handle, UInt32(clamping: max(drawn, 0)), ratio),
            "the smoothing lengths")
    }

    /// The spacing a light tracer reads off this tree for its kernel (#238), cell by cell, from
    /// the first `drawn` particles each standing for `ratio` drawn ones. None past 2^24 nodes.
    public func buildSpacing(drawn: Int, ratio: Float) throws {
        try check(
            sc_tree_spacing(handle, UInt32(clamping: max(drawn, 0)), ratio), "the spacing records")
    }

    /// Sorts `points` positions from `offset` into Morton order, written into `target` from
    /// `targetOffset` and counted from the first of them: the light tracers' walk order (#238).
    /// On a GPU it is the radix sort of the tree, in this builder's own buffers, as
    /// `GPUTreeBuilder.encodeOrder` sorts; on the CPU target a stable sort of the same codes by
    /// the standard library (`BarnesHutTree.mortonOrder`), which gives the same order.
    public func sortOrder(
        positions: CUDABuffer, offset: Int, points: Int, into target: CUDABuffer,
        at targetOffset: Int
    ) throws {
        let points = min(max(points, 0), count)
        guard points > 0, offset >= 0, targetOffset >= 0 else { return }
        guard CUDAContext.target == .gpu else {
            let chunk = try positions.download(SIMD3<Float>.self, count: points, from: offset * 16)
            return try target.upload(BarnesHutTree.mortonOrder(of: chunk), at: targetOffset * 4)
        }
        try check(
            sc_tree_sort_order(
                handle, positions.handle, UInt32(offset), UInt32(points), target.handle,
                UInt32(targetOffset)),
            "sorting \(points) points")
    }

    /// The CPU's tree laid out in this builder's buffers, in the level order, as the cells'
    /// phases leave them, or with its masses and moments too. What the CPU target builds in
    /// place of the bounds, the sort and the split; on a GPU, for tests. A tree of more nodes
    /// than the capacity raises the overflow flag, as a build that runs out does.
    public func upload(_ tree: BarnesHutTree, masses: Bool = false) throws {
        let moments = masses && quadrupole ? tree.quadrupoles : []
        guard let level = BarnesHutTree.levelOrdered(tree.nodes, moments: moments),
            let starts = BarnesHutTree.levelStarts(of: level.nodes, maximumDepth: maximumDepth)
        else {
            throw CUDAError(.invalidArgument, "a tree deeper than \(maximumDepth) or not a tree")
        }
        var cells = level.nodes
        if !masses {
            for index in cells.indices { cells[index].comMass = .zero }
        }
        let levels = starts.map { UInt32($0) }
        let order = tree.order.count == count ? tree.order : nil
        let frame = tree.frame.count == 8 ? tree.frame : nil
        let status = cells.withUnsafeBytes { cells in
            level.moments.withUnsafeBytes { moments in
                order.withUnsafeBufferPointer { order in
                    frame.withUnsafeBufferPointer { frame in
                        sc_tree_upload(
                            handle, cells.baseAddress, UInt32(level.nodes.count),
                            moments.isEmpty ? nil : moments.baseAddress?.assumingMemoryBound(to: Float.self),
                            order?.baseAddress, levels, frame?.baseAddress)
                    }
                }
            }
        }
        try check(status, "laying out a tree of \(level.nodes.count) nodes")
        // The codes the walk reads of a massive particle, by Morton slot (#274).
        if tree.sortedCodes.count == count { try codes.upload(tree.sortedCodes) }
    }

    private func layOutCPUTree(positions: CUDABuffer) throws {
        let points = try positions.download(SIMD3<Float>.self, count: count, from: first * 16)
        let tree = BarnesHutTree(leafCapacity: leafCapacity, maximumDepth: maximumDepth)
        tree.build(positions: points, mass: [Float](repeating: 0, count: count))
        try upload(tree)
    }

    /// How this tree compares with a CPU build over the same positions, with the checks
    /// `GPUTreeBuilder.compare(with:)` makes.
    public func compare(with tree: BarnesHutTree) throws -> TreeComparison {
        let built = try nodeCount
        let nodes = try self.nodes.download(BHNode.self, count: built)
        let order = ownOrder ? try self.order.download(UInt32.self, count: count) : []
        let moments = quadrupole ? try self.moments.download(SIMD4<Float>.self, count: built * 2) : []
        return nodes.withUnsafeBufferPointer { nodes in
            order.withUnsafeBufferPointer { order in
                moments.withUnsafeBufferPointer { moments in
                    tree.compare(nodes: nodes, order: order, moments: quadrupole ? moments : nil)
                }
            }
        }
    }
}

extension Optional where Wrapped == [UInt32] {
    fileprivate func withUnsafeBufferPointer<R>(_ body: (UnsafeBufferPointer<UInt32>?) -> R) -> R {
        guard let self else { return body(nil) }
        return self.withUnsafeBufferPointer { body($0) }
    }
}

extension Optional where Wrapped == [Float] {
    fileprivate func withUnsafeBufferPointer<R>(_ body: (UnsafeBufferPointer<Float>?) -> R) -> R {
        guard let self else { return body(nil) }
        return self.withUnsafeBufferPointer { body($0) }
    }
}
