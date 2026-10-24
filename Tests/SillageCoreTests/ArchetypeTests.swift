import Foundation
import Testing

@testable import SillageCore

@Suite("Archetypes")
struct ArchetypeTests {
    @Test func everyRoundOfABatchHoldsEachArchetypeOnce() {
        let batch = BatchDraw(batchSeed: 4)
        let places = (0..<280).map(batch.place)
        for round in 0..<10 {
            var drawn: [Archetype] = []
            for place in places[(round * 28)..<((round + 1) * 28)] {
                guard case .archetype(let archetype, let occurrence) = place else { continue }
                #expect(occurrence == round)
                drawn.append(archetype)
            }
            #expect(drawn.count == Archetype.allCases.count)
            #expect(Set(drawn) == Set(Archetype.allCases))
        }
        // The free places take the free draws in order, none skipped.
        let free = places.compactMap { place -> Int? in
            if case .free(let index) = place { index } else { nil }
        }
        #expect(free == Array(0..<210))
    }

    @Test(arguments: [Float(0.1), 0.3, 0.5])
    func anyShareIsHeldFromTheStart(share: Float) {
        let batch = BatchDraw(batchSeed: 1, archetypeShare: share)
        var archetypes = 0
        for index in 0..<200 {
            if case .archetype = batch.place(index) { archetypes += 1 }
            #expect(abs(Float(archetypes) - Float(index + 1) * share) < 1)
        }
    }

    @Test func aBatchWithoutArchetypesIsTheFreeOne() {
        let none = BatchDraw(batchSeed: 6, archetypeShare: 0)
        #expect(
            none.scene(at: 3, particleCount: 100_000)
                == FreeDraw(batchSeed: 6).scene(at: 3, particleCount: 100_000))
        let all = BatchDraw(batchSeed: 6, archetypeShare: 1)
        #expect((0..<14).allSatisfy { if case .archetype = all.place($0) { true } else { false } })
    }

    @Test func anArchetypeIsTheSameSceneWhereverItIsDrawn() throws {
        let batch = BatchDraw(batchSeed: 8)
        let index = try #require(
            (0..<40).first { if case .archetype(_, 1) = batch.place($0) { true } else { false } })
        guard case .archetype(let archetype, let occurrence) = batch.place(index) else { return }
        let drawn = batch.scene(at: index, particleCount: 100_000)
        #expect(drawn.draw?.generator == archetype.rawValue)
        #expect(drawn.draw?.index == index && drawn.draw?.batchSeed == 8)
        var alone = archetype.scene(batchSeed: 8, occurrence: occurrence, particleCount: 100_000)
        #expect(alone.draw?.index == occurrence)
        alone.draw?.index = index
        #expect(alone == drawn)
        #expect(
            archetype.scene(batchSeed: 9, occurrence: occurrence, particleCount: 100_000).seed != drawn.seed)
    }

    @Test func theSceneFileRecordsTheArchetypeOrFree() throws {
        let scene = Archetype.mice.scene(batchSeed: 2, occurrence: 0, particleCount: 100_000)
        let json = String(decoding: try SceneFile(scene).encoded(), as: UTF8.self)
        #expect(json.contains("\"generator\" : \"mice\""))
        #expect(try SceneFile.decoded(from: SceneFile(scene).encoded()).draw == scene.draw)
        let free = BatchDraw(batchSeed: 2).scene(at: 0, particleCount: 100_000)
        #expect(free.draw?.generator == FreeDraw.generator)
    }

    @Test(arguments: Archetype.allCases)
    func everyDraftKeepsToItsArchetype(archetype: Archetype) {
        for occurrence in 0..<32 {
            let scene = archetype.draft(
                batchSeed: 3, occurrence: occurrence, particleCount: 100_000, haste: 0)
            let families = scene.draw!.families
            let first = scene.encounters[0]
            let prograde = first.primaryDisk.spin == .prograde && first.secondaryDisk.spin == .prograde
            switch archetype {
            case .antennae:
                #expect(families == [.spiral, .spiral] && prograde && first.eccentricity < 1)
                #expect(first.massRatio >= 0.7)
            case .mice:
                #expect(prograde && first.massRatio >= 0.6)
                #expect(first.primaryDisk.inclination < 0.46 && first.secondaryDisk.inclination > 0.79)
            case .ring:
                // The disk's axis lies along the companion's path where it crosses the disk.
                let disk = first.primaryDisk
                #expect(abs(sin(disk.inclination) * cos(disk.argument)) > 0.9)
                #expect(first.pericentre <= 3 && [.globular, .elliptical].contains(families[1]))
            case .tadpole:
                #expect(families[0] == .spiral && first.massRatio <= 0.2)
                #expect(first.primaryDisk.spin == .prograde && first.primaryDisk.inclination <= 0.5)
            case .polarRing:
                #expect(families == [.disk, .dwarf] && first.eccentricity < 1)
                // The host's axis lies in the orbital plane, so the orbit passes over its poles.
                #expect(abs(cos(first.primaryDisk.inclination)) < 0.21)
            case .minorMerger:
                #expect(first.massRatio <= 0.2 && first.eccentricity < 1)
            case .compactGroup:
                #expect((4...5).contains(scene.galaxies.count))
                let intruder = scene.encounters.first!
                #expect(intruder.secondary == scene.galaxies.count - 1)
                #expect(scene.encounters.allSatisfy { $0.eccentricity <= intruder.eccentricity })
                #expect(scene.encounters.allSatisfy { $0.pericentreTime <= intruder.pericentreTime })
            }
            #expect(scene.galaxies.count == families.count)
            for galaxy in scene.galaxies {
                #expect(galaxy.potential.mass > 0 && galaxy.potential.scaleRadius > 0)
                #expect(galaxy.diskScaleLength > 0 && galaxy.diskTruncation >= 3)
                if galaxy.kind.isRotating { #expect((1.2...2.0).contains(galaxy.toomreQ)) }
            }
            for encounter in scene.encounters {
                #expect(encounter.massRatio > 0 && encounter.massRatio <= 1)
                #expect(encounter.pericentre > 0 && encounter.pericentre <= 30)
            }
        }
    }

    /// As `explore` runs them: live halos, moved into a clip of 3600 steps after 400 of
    /// settling at a step scale of 3.5, about 80 to 790 Myr. An archetype the sanity check
    /// turns away is a slot of the batch spent on nothing.
    @Test(arguments: Archetype.allCases)
    func archetypesPassTheSanityCheck(archetype: Archetype) {
        var accepted = 0
        let tries = 8
        for occurrence in 0..<tries {
            var scene = archetype.scene(batchSeed: 11, occurrence: occurrence, particleCount: 100_000)
            for index in scene.galaxies.indices { scene.galaxies[index].haloParticleRatio = 1.5 }
            scene.timeStepScale = 3.5
            scene.retune()
            scene.retimeEncounters(
                from: SceneConfig.contemplationWindow(haste: 0),
                to: scene.clipWindow(settleSteps: 400, steps: 3_600))
            scene.placeEncountersGivingWay()
            if scene.sanityCheck(settleSteps: 400, steps: 3_600).accepted { accepted += 1 }
        }
        #expect(accepted >= tries - 1, "\(archetype.rawValue): \(accepted) of \(tries)")
    }
}
