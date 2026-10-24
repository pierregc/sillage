import Foundation
import Testing

@testable import SillageCore

@Suite("Free generator")
struct FreeDrawTests {
    /// The property the sequence is used for: the first 2^k points put exactly one in each
    /// of 2^k slices of every axis, whatever the shift. Independent draws leave about a third
    /// of the slices empty.
    @Test(arguments: [1, 20_261_024] as [UInt64])
    func theSequenceSlicesEveryAxisEvenly(seed: UInt64) {
        let sobol = Sobol(dimensions: Sobol.maximumDimensions, seed: seed)
        let points = (0..<256).map(sobol.point)
        for dimension in 0..<sobol.dimensions {
            #expect(Set(points.map { Int($0[dimension] * 256) }).count == 256)
        }
        // And the first two together cover every cell of a 16 by 16 grid exactly once.
        #expect(Set(points.map { Int($0[0] * 16) * 16 + Int($0[1] * 16) }).count == 256)
    }

    @Test func aBatchCoversTheWholeRange() {
        let drafts = FreeDraw(batchSeed: 3).drafts(60, particleCount: 100_000)
        #expect(Set(drafts.map(\.galaxies.count)) == Set(1...5))
        #expect(Set(drafts.flatMap { $0.draw!.families }) == Set(GalaxyFamily.allCases))
        let spirals = drafts.flatMap(\.galaxies).filter { $0.kind == .spiral }
        #expect(Set(spirals.map(\.armCount)) == Set(2...5))
        let pitches = spirals.map(\.armPitch)
        #expect(pitches.min()! < 0.3 && pitches.max()! > 0.6)
        let ratios = drafts.compactMap { $0.encounters.first?.massRatio }
        #expect(ratios.min()! < 0.1 && ratios.max()! > 0.8)
        let orbits = Set(drafts.flatMap { $0.encounters.map(\.orbit) })
        #expect(orbits.contains(.bound) && orbits.contains(.hyperbolic))
    }

    @Test func noTwoScenesOfABatchAreTooClose() {
        let draw = FreeDraw(batchSeed: 11)
        let signatures = draw.drafts(150, particleCount: 100_000).map(\.signature)
        var closest = Float.infinity
        for i in signatures.indices {
            for j in signatures.indices where j > i {
                closest = min(closest, FreeDraw.distance(signatures[i], signatures[j]))
            }
        }
        #expect(closest >= draw.spacing)
        // Without the rejection the same points do come that close.
        let crowded = FreeDraw(batchSeed: 11, spacing: 0).drafts(150, particleCount: 100_000)
            .map(\.signature)
        #expect(
            crowded.indices.contains { i in
                crowded.indices.contains { j in
                    j > i && FreeDraw.distance(crowded[i], crowded[j]) < draw.spacing
                }
            })
    }

    @Test func everyGalaxyIsPlausible() {
        for scene in FreeDraw(batchSeed: 5).drafts(200, particleCount: 100_000) {
            for galaxy in scene.galaxies {
                #expect(galaxy.potential.mass > 0 && galaxy.potential.scaleRadius > 0)
                #expect(galaxy.diskScaleLength > 0 && galaxy.diskTruncation >= 3)
                if galaxy.kind.isRotating {
                    #expect(galaxy.diskThickness / galaxy.diskScaleLength < 0.31)
                    #expect(galaxy.bulgeFraction <= 0.42)
                    #expect((1.2...2.0).contains(galaxy.toomreQ))
                }
            }
            for encounter in scene.encounters {
                #expect(encounter.massRatio > 0 && encounter.massRatio <= 1)
                #expect(encounter.pericentre >= 1.5 && encounter.pericentre <= 30)
            }
        }
    }

    @Test func aSceneIsFoundAgainFromItsBatchAndIndex() throws {
        let draw = FreeDraw(batchSeed: 42)
        let scene = draw.scene(at: 7, particleCount: 200_000)
        #expect(scene == FreeDraw(batchSeed: 42).scene(at: 7, particleCount: 200_000))
        #expect(scene.draw?.index == 7 && scene.draw?.batchSeed == 42)
        #expect(scene.draw?.generator == "free")
        #expect(scene.galaxies.count == scene.draw?.families.count)
        let drafted = draw.drafts(8, particleCount: 200_000)[7]
        #expect(drafted.draw == scene.draw && drafted.seed == scene.seed)
        #expect(FreeDraw(batchSeed: 43).scene(at: 7, particleCount: 200_000).seed != scene.seed)
    }

    @Test func theSceneFileRecordsHowItWasDrawn() throws {
        let scene = FreeDraw(batchSeed: 9).scene(at: 2, particleCount: 100_000)
        let read = try SceneFile.decoded(from: SceneFile(scene).encoded())
        #expect(read.draw == scene.draw)
        #expect(read.scene(particleCount: 100_000).draw == scene.draw)
        let json = String(decoding: try SceneFile(scene).encoded(), as: UTF8.self)
        #expect(json.contains("\"generator\" : \"free\""))
        // A scene drawn by hand or before this has none, and reads as it did.
        #expect(SceneFile(.merger(particleCount: 1_000)).draw == nil)
    }

    @Test func freeScenesArePlaced() {
        let draw = FreeDraw(batchSeed: 2_026)
        for index in 0..<12 {
            let scene = draw.scene(at: index, particleCount: 200_000)
            guard !scene.encounters.isEmpty else { continue }
            #expect(EncounterTests.passages(scene).allSatisfy { $0 != nil })
            if scene.galaxies.count == 2 { EncounterTests.expectLanded(scene, within: 0.02) }
        }
    }
}
