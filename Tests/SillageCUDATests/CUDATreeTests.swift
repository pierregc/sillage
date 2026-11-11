import Foundation
import Testing

@testable import SillageCUDA
@testable import SillageCore
@testable import SillageRender

#if canImport(simd)
    import simd
#endif

/// The tree's kernels with block barriers and warp functions, and the large sizes, run on a GPU
/// only: #283 runs these on its first box.
private let onAGPU = CUDAContext.runsEveryKernel
private let needsAGPU: Comment = "needs an NVIDIA GPU and libsillagecuda.a: #283 runs it"

/// The CUDA tree builder against the CPU's `BarnesHutTree` (#273), with `GPUTreeTests`' checks.
/// On the CPU target the cells come from a `BarnesHutTree` laid out by `sc_tree_upload`, and the
/// masses, moments, lengths and spacing records from the CUDA entry points run on the CPU.
@Suite("CUDA tree")
struct CUDATreeTests {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/engines/tree")

    private func positions(_ set: String, count: Int) -> [SIMD3<Float>] {
        var generator = SeededGenerator(seed: 5)
        return (0..<count).map { index in
            let direction = SIMD3<Float>(generator.normal(), generator.normal(), generator.normal())
            switch set {
            case "merged core": return direction * (index % 10 == 0 ? 400 : 0.002)
            case "duplicates": return SIMD3<Float>(Float(index % 7), 0, 1)
            default: return direction * SIMD3<Float>(7, 7, 2)
            }
        }
    }

    private func masses(_ count: Int) -> [Float] {
        var generator = SeededGenerator(seed: 9)
        return (0..<count).map { _ in Float(0.001 + 0.002 * generator.uniform()) }
    }

    private struct Built {
        var builder: CUDATreeBuilder
        var tree: BarnesHutTree
        var grown: Int
        var positions: CUDABuffer
    }

    private func build(
        _ points: [SIMD3<Float>], mass: [Float]? = nil, quadrupole: Bool, nodeCapacity: Int? = nil
    ) throws -> Built {
        let context = try CUDAContext()
        let count = points.count
        let mass = mass ?? masses(count)
        let tree = BarnesHutTree(leafCapacity: 16, maximumDepth: 20)
        tree.computesQuadrupoles = quadrupole
        tree.build(positions: points, mass: mass)

        let builder = try CUDATreeBuilder(
            context: context, count: count, quadrupole: quadrupole, nodeCapacity: nodeCapacity)
        let positionBuffer = try context.makeBuffer(points)
        let massBuffer = try context.makeBuffer(mass)
        let sorted = try context.makeBuffer(length: count * 16)
        var grown = 0
        repeat {
            if try builder.overflowed {
                try builder.grow()
                grown += 1
            }
            try builder.build(positions: positionBuffer, mass: massBuffer, sorted: sorted)
            try context.synchronize()
        } while try builder.overflowed && grown < 20
        return Built(builder: builder, tree: tree, grown: grown, positions: positionBuffer)
    }

