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

    /// Retuning is what every edit in the setup screen runs, so a speed the user picked has
    /// to come through it rather than being reset to the automatic value.
    @Test func retuningKeepsTheExplorationSpeed() {
        var scene = SceneConfig.merger(particleCount: 200_000)
        scene.retune()
        let automatic = scene.timeStep
        scene.timeStepScale = 8
        scene.retune()
        #expect(abs(scene.timeStep - automatic * 8) < automatic * 1e-4)
        scene.galaxies[0].particleCount *= 2
        scene.retune()
        #expect(scene.timeStep > automatic)
    }

    @Test func bothSolversAreAvailable() {
        #expect(SolverKind.allCases.count == 2)
        #expect(SolverKind.allCases.allSatisfy { $0.isImplemented })
        #expect(!SolverKind.restricted.isSelfGravitating)
        #expect(SolverKind.barnesHut.isSelfGravitating)
    }
}

@Suite("Scene file")
struct SceneFileTests {
    static let scenes: [SceneConfig] =
        SceneConfig.all
        + [1, 7, 42, 2_026].map { SceneConfig.contemplation(particleCount: 700_000, seed: $0) }
        + [SceneConfig.contemplation(particleCount: 700_000, seed: 3, galaxies: 4)]

    @Test(arguments: scenes)
    func readingThenWritingGivesAnIdenticalFile(scene: SceneConfig) throws {
        var file = SceneFile(scene)
        let written = try file.encoded()
        #expect(try SceneFile.decoded(from: written).encoded() == written)

        file.softening = 0.07
        file.timeStep = 0.004
        let overridden = try file.encoded()
        #expect(try SceneFile.decoded(from: overridden).encoded() == overridden)
    }

    /// A generated scene runs from its file, so the file has to give that scene back exactly.
    @Test(arguments: scenes)
    func theFileReplaysTheSceneItWasWrittenFrom(scene: SceneConfig) throws {
        let file = try SceneFile.decoded(from: SceneFile(scene).encoded())
        var expected = scene
        expected.retune()
        let replayed = file.scene(
            particleCount: scene.totalParticleCount, palette: scene.galaxies.map(\.color))
        #expect(replayed == expected)
        #expect(try SceneFile(replayed).encoded() == SceneFile(scene).encoded())
    }

    @Test(arguments: [100_000, 5_000_000])
    func theSameFileRunsAtAnyParticleCount(particles: Int) throws {
        var file = SceneFile(.encounter(particleCount: 500_000))
        let scene = file.scene(particleCount: particles)
        #expect(scene.totalParticleCount == particles)
        for (galaxy, share) in zip(scene.galaxies, file.galaxies.map(\.particleShare)) {
            #expect(abs(Double(galaxy.particleCount) / Double(particles) - share) <= 1 / Double(particles))
        }
        var reduced = SceneFile(scene)
        for index in reduced.galaxies.indices {
            reduced.galaxies[index].particleShare = file.galaxies[index].particleShare
        }
        #expect(reduced == file)

        // Derived values follow the count; values set by hand do not.
        #expect(scene.softening == scene.recommendedSoftening)
        file.softening = 0.07
        file.timeStep = 0.004
        let pinned = file.scene(particleCount: particles)
        #expect(pinned.softening == 0.07 && pinned.timeStep == 0.004)
    }

    /// Every field of the scene is in the file except the particle counts and the colour, so a
    /// field added to the scene cannot be silently left out of what replays it.
    @Test func theFileHoldsAllThePhysicsAndNothingElse() throws {
        func keys(_ data: Data) throws -> Set<String> {
            Set((try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]).keys)
        }
        let scene = SceneConfig.flyby(particleCount: 10_000)
        let file = SceneFile(scene)
        let encoder = JSONEncoder()

        #expect(
            try keys(encoder.encode(scene)).subtracting(["softening", "timeStep"])
                == keys(file.encoded()).subtracting(["version"]))
        #expect(
            try keys(encoder.encode(scene.galaxies[0])).subtracting(["particleCount", "color"])
                == keys(encoder.encode(file.galaxies[0])).subtracting(["particleShare"]))
        #expect(!String(decoding: try file.encoded(), as: UTF8.self).contains("color"))
    }

    @Test(arguments: [1, 7, 42, 2_026] as [UInt64])
    func redrawingTheLookChangesNoPhysics(seed: UInt64) throws {
        let scene = SceneConfig.contemplation(particleCount: 100_000, seed: seed)
        var colours: Set<[Float]> = []
        for lookSeed in 0..<UInt64(12) {
            let repainted = SceneConfig.contemplation(
                particleCount: 100_000, seed: seed, lookSeed: lookSeed)
            #expect(try SceneFile(repainted).encoded() == SceneFile(scene).encoded())
            colours.insert(repainted.galaxies.flatMap { [$0.color.x, $0.color.y, $0.color.z] })
        }
        #expect(colours.count > 1)
    }

    @Test func anUnknownVersionOrBadSharesAreRefused() throws {
        var file = SceneFile(.merger(particleCount: 1_000))
        file.version = 2
        #expect(throws: SceneFile.ReadError.self) { try SceneFile.decoded(from: file.encoded()) }
        file.version = SceneFile.currentVersion
        file.galaxies[0].particleShare = 0.9
        #expect(throws: SceneFile.ReadError.self) { try SceneFile.decoded(from: file.encoded()) }
    }
}
