import Foundation
import SillageCore
import Testing

@testable import SillageRender

@Suite("Background galaxies and dust glow in look files")
struct GalaxyFieldTests {
    @Test func theGalaxyFieldIsTheSameEveryTimeAndWithinItsSizes() {
        let field = BackgroundGalaxy.field(count: 500)
        let again = BackgroundGalaxy.field(count: 500)
        #expect(field.map(\.direction) == again.map(\.direction))
        #expect(field.allSatisfy { $0.direction.w >= 1.49 && $0.direction.w <= 21.01 })
        #expect(field.allSatisfy { $0.color.w >= 0.25 && $0.color.w <= 1 })
        #expect(BackgroundGalaxy.field(count: 0).isEmpty)
    }

    @Test func aLookWithoutGalaxiesWritesNoField() throws {
        let written = String(decoding: try LookFile().encoded(), as: UTF8.self)
        #expect(!written.contains("galaxyCount"))
        let read = try JSONDecoder().decode(
            LookFile.self, from: Data(#"{"version": 1, "galaxyCount": 12, "look": {"dustGlow": 1.5}}"#.utf8))
        #expect(read.galaxyCount == 12 && read.look.dustGlow == 1.5)
        #expect(read.renderSettings(width: 10, height: 10).galaxyCount == 12)
        #expect(read.rebuildsRenderer(from: LookFile()))
    }
}
