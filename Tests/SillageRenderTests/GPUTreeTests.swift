import Metal
import Testing
import simd

@testable import SillageCore
@testable import SillageRender

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

    /// The GPU build is the CPU build, laid out by level: same order to the bit, same cells,
    /// same masses.
    @Test(
        arguments: [
            ("disk", 200_000), ("merged core", 200_000), ("duplicates", 5_000), ("disk", 1),
            ("disk", 17), ("disk", 2_049),
        ], [false, true])
    func theGPUTreeIsTheCPUTree(set: (String, Int), gathered: Bool) throws {
        let (set, count) = set
        let device = try #require(MTLCreateSystemDefaultDevice())
        let points = positions(set, count: count)
        var generator = SeededGenerator(seed: 9)
        let mass = (0..<count).map { _ in Float(0.001 + 0.002 * generator.uniform()) }

        let tree = BarnesHutTree(leafCapacity: 16, maximumDepth: 20)
        tree.build(positions: points, mass: mass)

        let builder = try GPUTreeBuilder(device: device, count: count)
        let positionBuffer = try #require(
            device.makeBuffer(
                bytes: points, length: count * MemoryLayout<SIMD3<Float>>.stride,
                options: .storageModeShared))
        let massBuffer = try #require(
            device.makeBuffer(bytes: mass, length: count * 4, options: .storageModeShared))
        let queue = try #require(device.makeCommandQueue())
        let buffer = try #require(queue.makeCommandBuffer())
        let sorted = try #require(
            device.makeBuffer(length: count * 16, options: .storageModePrivate))
        builder.encode(
            into: buffer, positions: positionBuffer, mass: massBuffer, sorted: gathered ? sorted : nil)
        buffer.commit()
        buffer.waitUntilCompleted()
        #expect(buffer.error == nil)
        #expect(!builder.overflowed)

        let comparison = builder.compare(with: tree)
        #expect(comparison.nodes.gpu == comparison.nodes.cpu)
        #expect(comparison.orderMatches)
        #expect(comparison.firstDifference == nil, "\(comparison.firstDifference ?? "")")
        #expect(comparison.massesCompared == comparison.nodes.cpu)
        #expect(
            comparison.massesDiffering == 0,
            "\(comparison.massesDiffering) masses differ, by up to \(comparison.largestRelativeGap)")
    }
}
