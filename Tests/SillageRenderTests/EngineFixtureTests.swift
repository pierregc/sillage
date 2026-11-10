import Foundation
import Metal
import Testing
import simd

@testable import SillageCore
@testable import SillageRender

/// Metal has to give the reference outputs of `Tests/Fixtures/engines/` again, to the bit
/// (#281). After a change that is meant: `./scripts/dev.sh fixtures`, and the PR says so.
@Suite("Engine fixtures")
struct EngineFixtureTests {
    private static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/engines")
    private static let meant = "if the change is meant, ./scripts/dev.sh fixtures"

    private func file(_ path: String) throws -> Data {
        try Data(contentsOf: Self.folder.appendingPathComponent(path))
    }

    @Test func metalBuildsTheFixtureTree() throws {
        let positions = EngineFixtures.values(try file("tree/positions.bin"), as: SIMD4<Float>.self)
        let mass = EngineFixtures.values(try file("tree/mass.bin"), as: Float.self)
        #expect(positions.count == 20_000)
        let tree = try EngineFixtures.metalTree(positions: positions, mass: mass)
        #expect(tree.order == (try file("tree/order.bin")), "order: \(Self.meant)")
        #expect(tree.nodes == (try file("tree/nodes.bin")), "nodes: \(Self.meant)")
        #expect(tree.moments == (try file("tree/moments.bin")), "moments: \(Self.meant)")
        #expect(tree.frame == (try file("tree/frame.bin")), "frame: \(Self.meant)")
        #expect(tree.levels == (try file("tree/levels.bin")), "levels: \(Self.meant)")
        #expect(tree.smoothing == (try file("tree/smoothing.bin")), "smoothing: \(Self.meant)")
        #expect(tree.spacing == (try file("tree/spacing.bin")), "spacing: \(Self.meant)")
        #expect(tree.smoothing.count == EngineFixtures.treeDrawn * 4)
    }

    @Test func metalWalksTheFixtureDumpToTheBit() throws {
        let dump = try EngineFixtures.WalkDump(folder: Self.folder.appendingPathComponent("walk"))
        #expect(dump.tracers == 1_000)
        let walked = try EngineFixtures.walk(dump)
        let expected = EngineFixtures.values(try dump.buffer("accelerations"), as: SIMD4<Float>.self)
        let found = EngineFixtures.values(walked.accelerations, as: SIMD4<Float>.self)
        var differing = 0
        var worst: Float = 0
        for (a, b) in zip(found, expected)
        where unsafeBitCast(a, to: SIMD4<UInt32>.self) != unsafeBitCast(b, to: SIMD4<UInt32>.self) {
            differing += 1
            let (x, y) = (SIMD3<Float>(a.x, a.y, a.z), SIMD3<Float>(b.x, b.y, b.z))
            worst = max(worst, simd_length(x - y) / max(simd_length(y), .leastNormalMagnitude))
        }
        #expect(
            found.count == expected.count && differing == 0,
            "\(differing) accelerations differ, by up to \(worst) relative: \(Self.meant)")
        #expect(
            walked.motions == (try dump.buffer("motions-mode1")),
            "the mode 1 pass differs: \(Self.meant)")
        #expect(walked.motions != (try dump.buffer("motions")))
    }

    @Test(arguments: EngineFixtures.looks)
    func metalDrawsTheFixtureFrame(look: String) throws {
        let frames = Self.folder.appendingPathComponent("frames")
        let drawn = try EngineFixtures.frame(
            take: frames.appendingPathComponent("take.sillage"),
            look: frames.appendingPathComponent("\(look).look.json"))
        let expected = try file("frames/\(look).rgba")
        #expect(expected.count == EngineFixtures.width * EngineFixtures.height * 4)
        var differing = 0
        var worst = 0
        for (a, b) in zip(drawn, expected) where a != b {
            differing += 1
            worst = max(worst, abs(Int(a) - Int(b)))
        }
        #expect(
            drawn.count == expected.count && differing == 0,
            "\(look): \(differing) bytes differ, by up to \(worst): \(Self.meant)")
        #expect(expected.contains { $0 > 32 }, "\(look): a black frame checks nothing")
    }

    @Test func theFixturesStayUnderTwoMegabytes() throws {
        let files = FileManager.default.enumerator(
            at: Self.folder, includingPropertiesForKeys: [.fileSizeKey])
        var total = 0
        while let url = files?.nextObject() as? URL {
            total += try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        }
        #expect(total > 0 && total < 2_000_000, "\(total) bytes")
    }
}
