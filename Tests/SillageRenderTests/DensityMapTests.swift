import Foundation
import Testing

@testable import SillageRender

@Suite("Density map")
struct DensityMapTests {
    @Test func instantsSpanTheClipFromFirstToLastFrame() {
        #expect(DensityMap(frames: 900, count: 4, extent: 10).instants == [0, 300, 599, 899])
        #expect(DensityMap(frames: 3, count: 8, extent: 10).instants == [0, 1, 2])
    }

    @Test func countsAreAFractionOfTheStarsWithThoseOutsideLeftOut() {
        var map = DensityMap(frames: 1, count: 1, extent: 2, size: 4)
        let positions: [SIMD3<Float>] = [[-1.5, -1.5, 0], [-1.5, -1.5, 3], [1.9, 0.1, 0], [5, 0, 0]]
        positions.withUnsafeBufferPointer { map.add($0.baseAddress!, count: $0.count) }
        #expect(map.maps[0][0] == 0.5)
        #expect(map.maps[0][2 * 4 + 3] == 0.25)
        #expect(map.maps[0].reduce(0, +) == 0.75)
    }

    @Test func npyHeaderIsAlignedAndDescribesTheShape() throws {
        var map = DensityMap(frames: 2, count: 2, extent: 1, size: 2)
        let positions: [SIMD3<Float>] = [[0.5, 0.5, 0]]
        for _ in 0..<2 {
            positions.withUnsafeBufferPointer { map.add($0.baseAddress!, count: 1) }
        }
        let data = map.npy()
        let length = Int(data[8]) | Int(data[9]) << 8
        #expect((10 + length) % 64 == 0)
        let header = try #require(String(data: data[10..<(10 + length)], encoding: .ascii))
        #expect(header.contains("'shape': (2, 2, 2)"))
        #expect(data.count == 10 + length + 2 * 4 * 4)
    }
}
