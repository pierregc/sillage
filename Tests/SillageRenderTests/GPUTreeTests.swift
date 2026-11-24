import Metal
import Testing

@testable import SillageCore
@testable import SillageRender

#if canImport(simd)
    import simd
#else
    import Foundation
#endif

@Suite("GPU tree")
struct GPUTreeTests {
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

    private func build(
        _ set: String, count: Int, quadrupole: Bool, nodeCapacity: Int? = nil
    ) throws -> (builder: GPUTreeBuilder, tree: BarnesHutTree, grown: Int) {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let points = positions(set, count: count)
        var generator = SeededGenerator(seed: 9)
        let mass = (0..<count).map { _ in Float(0.001 + 0.002 * generator.uniform()) }

        let tree = BarnesHutTree(leafCapacity: 16, maximumDepth: 20)
        tree.computesQuadrupoles = quadrupole
        tree.build(positions: points, mass: mass)

        let builder = try GPUTreeBuilder(
            device: device, count: count, quadrupole: quadrupole, nodeCapacity: nodeCapacity)
        let positionBuffer = try #require(
            device.makeBuffer(
                bytes: points, length: count * MemoryLayout<SIMD3<Float>>.stride,
                options: .storageModeShared))
        let massBuffer = try #require(
            device.makeBuffer(bytes: mass, length: count * 4, options: .storageModeShared))
        let sorted = try #require(
            device.makeBuffer(length: count * 16, options: .storageModePrivate))
        let queue = try #require(device.makeCommandQueue())
        var grown = 0
        repeat {
            if builder.overflowed {
                try builder.grow()
                grown += 1
            }
            let buffer = try #require(queue.makeCommandBuffer())
            builder.encode(into: buffer, positions: positionBuffer, mass: massBuffer, sorted: sorted)
            buffer.commit()
            buffer.waitUntilCompleted()
            #expect(buffer.error == nil)
        } while builder.overflowed && grown < 20
        return (builder, tree, grown)
    }

    private func expectSameTree(_ builder: GPUTreeBuilder, _ tree: BarnesHutTree) {
        #expect(!builder.overflowed)
        let comparison = builder.compare(with: tree)
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

    /// The GPU build is the CPU build, laid out by level: same order to the bit, same cells,
    /// same masses, same second moments.
    @Test(
        arguments: [
            ("disk", 200_000), ("merged core", 200_000), ("duplicates", 5_000), ("disk", 1),
            ("disk", 17), ("disk", 2_049),
        ], [false, true])
    func theGPUTreeIsTheCPUTree(set: (String, Int), quadrupole: Bool) throws {
        let (builder, tree, _) = try build(set.0, count: set.1, quadrupole: quadrupole)
        expectSameTree(builder, tree)
    }

    /// The case the depth ceiling exists for, so it had better be reached here.
    @Test func aMergedCoreReachesTheDepthCeiling() throws {
        let (builder, tree, _) = try build("merged core", count: 200_000, quadrupole: true)
        let levels = builder.levelStarts
        #expect(levels[20] < levels[21])
        expectSameTree(builder, tree)
    }

    /// A node buffer that turns out too small grows, and the build that runs again is whole.
    @Test func aTreeThatOutgrowsItsNodesIsBuiltAgain() throws {
        let (builder, tree, grown) = try build(
            "disk", count: 200_000, quadrupole: true, nodeCapacity: 1_000)
        #expect(grown > 0)
        expectSameTree(builder, tree)
    }
    /// Playback's lengths come from a tree built on the GPU, and are the ones a CPU tree gives.
    @Test(arguments: ["disk", "merged core"])
    func playbackSmoothingMatchesTheCPUField(set: String) throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let count = 100_000
        let points = positions(set, count: count)
        let cpu = try SmoothingField(device: device, particleCount: count)
        cpu.update(positions: points)
        let gpu = try SmoothingField(device: device, particleCount: count)
        let buffer = try #require(
            device.makeBuffer(
                bytes: points, length: count * MemoryLayout<SIMD3<Float>>.stride,
                options: .storageModeShared))
        gpu.update(from: buffer)
        let expected = cpu.buffer.contents().bindMemory(to: Float.self, capacity: count)
        let lengths = gpu.buffer.contents().bindMemory(to: Float.self, capacity: count)
        var worst: Float = 0
        for index in 0..<count {
            worst = max(worst, abs(lengths[index] - expected[index]) / expected[index])
        }
        #expect(worst < 1e-5)
    }

    /// With `emitting` set, the stars' lengths come from a tree of the stars alone: a star in a
    /// dense clump of grains keeps its neighbours' length, the grains keep theirs, and a star
    /// far from any grain is about where it was (#478).
    @Test func emittingParticlesTakeTheirLengthsFromEachOther() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        var generator = SeededGenerator(seed: 9)
        // 60 000 stars spread through a box 20 kpc wide, 40 000 grains packed in 0.2 kpc round
        // the centre, where a few stars stand among them.
        var points = (0..<59_980).map { _ in
            SIMD3<Float>(
                generator.uniform() * 20 - 10, generator.uniform() * 20 - 10, generator.uniform() * 20 - 10)
        }
        points += (0..<20).map { _ in
            SIMD3<Float>(
                generator.uniform() * 0.1 - 0.05, generator.uniform() * 0.1 - 0.05,
                generator.uniform() * 0.1 - 0.05)
        }
        points += (0..<40_000).map { _ in
            SIMD3<Float>(
                generator.uniform() * 0.2 - 0.1, generator.uniform() * 0.2 - 0.1,
                generator.uniform() * 0.2 - 0.1)
        }
        let count = points.count
        let buffer = try #require(
            device.makeBuffer(
                bytes: points, length: count * MemoryLayout<SIMD3<Float>>.stride, options: .storageModeShared)
        )
        let stars = (0..<60_000).map { UInt32($0) }
        let inside = Array(59_980..<60_000)
        let far = (0..<60_000).filter { simd_length(points[$0]) > 5 }.prefix(2000)
        func lengths(_ emitting: [UInt32]?) throws -> [Float] {
            let field = try SmoothingField(device: device, particleCount: count)
            field.emitting = emitting
            field.update(from: buffer)
            return Array(
                UnsafeBufferPointer(
                    start: field.buffer.contents().bindMemory(to: Float.self, capacity: count), count: count))
        }
        let plain = try lengths(nil)
        let apart = try lengths(stars)
        try #require(!inside.isEmpty)
        // In the clump a star took the grains' tiny spacing; apart, the stars' own.
        let before = inside.map { plain[$0] }.reduce(0, +) / Float(inside.count)
        let after = inside.map { apart[$0] }.reduce(0, +) / Float(inside.count)
        #expect(after > 5 * before, "\(before) -> \(after)")
        // The grains keep theirs, and a star far from the clump keeps its length.
        #expect((60_000..<count).allSatisfy { apart[$0] == plain[$0] })
        let drift = far.map { abs(apart[$0] / plain[$0] - 1) }.reduce(0, +) / Float(far.count)
        #expect(drift < 0.02, "\(drift)")
    }
}
