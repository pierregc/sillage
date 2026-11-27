import Foundation
import Testing

@testable import SillageCore
@testable import SillageRender

/// The dust screen as the CUDA engine holds it (#513): the Sombrero fixture's tile with its
/// levels down to one texel, half floats, and what the resolve reads of it.
@Suite("Dust screen texels")
struct DustScreenTexelsTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Fixtures/sombrero")

    static func ref() -> DustScreenRef {
        var ref = DustScreenRef(
            tile: folder.appendingPathComponent("tile.json").path, rest: 12.388, depth: 0.39)
        ref.renew = 50
        return ref
    }

    @Test func theTileHasItsLevelsDownToOneTexel() throws {
        let texels = try DustScreenTexels(Self.ref())
        #expect(texels.width == 64 && texels.height == 16 && texels.levels == 7)
        #expect(texels.tile.count == 64 * 16 + 32 * 8 + 16 * 4 + 8 * 2 + 4 + 2 + 1)
        #expect(texels.lut.count == 16 * 16 && texels.lutWidth == 16)
        #expect(texels.tile.allSatisfy { Float(Float16($0)) == $0 }, "a texel is not a half float")
        let first = texels.tile[0..<(64 * 16)].reduce(0, +) / Float(64 * 16)
        let last = try #require(texels.tile.last)
        #expect(
            abs(last - first) < 0.01 * max(abs(first), 1), "the last level \(last) is not the mean \(first)")
        // The second level's first texel, the mean of the first level's two by two at its corner.
        let corner = (texels.tile[0] + texels.tile[1] + texels.tile[64] + texels.tile[65]) / 4
        #expect(abs(texels.tile[64 * 16] - corner) <= abs(corner) / 1000)
    }

    @Test func theUniformsAreTheRenderersOwn() throws {
        let texels = try DustScreenTexels(Self.ref())
        let u = texels.uniforms
        let unit = Float(Physics.megayearsPerTimeUnit)
        #expect(u.shape == SIMD4(1, 0.5, 8, 12.388 / unit))
        #expect(u.renew == SIMD4(50 / unit, 1, -3, 3))
        #expect(u.depth == SIMD4(0.39, 0, 0, 0))
        #expect(u.dabSize == .zero && u.front == .zero)
        #expect(MemoryLayout<ScreenUniforms>.stride == 208 && MemoryLayout<ScreenLaw>.stride == 144)
    }

    @Test func dabsOnATileWithoutALutAreRefused() throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent(
            "screen-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: Self.folder.appendingPathComponent("tile.f32"), to: work.appendingPathComponent("tile.f32"))
        let tile = work.appendingPathComponent("tile.json")
        try Data(#"{"width": 64, "height": 16, "radii": [0.5, 8], "data": "tile.f32"}"#.utf8).write(to: tile)
        var ref = DustScreenRef(tile: tile.path)
        let columns = try DustScreenTexels(ref)
        #expect(columns.lut.isEmpty && columns.uniforms.renew.y == 0)
        ref.dabs = try JSONDecoder().decode(DustScreenDabs.self, from: Data(#"{"size": [95, 55, 28]}"#.utf8))
        #expect(throws: DustScreenTexels.Failure.self) { try DustScreenTexels(ref) }
        try Data("{}".utf8).write(to: tile)
        #expect(throws: DustScreenTexels.Failure.self) {
            try DustScreenTexels(DustScreenRef(tile: tile.path))
        }
    }
}
