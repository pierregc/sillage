import Foundation
import Testing

@testable import SillageCore

@Suite("Scene configuration")
struct SceneConfigTests {
    @Test(arguments: SceneConfig.all)
    func presetsRoundTripThroughJSON(scene: SceneConfig) throws {
        #expect(try SceneConfig.decoded(from: scene.encoded()) == scene)
    }

    @Test func particleCountIsSplitAcrossGalaxies() {
        #expect(SceneConfig.merger(particleCount: 999_999).totalParticleCount == 999_999)
        #expect(SceneConfig.flyby(particleCount: 1_000).totalParticleCount == 1_000)
    }

    @Test func bothSolversAreAvailable() {
        #expect(SolverKind.allCases.count == 2)
        #expect(SolverKind.allCases.allSatisfy { $0.isImplemented })
        #expect(!SolverKind.restricted.isSelfGravitating)
        #expect(SolverKind.barnesHut.isSelfGravitating)
    }
}
