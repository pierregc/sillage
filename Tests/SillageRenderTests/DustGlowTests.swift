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

    @Test func theDustUnderTheWebGlowsToo() throws {
        let webbed = try Self.light { $0.dustWeb = 0.8 }
        let glowing = try Self.light {
            $0.dustWeb = 0.8
            $0.dustGlow = 2
            $0.dustGlowColour = SIMD3(1, 0, 0)
        }
        let blue = { (light: [SIMD3<Float>]) in light.reduce(0) { $0 + Double($1.z) } }
        #expect(Self.red(glowing) > 1.05 * Self.red(webbed))
        #expect(abs(blue(glowing) - blue(webbed)) < 1e-6 * max(blue(webbed), 1))
    }

    @Test func backgroundGalaxiesLightTheSky() throws {
        let none = try Self.light { _ in }
        let field = try Self.light { $0.galaxyCount = 200_000 }
        #expect(PopulationWidthTests.total(field) > PopulationWidthTests.total(none))
    }
}
