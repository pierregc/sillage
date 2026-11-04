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
        // A black hole is a few per cent of the scenes, and may miss sixty of them.
        #expect(
            Set(drafts.flatMap { $0.draw!.families }).subtracting([.blackHole])
                == Set(GalaxyFamily.allCases).subtracting([.blackHole]))
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

    /// Held to two galaxies or to the others, each kind keeps the spacing among its own scenes,
    /// and a black hole counts as no galaxy: a triple that meets one is a pair.
    @Test func aPairingTakesOnlyItsCountsAndKeepsTheSpacing() throws {
        let draw = FreeDraw(batchSeed: 11)
        let pairs = draw.drafts(80, particleCount: 100_000, taking: .pairs)
        let others = draw.drafts(80, particleCount: 100_000, taking: .others)
        #expect(pairs.allSatisfy { $0.galaxyCount == 2 } && others.allSatisfy { $0.galaxyCount != 2 })
        #expect(Set(others.map(\.galaxyCount)) == [1, 3, 4, 5])
        for kind in [pairs, others] {
            let signatures = kind.map(\.signature)
            let gaps = signatures.indices.flatMap { i in
                signatures.indices.filter { $0 > i }.map { FreeDraw.distance(signatures[i], signatures[$0]) }
            }
            #expect(gaps.min()! >= draw.spacing)
        }
        // No point is drawn twice, and the scene at an index is the draft there, placed.
        #expect(Set(pairs.map(\.draw!.point)).isDisjoint(with: others.map(\.draw!.point)))
        let placed = draw.scene(at: 7, particleCount: 100_000, taking: .pairs)
        #expect(placed.draw == pairs[7].draw && placed.galaxyCount == 2)
        var triple = try #require(draw.drafts(20, particleCount: 100_000).first { $0.galaxies.count == 3 })
        triple.galaxies[1].kind = .blackHole
        #expect(triple.galaxyCount == 2)
    }

    @Test func everyGalaxyIsPlausible() {
        for scene in FreeDraw(batchSeed: 5).drafts(200, particleCount: 100_000) {
            for galaxy in scene.galaxies where galaxy.kind != .blackHole {
                #expect(galaxy.potential.mass > 0 && galaxy.potential.scaleRadius > 0)
                #expect(galaxy.diskScaleLength > 0 && galaxy.diskTruncation >= 3)
                if galaxy.kind.isRotating {
                    #expect(galaxy.diskThickness / galaxy.diskScaleLength < 0.31)
                    #expect(galaxy.bulgeFraction <= 0.42)
                    #expect((DiskResponse.lowestToomreQ...2.0).contains(galaxy.toomreQ))
                }
            }
            for encounter in scene.encounters {
                let hole = scene.galaxies[encounter.secondary].kind == .blackHole
                #expect(encounter.massRatio > 0 && encounter.massRatio <= (hole ? 0.3 : 1))
                #expect(encounter.pericentre >= (hole ? 0.5 : 1.5) && encounter.pericentre <= 30)
            }
        }
    }

    /// A few per cent of free scenes swap their first companion for a black hole.
    @Test func aFewFreeScenesMeetABlackHole() {
        let drafts = FreeDraw(batchSeed: 7).drafts(400, particleCount: 100_000)
        let holes = drafts.filter { $0.draw!.families.contains(.blackHole) }
        let pairs = drafts.filter { $0.galaxies.count >= 2 }.count
        #expect(holes.count >= pairs / 100 && holes.count <= pairs / 10)
        for scene in holes {
            #expect(scene.draw!.families[1] == .blackHole && scene.galaxies[1].particleCount == 1)
            #expect(scene.galaxies.filter { $0.kind == .blackHole }.count == 1)
            #expect((0.01...0.3).contains(scene.encounters[0].massRatio))
            // Swapped after the choice: what the signatures saw is the scene as first drawn.
            let drawn = FreeDraw(batchSeed: 7).draft(point: scene.draw!.point, particleCount: 100_000)
            #expect(FreeDraw.withBlackHole(drawn)?.galaxies == scene.galaxies)
        }
        let placed = FreeDraw(batchSeed: 7).scene(at: holes[0].draw!.index, particleCount: 200_000)
        #expect(placed.galaxies[1].kind == .blackHole && placed.galaxies[0].particleCount == 199_999)
        #expect(EncounterTests.passages(placed).allSatisfy { $0 != nil })
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

    /// A spiral is drawn for how its disk answers (#181), archetypes included: at the softening
    /// its scene explores at with 100 000 particles a galaxy, its response is in the range for
    /// its arms and its size unless the floor of Q left it higher, and its Q holds it at the
    /// count the scene is drawn at. A large two-armed one keeps the response its draw of Q gives
    /// at that softening, `largeTwoArmedFloor` at least (#249).
    @Test func aSpiralIsDrawnForItsResponse() throws {
        let batch = BatchDraw(batchSeed: 20_261_031)
        var drawn = 0
        var floored = 0
        var twoArmed = 0
        var lifted = 0
        var small = 0
        for index in 0..<40 {
            let scene = batch.scene(at: index, particleCount: 300_000)
            let reference = DiskResponse.referenceSoftening(scene.galaxies)
            for (galaxy, family) in zip(scene.galaxies, scene.draw!.families) {
                guard family == .spiral else {
                    #expect(galaxy.effectiveToomreQ == nil)
                    continue
                }
                let isSmall = galaxy.diskScaleLength < DiskResponse.smallScaleLength
                let response = try #require(galaxy.effectiveToomreQ)
                #expect(
                    galaxy.toomreQ
                        == DiskResponse.toomreQ(
                            effective: response, of: galaxy, softening: scene.recommendedSoftening))
                let atReference = DiskResponse.toomreQ(effective: response, of: galaxy, softening: reference)
                guard galaxy.armCount > 2 || isSmall else {
                    twoArmed += 1
                    let drawnQ = DiskResponse.twoArmedToomreQ
                    #expect(response >= DiskResponse.largeTwoArmedFloor - 1e-5)
                    #expect(atReference > drawnQ.lowerBound - 1e-5)
                    if response > DiskResponse.largeTwoArmedFloor + 1e-5 {
                        #expect(atReference < drawnQ.upperBound + 1e-5)
                    } else {
                        lifted += 1
                    }
                    continue
                }
                drawn += 1
                if isSmall { small += 1 }
                let range =
                    galaxy.armCount <= 2
                    ? DiskResponse.smallTwoArmedRange
                    : isSmall ? DiskResponse.smallRange : DiskResponse.drawnRange
                #expect(response >= range.lowerBound - 1e-4)
                if atReference <= DiskResponse.lowestToomreQ + 1e-4 {
                    floored += 1
                } else {
                    #expect(response <= range.upperBound + 1e-4)
                }
            }
        }
        #expect(drawn >= 20 && small >= 8 && twoArmed >= 5 && floored * 2 < drawn)
        #expect(lifted >= 1 && lifted * 2 < twoArmed)
    }

    /// A generated disk sheds its random motion over the time drawn, but never in fewer than
    /// `DiskResponse.coolingTurns` of its turns (#218): a large disk keeps a longer cooling, a
    /// small one the draw.
    @Test func aGeneratedDiskCoolsOverTurnsOfItsOwn() {
        let batch = BatchDraw(batchSeed: 20_261_030, pairShare: nil)
        var held = 0
        var kept = 0
        for index in 0..<40 {
            let scene = batch.scene(at: index, particleCount: 300_000)
            for galaxy in scene.galaxies where galaxy.kind.isRotating {
                let turns = galaxy.dissipationTime / DiskResponse.turn(of: galaxy)
                #expect(turns >= DiskResponse.coolingTurns - 1e-3)
                if turns < DiskResponse.coolingTurns + 1e-3 {
                    held += 1
                } else {
                    kept += 1
                    #expect((180...320).contains(galaxy.dissipationTime))
                }
            }
        }
        #expect(held >= 5 && kept >= 5)
        var large = GalaxyConfig(
            name: "", particleCount: 100_000,
            potential: GalaxyPotential(profile: .hernquist, mass: 68, scaleRadius: 7.7),
            diskScaleLength: 6.1)
        #expect(DiskResponse.turn(of: large) > 150)
        #expect(DiskResponse.dissipationTime(drawn: 185, of: large) > 185)
        large.diskScaleLength = 2.6
        #expect(DiskResponse.dissipationTime(drawn: 185, of: large) == 185)
        large.kind = .globular
        #expect(DiskResponse.dissipationTime(drawn: 185, of: large) == 185)
    }

    /// The gas of a large generated spiral weighs a tenth to a fifth of its disk, at the place
    /// of its dust draw, and its dust particles stay as drawn for the light (#218); a small one,
    /// or any other kind, keeps its gas as heavy as its dust.
    @Test func aLargeSpiralsGasWeighsApartFromItsDust() {
        let batch = BatchDraw(batchSeed: 20_261_030, pairShare: nil)
        var large = 0
        var other = 0
        for index in 0..<40 {
            let scene = batch.scene(at: index, particleCount: 300_000)
            for galaxy in scene.galaxies {
                guard galaxy.kind == .spiral, galaxy.diskScaleLength >= DiskResponse.smallScaleLength else {
                    #expect(galaxy.dustMassFraction == nil)
                    other += 1
                    continue
                }
                large += 1
                #expect(DiskResponse.drawnDust.contains(galaxy.dustFraction))
                let place = (galaxy.dustFraction - 0.14) / 0.24
                #expect(abs((galaxy.dustMassFraction ?? 0) - (0.10 + 0.10 * place)) < 1e-5)
            }
        }
        #expect(large >= 8 && other >= 20)
        let contemplation = SceneConfig.contemplation(particleCount: 300_000, seed: 7)
        #expect(contemplation.galaxies.allSatisfy { $0.dustMassFraction == nil })
    }

    /// A scene a generator did not draw keeps its Toomre Q, small two-armed spirals included,
    /// and its cooling as drawn.
    @Test func aContemplationSceneKeepsItsToomreQ() {
        for seed in [1, 7, 42, 2_026] as [UInt64] {
            let scene = SceneConfig.contemplation(particleCount: 300_000, seed: seed)
            #expect(scene.galaxies.allSatisfy { $0.effectiveToomreQ == nil })
            #expect(
                scene.galaxies.allSatisfy {
                    $0.dissipationTime == 0 || (180...320).contains($0.dissipationTime)
                })
        }
    }

    /// How fast a companion comes in is drawn for itself (#252): two in five captured on a
    /// bound orbit and passing early, three in ten falling in from rest or nearly, the rest
    /// fast, up to 900 km/s far out, and the faster the closer.
    @Test func theApproachRunsFromCapturedToFast() {
        let window = SceneConfig.contemplationWindow(haste: 0)
        var captured = 0
        var slow = 0
        var fast = 0
        var fastest: Float = 0
        for scene in FreeDraw(batchSeed: 3, spacing: 0).drafts(256, particleCount: 100_000) {
            guard let encounter = scene.encounters.first, scene.draw!.families[1] != .blackHole else {
                continue
            }
            let minor = [.dwarf, .globular].contains(scene.draw!.families[1])
            let mass = scene.galaxies[0].potential.mass * (1 + encounter.massRatio)
            if encounter.eccentricity < 1 {
                captured += 1
                let along = (encounter.pericentreTime - window.lowerBound) / (window.upperBound - window.lowerBound)
                #expect(along <= 0.22 + 1e-4)
                continue
            }
            let speed =
                ((encounter.eccentricity - 1) * mass / encounter.pericentre).squareRoot()
                * Float(Physics.kilometersPerSecondPerVelocityUnit)
            #expect(speed <= 900 * 1.001)
            guard speed > 120 * 1.001 else {
                slow += 1
                continue
            }
            fast += 1
            fastest = max(fastest, speed)
            let lowest: Float = minor ? 1.5 : 2
            #expect(encounter.pericentre * speed <= FreeDraw.fastReach * 1.001 || encounter.pericentre <= 2 * lowest + 1e-3)
        }
        let total = Float(captured + slow + fast)
        #expect(total > 150)
        #expect(abs(Float(captured) / total - FreeDraw.capturedShare) < 0.08)
        #expect(abs(Float(slow) / total - FreeDraw.slowShare) < 0.08)
        #expect(fastest > 600)
    }

    /// The signature reads the approach where the draw put it.
    @Test func theSignatureReadsTheApproachAsDrawn() {
        for u in stride(from: Float(0.01), to: 1, by: 0.03) {
            for pericentre in [0.1, 0.5, 0.9] as [Float] {
                let orbit = FreeDraw.orbit(approach: u, pericentre: pericentre, in: 2...30, totalMass: 90)
                #expect(orbit.captured == (u < FreeDraw.capturedShare))
                #expect(orbit.pericentre >= 2 && orbit.pericentre <= 30)
                guard !orbit.captured || orbit.pericentre * 1.5 < FreeDraw.capturedApocentres.lowerBound else {
                    continue
                }
                let read = FreeDraw.approach(
                    pericentre: orbit.pericentre, eccentricity: orbit.eccentricity, totalMass: 90)
                #expect(abs(read - u) < 2e-3, "\(u) \(pericentre)")
            }
        }
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
