import Foundation
import Testing
import simd

@testable import SillageCore

@Suite("Tree layout")
struct TreeLayoutTests {
    private static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/engines/tree")

    private func bytes<T>(_ values: [T]) -> Data { values.withUnsafeBytes { Data($0) } }

    /// The level order moves the cells and nothing else: the walk from the root meets the same
    /// ones, with the same moments.
    @Test func aTreeInLevelOrderIsTheSameTree() throws {
        var generator = SeededGenerator(seed: 11)
        let positions = (0..<30_000).map { index in
            SIMD3<Float>(generator.normal(), generator.normal(), generator.normal())
                * (index % 7 == 0 ? 0.001 : 5)
        }
        let tree = BarnesHutTree()
        tree.computesQuadrupoles = true
        tree.build(positions: positions, mass: positions.map { _ in 0.002 })
        let level = try #require(BarnesHutTree.levelOrdered(tree.nodes, moments: tree.quadrupoles))
        #expect(level.nodes.count == tree.nodes.count)
        var stack = [(0, 0)]
        var met = 0
        var same = true
        while let (a, b) = stack.popLast() {
            let (plain, moved) = (tree.nodes[a], level.nodes[b])
            met += 1
            same =
                same && plain.comMass == moved.comMass && plain.signedCount == moved.signedCount
                && plain.packed.x == moved.packed.x && plain.digit == moved.digit
                && tree.quadrupoles[2 * a] == level.moments[2 * b]
                && tree.quadrupoles[2 * a + 1] == level.moments[2 * b + 1]
                && (plain.isLeaf ? plain.range == moved.range : moved.childOffset > b)
            guard !plain.isLeaf else { continue }
            for k in 0..<plain.childCount {
                stack.append((plain.childOffset + k, moved.childOffset + k))
            }
        }
        #expect(same && met == tree.nodes.count)
        // Already level by level: nothing moves.
        let again = try #require(BarnesHutTree.levelOrdered(level.nodes, moments: level.moments))
        #expect(bytes(again.nodes) == bytes(level.nodes) && again.moments == level.moments)
    }

    @Test func aTreeThatLoopsHasNoLevelOrder() {
        #expect(BarnesHutTree.levelOrdered([BHNode()])?.nodes.count == 1)
        var loop = BHNode()
        loop.range = 0
        loop.signedCount = 1
        #expect(BarnesHutTree.levelOrdered([loop]) == nil)
        #expect(BarnesHutTree.levelOrdered([BHNode()], moments: [.zero]) == nil)
    }

    /// The portable tree gives the engines' reference tree to the bit (#281), on the Mac and on
    /// Linux alike.
    @Test func theCPUBuildsTheFixtureTree() throws {
        func file(_ name: String) throws -> Data {
            try Data(contentsOf: Self.fixtures.appendingPathComponent(name))
        }
        let positions = try file("positions.bin").withUnsafeBytes {
            $0.bindMemory(to: SIMD4<Float>.self).map { SIMD3<Float>($0.x, $0.y, $0.z) }
        }
        let mass = try file("mass.bin").withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        #expect(positions.count == 20_000 && mass.count == positions.count)
        let tree = BarnesHutTree(leafCapacity: 16, maximumDepth: 20)
        tree.computesQuadrupoles = true
        tree.build(positions: positions, mass: mass)
        let level = try #require(BarnesHutTree.levelOrdered(tree.nodes, moments: tree.quadrupoles))
        #expect(bytes(tree.order) == (try file("order.bin")))
        #expect(bytes(level.nodes) == (try file("nodes.bin")))
        #expect(bytes(level.moments) == (try file("moments.bin")))
    }
}
