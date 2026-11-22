import Foundation
import Metal
import SillageCore
import Testing

@testable import SillageRender

@Suite("Dust glow and background galaxies")
struct DustGlowTests {
    static func light(_ change: (inout RenderSettings) -> Void) throws -> [SIMD3<Float>] {
        try PopulationWidthTests.light {
            $0.dustStrength = 0.3
            change(&$0)
        }
    }

    static func red(_ light: [SIMD3<Float>]) -> Double { light.reduce(0) { $0 + Double($1.x) } }

    @Test func noGlowDrawsWhatTheDustAloneDraws() throws {
        let plain = try Self.light { _ in }
        let off = try Self.light { $0.dustGlow = 0 }
        #expect(off == plain)
    }

    @Test func theDustGlowsInItsColour() throws {
        let plain = try Self.light { _ in }
        let glowing = try Self.light {
            $0.dustGlow = 2
            $0.dustGlowColour = SIMD3(1, 0, 0)
        }
        let blue = { (light: [SIMD3<Float>]) in light.reduce(0) { $0 + Double($1.z) } }
        #expect(Self.red(glowing) > 1.05 * Self.red(plain))
        #expect(abs(blue(glowing) - blue(plain)) < 1e-6 * max(blue(plain), 1))
    }

    @Test func backgroundGalaxiesLightTheSky() throws {
        let none = try Self.light { _ in }
        let field = try Self.light { $0.galaxyCount = 200_000 }
        #expect(PopulationWidthTests.total(field) > PopulationWidthTests.total(none))
    }

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
