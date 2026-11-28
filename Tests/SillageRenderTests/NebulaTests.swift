import Foundation
import Metal
import SillageCore
import Testing

@testable import SillageRender

@Suite("HII regions around the young knots")
struct NebulaTests {
    static func light(_ change: (inout RenderSettings) -> Void) throws -> [SIMD3<Float>] {
        try PopulationWidthTests.light {
            $0.dustStrength = 0.3
            change(&$0)
        }
    }

    static func sum(_ light: [SIMD3<Float>], _ channel: Int) -> Double {
        light.reduce(0) { $0 + Double($1[channel]) }
    }

    @Test func noNebulaeDrawWhatTheFrameAlwaysDrew() throws {
        let plain = try Self.light { _ in }
        let off = try Self.light {
            $0.nebulae = 0
            $0.nebulaSize = 0.5
        }
        #expect(off == plain)
    }

    @Test func theRegionsGlowInTheirColourAroundTheKnots() throws {
        let plain = try Self.light { _ in }
        let lit = try Self.light {
            $0.nebulae = 30
            $0.nebulaMyr = 1000
            $0.nebulaColour = SIMD3(1, 0, 0)
        }
        #expect(Self.sum(lit, 0) > 1.05 * Self.sum(plain, 0))
        #expect(Self.sum(lit, 2) == Self.sum(plain, 2))
    }

    @Test func aRegionFadesWithItsKnotsAge() throws {
        let plain = try Self.light { _ in }
        func added(_ megayears: Float) throws -> Double {
            let lit = try Self.light {
                $0.nebulae = 30
                $0.nebulaMyr = megayears
                $0.nebulaColour = SIMD3(1, 0, 0)
            }
            return Self.sum(lit, 0) - Self.sum(plain, 0)
        }
        #expect(try added(1000) > 2 * added(100))
    }
}