    private func expectSameTree(_ builder: CUDATreeBuilder, _ tree: BarnesHutTree) throws {
        #expect(try !builder.overflowed)
        let comparison = try builder.compare(with: tree)
        #expect(comparison.nodes.gpu == comparison.nodes.cpu)
        #expect(comparison.orderMatches)
        #expect(comparison.firstDifference == nil, "\(comparison.firstDifference ?? "")")
        #expect(comparison.massesCompared == comparison.nodes.cpu)
        #expect(
            comparison.massesDiffering == 0,
            "\(comparison.massesDiffering) masses differ, by up to \(comparison.largestRelativeGap)")
        if builder.quadrupole {
            #expect(comparison.momentsCompared == comparison.nodes.cpu)
            #expect(comparison.momentsDiffering == 0, "\(comparison.momentsDiffering) moments differ")
        }
    }

    /// The builder's cells in the level order, with their spacing records moved along: the
    /// layout the fixture holds, whatever order a GPU's atomics gave a level.
    private func canonical(_ builder: CUDATreeBuilder) throws -> (
        nodes: [BHNode], moments: [SIMD4<Float>], spacing: [SIMD2<UInt32>]
    ) {
        let count = try builder.nodeCount
        let nodes = try builder.nodes.download(BHNode.self, count: count)
        let moments =
            builder.quadrupole ? try builder.moments.download(SIMD4<Float>.self, count: count * 2) : []
        let sources = try #require(BarnesHutTree.levelOrder(of: nodes))
        let level = try #require(BarnesHutTree.levelOrdered(nodes, moments: moments))
        let records = try builder.spacing?.download(SIMD2<UInt32>.self, count: count) ?? []
        let spacing =
            records.isEmpty
            ? [] : BarnesHutTree.levelOrdered(spacing: records, sources: sources, ordered: level.nodes)
        return (level.nodes, level.moments, spacing)
    }

    /// The lengths and spacing records the CPU works out from its own tree, in the level order:
    /// the drawn particles of each leaf, summed up the tree, each standing for `ratio`.
    private func expected(
        _ tree: BarnesHutTree, drawn: Int, ratio: Float
    ) throws -> (lengths: [Float], spacing: [SIMD2<UInt32>]) {
        let nodes = try #require(BarnesHutTree.levelOrdered(tree.nodes)).nodes
        let order = tree.order
        var lengths = [Float](repeating: 0, count: drawn)
        var counted = [UInt32](repeating: 0, count: nodes.count)
        func length(_ node: BHNode, _ drawn: UInt32) -> Float {
            drawn == 0 ? 0 : sqrt(max(node.packed.x, 1e-12)) * pow(1 / (Float(drawn) * ratio), 1.0 / 3.0)
        }
        for (index, node) in nodes.enumerated() where node.isLeaf {
            let slots = node.particleStart..<node.particleStart + node.particleCount
            counted[index] = UInt32(slots.filter { order[$0] < drawn }.count)
            for slot in slots where order[slot] < drawn {
                lengths[Int(order[slot])] = length(node, counted[index])
            }
        }
        for index in nodes.indices.reversed() where !nodes[index].isLeaf {
            let children = nodes[index].childOffset..<nodes[index].childOffset + nodes[index].childCount
            counted[index] = children.reduce(0) { $0 + counted[$1] }
        }
        let spacing = nodes.enumerated().map { index, node in
            var mask: UInt32 = 0
            for child in node.childOffset..<node.childOffset + node.childCount where !node.isLeaf {
                mask |= 1 << (nodes[child].digit & 7)
            }
            return SIMD2<UInt32>(
                length(node, counted[index]).bitPattern,
                node.isLeaf ? 0 : UInt32(node.childOffset) << 8 | mask)
        }
        return (lengths, spacing)
    }

    /// How many lengths lie further than 1e-6 apart: they go through pow, which no two math
    /// libraries round alike.
    private func far(_ mine: [Float], _ theirs: [Float]) -> Int {
        guard mine.count == theirs.count else { return max(mine.count, theirs.count) }
        var count = 0
        for (a, b) in zip(mine, theirs) where a != b {
            let gap: Float = abs(a - b) / max(abs(b), 1e-30)
            if gap > 1e-6 { count += 1 }
        }
        return count
    }

    private func expectSameLengths(
        _ builder: CUDATreeBuilder, _ tree: BarnesHutTree, drawn: Int, ratio: Float
    ) throws {
        let lengths = try builder.context.makeBuffer(length: drawn * 4)
        try builder.buildSmoothing(into: lengths, drawn: drawn, ratio: ratio)
        try builder.buildSpacing(drawn: drawn, ratio: ratio)
        let reference = try expected(tree, drawn: drawn, ratio: ratio)
        #expect(far(try lengths.download(Float.self, count: drawn), reference.lengths) == 0)
        let records = try canonical(builder).spacing
        #expect(records.map(\.y) == reference.spacing.map(\.y))
        #expect(
            far(records.map { Float(bitPattern: $0.x) }, reference.spacing.map { Float(bitPattern: $0.x) })
                == 0)
    }

    /// The CUDA build is the CPU build, laid out by level: same order to the bit, same cells,
    /// same masses, same second moments.
    @Test(
        arguments: [
            ("disk", 200_000), ("merged core", 200_000), ("duplicates", 5_000), ("disk", 1),
            ("disk", 17), ("disk", 2_049),
        ], [false, true])
    func theCUDATreeIsTheCPUTree(set: (String, Int), quadrupole: Bool) throws {
        let built = try build(positions(set.0, count: set.1), quadrupole: quadrupole)
        try expectSameTree(built.builder, built.tree)
    }

    @Test func aMergedCoreReachesTheDepthCeiling() throws {
        let built = try build(positions("merged core", count: 200_000), quadrupole: true)
        let levels = try built.builder.levelStarts
        #expect(levels[20] < levels[21])
        try expectSameTree(built.builder, built.tree)
    }

    /// A node buffer that turns out too small grows, and the build that runs again is whole.
    @Test func aTreeThatOutgrowsItsNodesIsBuiltAgain() throws {
        let built = try build(
            positions("disk", count: 200_000), quadrupole: true, nodeCapacity: 1_000)
        #expect(built.grown > 0)
        try expectSameTree(built.builder, built.tree)
    }

    /// `sc_tree_upload` lays the CPU's tree out as a build leaves it, masses and moments
    /// included: the same tree through the comparison.
    @Test func aLaidOutTreeIsTheCPUTree() throws {
        let context = try CUDAContext()
        let points = positions("disk", count: 30_000)
        let tree = BarnesHutTree()
        tree.computesQuadrupoles = true
        tree.build(positions: points, mass: masses(points.count))
        let builder = try CUDATreeBuilder(context: context, count: points.count, quadrupole: true)
        try builder.upload(tree, masses: true)
        try expectSameTree(builder, tree)
        let frame = try builder.frame.download(Float.self, count: 8)
        #expect(frame.map(\.bitPattern) == tree.frame.map(\.bitPattern))
    }

    /// The engines' reference tree (#281): the order, the cells, the masses, the moments, the
    /// frame and the levels to the bit, the lengths to 1e-6, the links of the spacing records to
    /// the bit.
    @Test func theFixtureTree() throws {
        func file(_ name: String) throws -> Data {
            try Data(contentsOf: Self.fixtures.appendingPathComponent(name))
        }
        func values<T>(_ data: Data, _ type: T.Type) -> [T] {
            data.withUnsafeBytes { Array($0.bindMemory(to: T.self)) }
        }
        func bytes<T>(_ values: [T]) -> Data { values.withUnsafeBytes { Data($0) } }
        let points = values(try file("positions.bin"), SIMD4<Float>.self).map {
            SIMD3<Float>($0.x, $0.y, $0.z)
        }
        let mass = values(try file("mass.bin"), Float.self)
        let built = try build(points, mass: mass, quadrupole: true)
        let builder = built.builder
        let drawn = 16_000
        let lengths = try builder.context.makeBuffer(length: drawn * 4)
        try builder.buildSmoothing(into: lengths, drawn: drawn, ratio: 4)
        try builder.buildSpacing(drawn: drawn, ratio: 4)
        let tree = try canonical(builder)
        #expect(
            bytes(try builder.order.download(UInt32.self, count: points.count)) == (try file("order.bin")))
        #expect(bytes(tree.nodes) == (try file("nodes.bin")))
        #expect(bytes(tree.moments) == (try file("moments.bin")))
        #expect(bytes(try builder.frame.download(Float.self, count: 8)) == (try file("frame.bin")))
        #expect(bytes(try builder.levelStarts.map { UInt32($0) }) == (try file("levels.bin")))
        #expect(
            far(try lengths.download(Float.self, count: drawn), values(try file("smoothing.bin"), Float.self))
                == 0)
        let spacing = values(try file("spacing.bin"), SIMD2<UInt32>.self)
        #expect(tree.spacing.map(\.y) == spacing.map(\.y))
        #expect(
            far(tree.spacing.map { Float(bitPattern: $0.x) }, spacing.map { Float(bitPattern: $0.x) }) == 0)

        // The cells alone are all a smoothing length needs.
        let cells = try CUDATreeBuilder(context: builder.context, count: points.count)
        try cells.buildCells(positions: built.positions)
        let alone = try builder.context.makeBuffer(length: drawn * 4)
        try cells.buildSmoothing(into: alone, drawn: drawn, ratio: 4)
        #expect(try alone.download(Float.self, count: drawn) == lengths.download(Float.self, count: drawn))
    }

    /// The lengths and spacing records are the ones the CPU works out from its own tree.
    @Test(arguments: ["disk", "merged core"])
    func theLengthsAreTheCPUs(set: String) throws {
        let built = try build(positions(set, count: 100_000), quadrupole: false)
        try expectSameLengths(built.builder, built.tree, drawn: 75_000, ratio: 4)
    }

    /// A chunk of positions sorts into its own Morton order, the light tracers' walk order.
    @Test func aChunkSortsIntoMortonOrder() throws {
        let context = try CUDAContext()
        let points = positions("disk", count: 40_000)
        let builder = try CUDATreeBuilder(context: context, count: 40_000, ownOrder: false)
        let buffer = try context.makeBuffer(points)
        let target = try context.makeBuffer(length: (100 + 30_000) * 4)
        try builder.sortOrder(positions: buffer, offset: 5_000, points: 30_000, into: target, at: 100)
        let tree = BarnesHutTree()
        tree.build(positions: Array(points[5_000..<35_000]), mass: [Float](repeating: 0, count: 30_000))
        #expect(try target.download(UInt32.self, count: 30_000, from: 400) == tree.order)
        #expect(try target.download(UInt32.self, count: 100) == [UInt32](repeating: 0, count: 100))
    }

    /// The CPU target says which phases it leaves to a GPU, and runs the rest.
    @Test(.enabled(if: CUDAContext.target == .cpu, "the CPU target only"))
    func theCPUTargetLeavesTheBarriersToAGPU() throws {
        let context = try CUDAContext()
        let points = positions("disk", count: 3_000)
        let builder = try CUDATreeBuilder(context: context, count: points.count)
        let buffer = try context.makeBuffer(points)
        for phase in [CUDATreeBuilder.Phase.bounds, .sort, .nodes] {
            let error = #expect(throws: CUDAError.self) {
                try builder.build(phase, positions: buffer, mass: nil, sorted: nil)
            }
            #expect(error?.code == .gpuOnly)
            #expect(error?.message.contains("#283") == true)
        }
        try builder.buildCells(positions: buffer)
        try builder.build(.morton, positions: buffer, mass: nil, sorted: nil)
        let codes = try builder.codes.download(UInt64.self, count: points.count)
        let tree = BarnesHutTree()
        tree.build(positions: points, mass: [Float](repeating: 0, count: points.count))
        let frame = tree.frame
        let origin = SIMD3<Float>(frame[0], frame[1], frame[2])
        let expected = points.map { point -> UInt64 in
            let local = (point - origin) * frame[3]
            return BarnesHutTree.morton(
                UInt32(min(max(local.x, 0), 2_097_151)), UInt32(min(max(local.y, 0), 2_097_151)),
                UInt32(min(max(local.z, 0), 2_097_151)))
        }
        #expect(codes == expected)
    }

    // MARK: - On a GPU only (#283)

    /// A 500 k merger at t = 0, sampled where the test runs.
    @Test(.enabled(if: onAGPU, needsAGPU))
    func aMergerAtTheStart() throws {
        let system = RestrictedSolver.sampleParticles(for: SceneConfig.merger(particleCount: 500_000))
        let built = try build(system.positions, mass: system.mass, quadrupole: true)
        try expectSameTree(built.builder, built.tree)
        try expectSameLengths(built.builder, built.tree, drawn: system.count / 2, ratio: 4)
    }

    /// The same merger after 200 steps: the last frame of a take of a Metal run, so that no CUDA
    /// solver is needed.
    @Test(
        .enabled(if: onAGPU, needsAGPU),
        .enabled(
            if: ProcessInfo.processInfo.environment["SILLAGE_CUDA_TREE_TAKE"] != nil,
            "SILLAGE_CUDA_TREE_TAKE names the take: docs/notes/cuda-engine.md"))
    func aMergerAfter200Steps() throws {
        let path = try #require(ProcessInfo.processInfo.environment["SILLAGE_CUDA_TREE_TAKE"])
        let loaded = try RecordingFile.read(from: URL(fileURLWithPath: path))
        let points = loaded.recording.positions(at: loaded.recording.count - 1)
        let mass = loaded.particles.mass.count == points.count ? loaded.particles.mass : nil
        let built = try build(points, mass: mass, quadrupole: true)
        try expectSameTree(built.builder, built.tree)
        try expectSameLengths(built.builder, built.tree, drawn: points.count, ratio: 1)
    }

    /// The 5 M massive particles of #283's 8 M walk dump.
    @Test(
        .enabled(if: onAGPU, needsAGPU),
        .enabled(
            if: ProcessInfo.processInfo.environment["SILLAGE_CUDA_TREE_DUMP"] != nil,
            "SILLAGE_CUDA_TREE_DUMP names the walk dump: docs/notes/cuda-engine.md"))
    func theMassiveParticlesOfADump() throws {
        let folder = try #require(ProcessInfo.processInfo.environment["SILLAGE_CUDA_TREE_DUMP"])
        let points = try massive(of: folder)
        let built = try build(points, quadrupole: true)
        try expectSameTree(built.builder, built.tree)
    }

    private func massive(of folder: String) throws -> [SIMD3<Float>] {
        let data = try Data(contentsOf: URL(fileURLWithPath: folder).appendingPathComponent("massive.bin"))
        return data.withUnsafeBytes { Array($0.bindMemory(to: SIMD3<Float>.self)) }
    }

    /// The build timed at 2 M and 5 M, against 11 ms on the M4 Max at 5 M (gpu-tree.md).
    @Test(.enabled(if: onAGPU, needsAGPU), arguments: [2_000_000, 5_000_000])
    func theBuildIsTimed(count: Int) throws {
        let points: [SIMD3<Float>]
        if let folder = ProcessInfo.processInfo.environment["SILLAGE_CUDA_TREE_DUMP"],
            let held = try? massive(of: folder), held.count >= count
        {
            points = Array(held.prefix(count))
        } else {
            points =
                RestrictedSolver.sampleParticles(for: SceneConfig.merger(particleCount: count))
                .positions
        }
        let built = try build(points, quadrupole: true)
        try expectSameTree(built.builder, built.tree)
        let context = built.builder.context
        let mass = try context.makeBuffer(masses(points.count))
        let sorted = try context.makeBuffer(length: points.count * 16)
        var times: [Double] = []
        for _ in 0..<11 {
            let clock = Date()
            try built.builder.build(positions: built.positions, mass: mass, sorted: sorted)
            try context.synchronize()
            times.append(Date().timeIntervalSince(clock) * 1000)
        }
        let median = times.dropFirst().sorted()[5]
        print(
            "CUDATREE \(context.name) \(points.count) particles: \(String(format: "%.2f", median)) ms a build"
        )
    }
}
