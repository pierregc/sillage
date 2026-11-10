import Foundation
import Testing

@testable import SillageCore
#if canImport(simd)
    import simd
#endif

@Suite("Encounter geometry")
struct EncounterTests {
    enum Halos: CaseIterable { case restricted, rigid, live }

    static func pair(_ halos: Halos) -> SceneConfig {
        var scene = SceneConfig.merger(particleCount: 100_000)
        scene.solver = halos == .restricted ? .restricted : .barnesHut
        for index in scene.galaxies.indices {
            scene.galaxies[index].haloParticleRatio = halos == .live ? 1.5 : 0
        }
        return scene
    }

    static func passages(_ scene: SceneConfig) -> [EncounterCentres.Passage?] {
        let horizon = (scene.encounters.map(\.pericentreTime).max() ?? 0) * 1.5 + 200
        return EncounterCentres(scene: scene).firstPericentres(
            of: scene.encounters.map { ($0.primary, $0.secondary) }, horizonMyr: horizon)
    }

    static func expectLanded(_ scene: SceneConfig, within tolerance: Float) {
        for (encounter, passage) in zip(scene.encounters, passages(scene)) {
            guard let passage else {
                Issue.record("no passage for \(encounter.primary)-\(encounter.secondary)")
                continue
            }
            #expect(abs(passage.distance / encounter.pericentre - 1) < tolerance)
            #expect(abs(passage.time - encounter.pericentreTime) < tolerance * encounter.pericentreTime)
        }
    }

    /// The whole point: run forward, the centres pass where and when they were asked to, for
    /// every orbit class and every way the solver can hold a halo.
    @Test(arguments: Halos.allCases)
    func aPairPassesWhereAndWhenItWasAsked(halos: Halos) throws {
        for (q, e, t): (Float, Float, Float) in [(8, 1, 200), (5, 0.8, 150), (15, 1.4, 300), (3, 2.2, 90)] {
            var scene = Self.pair(halos)
            scene.encounters = [
                Encounter(
                    pericentre: q, eccentricity: e, massRatio: 0.5, pericentreTime: t,
                    secondaryDisk: .init(inclination: 0.7, argument: 1, spin: .retrograde),
                    planeTilt: 0.4, planeTurn: 1)
            ]
            try scene.placeEncounters()
            Self.expectLanded(scene, within: 0.01)
        }
    }

    @Test func theOrbitClassIsTheTrueOne() throws {
        for (e, bound) in [(0.7 as Float, true), (1.3, false)] {
            var scene = Self.pair(.live)
            scene.encounters = [
                Encounter(pericentre: 8, eccentricity: e, massRatio: 1, pericentreTime: 100)
            ]
            try scene.placeEncounters()
            let centres = EncounterCentres(scene: scene)
            let offset = centres.positions[1] - centres.positions[0]
            let speed = simd_length(centres.velocities[1] - centres.velocities[0])
            let energy = 0.5 * speed * speed + centres.pairPotential(0, 1, at: simd_length(offset))
            #expect((energy < 0) == bound)
        }
        #expect(
            Encounter(pericentre: 1, eccentricity: 1, massRatio: 1, pericentreTime: 1).orbit == .parabolic)
    }

    /// A prograde disk lying in the orbital plane turns the way the orbit does.
    @Test func aProgradeDiskTurnsWithItsOrbit() throws {
        for spin in Spin.allCases {
            var scene = Self.pair(.rigid)
            scene.encounters = [
                Encounter(
                    pericentre: 8, eccentricity: 1, massRatio: 1, pericentreTime: 120,
                    primaryDisk: .init(inclination: 0, argument: 0, spin: spin),
                    secondaryDisk: .init(inclination: .pi / 2, argument: 0.3, spin: spin),
                    planeTilt: 0.9, planeTurn: 2.2, pericentreAngle: 0.4)
            ]
            try scene.placeEncounters()
            let orbit = simd_normalize(
                simd_cross(
                    scene.galaxies[1].position - scene.galaxies[0].position,
                    scene.galaxies[1].velocity - scene.galaxies[0].velocity))
            let first = scene.galaxies[0].orientation.columns.2 * scene.galaxies[0].spin.sign
            let second = scene.galaxies[1].orientation.columns.2 * scene.galaxies[1].spin.sign
            #expect(abs(simd_dot(first, orbit) - spin.sign) < 1e-4)
            #expect(abs(simd_dot(second, orbit)) < 1e-4)
        }
    }

    @Test func theMassRatioSetsTheSecondaryAndTheParticlesFollowTheMass() throws {
        var scene = Self.pair(.live)
        scene.encounters = [Encounter(pericentre: 8, eccentricity: 1, massRatio: 0.25, pericentreTime: 100)]
        let total = scene.totalParticleCount
        try scene.placeEncounters()
        let primary = scene.galaxies[0]
        let secondary = scene.galaxies[1]
        #expect(abs(secondary.potential.mass / primary.potential.mass - 0.25) < 1e-5)
        #expect(scene.totalParticleCount == total)
        let perParticle = primary.potential.mass / Float(primary.particleCount)
        #expect(abs(secondary.potential.mass / Float(secondary.particleCount) / perParticle - 1) < 1e-3)
    }

    @Test func placingTwiceChangesNothing() throws {
        var scene = SceneConfig.contemplation(particleCount: 100_000, seed: 7, galaxies: 2)
        let once = scene
        try scene.placeEncounters()
        #expect(scene.galaxies.map(\.potential) == once.galaxies.map(\.potential))
        #expect(scene.galaxies.map(\.particleCount) == once.galaxies.map(\.particleCount))
        for (a, b) in zip(scene.galaxies, once.galaxies) {
            #expect(simd_distance(a.position, b.position) < 1e-3)
            #expect(simd_distance(a.velocity, b.velocity) < 1e-5)
        }
    }

    static func expectWithinLimits(_ scene: SceneConfig, _ label: String = "") {
        for galaxy in scene.galaxies {
            #expect(simd_length(galaxy.position) <= Encounter.startDistanceLimit, "\(label) \(galaxy.name)")
            #expect(simd_length(galaxy.velocity) <= Encounter.startSpeedLimit, "\(label) \(galaxy.name)")
        }
    }

    /// A drawn scene as `explore` places it: live halos at a step scale of 3.5, its passages
    /// moved into a clip of 700 Myr after 750 steps of settling.
    static func explored(_ drawn: SceneConfig, particleCount: Int) -> SceneConfig {
        var file = SceneFile(drawn)
        file.solver = .barnesHut
        for index in file.galaxies.indices where file.galaxies[index].kind != .blackHole {
            file.galaxies[index].haloParticleRatio = 1.5
        }
        file.timeStepScale = 3.5
        var scene = file.scene(particleCount: particleCount)
        guard !scene.encounters.isEmpty else { return scene }
        scene.retimeEncounters(
            from: SceneConfig.contemplationWindow(haste: 0),
            to: scene.encounterWindow(settleSteps: 750, steps: exploredSteps(scene)))
        scene.placeEncountersGivingWay()
        return scene
    }

    static func exploredSteps(_ scene: SceneConfig) -> Int {
        Int((700 / (Double(scene.timeStep) * Physics.megayearsPerTimeUnit) / 900).rounded(.up)) * 900
    }

    /// Batches whose fits ran away before #217, starting galaxies 4700 to 355 000 kpc out at
    /// up to 600 000 km/s; the first is the batch the review found it in. Each place at the
    /// count `explore-batch.sh` gives it, a hundred thousand particles a galaxy.
    @Test(arguments: [(20_261_030, nil), (117, 0.8), (129, 0.8)] as [(UInt64, Float?)])
    func generatedScenesStartWithinTheLimits(batchSeed: UInt64, pairShare: Float?) {
        let draw = BatchDraw(batchSeed: batchSeed, pairShare: pairShare)
        let drafts = draw.drafts(17, particleCount: 100_000)
        for index in 1...16 {
            let particles = max(drafts[index].galaxyCount, 1) * 100_000
            let drawn = draw.scene(at: index, particleCount: particles)
            Self.expectWithinLimits(drawn, "\(batchSeed) \(index) drawn")
            Self.expectWithinLimits(
                Self.explored(drawn, particleCount: particles), "\(batchSeed) \(index) explored")
        }
    }

    /// The two scenes of the review: placed again holding the drawn energy, every passage
    /// still comes inside the clip, within a few times the distance asked.
    @Test(arguments: [1, 12])
    func aFitThatRanAwayIsTakenAgainHoldingTheEnergy(index: Int) {
        let drawn = BatchDraw(batchSeed: 20_261_030, pairShare: nil).scene(at: index, particleCount: 400_000)
        let scene = Self.explored(drawn, particleCount: 400_000)
        Self.expectWithinLimits(scene)
        let clip = scene.clipWindow(settleSteps: 750, steps: Self.exploredSteps(scene))
        for (encounter, passage) in zip(scene.encounters, Self.passages(scene)) {
            guard let passage else {
                Issue.record("no passage for \(encounter.primary)-\(encounter.secondary)")
                continue
            }
            #expect(clip.contains(passage.time))
            #expect(passage.distance < 3 * encounter.pericentre)
        }
    }

    /// A pair drawn faster than any galaxy starts is slowed towards parabolic, and still
    /// passes where and when it was asked.
    @Test func aPairDrawnTooFastIsSlowed() throws {
        var scene = Self.pair(.live)
        scene.encounters = [Encounter(pericentre: 1, eccentricity: 4, massRatio: 1, pericentreTime: 400)]
        try scene.placeEncounters()
        #expect(scene.encounters[0].eccentricity > 1 && scene.encounters[0].eccentricity < 4)
        Self.expectWithinLimits(scene)
        Self.expectLanded(scene, within: 0.01)
    }

    /// Stepping back past apocentre would make the asked-for passage a second one. Giving way
    /// widens the orbit as little as it can rather than opening it (#252), so the pair is still
    /// bound and comes back.
    @Test(arguments: [Halos.rigid, .live])
    func aBoundOrbitTooShortForItsTimeIsWidened(halos: Halos) throws {
        func pair(_ eccentricity: Float) -> SceneConfig {
            var scene = Self.pair(halos)
            scene.encounters = [
                Encounter(pericentre: 3, eccentricity: eccentricity, massRatio: 1, pericentreTime: 300)
            ]
            return scene
        }
        var scene = pair(0.6)
        #expect(throws: Encounter.Failure.self) { try scene.placeEncounters() }
        scene.placeEncountersGivingWay()
        let widened = scene.encounters[0].eccentricity
        #expect(widened > 0.6 && widened < 1)
        Self.expectLanded(scene, within: 0.01)
        let centres = EncounterCentres(scene: scene)
        let speed = simd_length(centres.velocities[1] - centres.velocities[0])
        let apart = simd_distance(centres.positions[1], centres.positions[0])
        #expect(0.5 * speed * speed + centres.pairPotential(0, 1, at: apart) < 0)
        var narrower = pair(1 - (1 - widened) / SceneConfig.widening)
        #expect(throws: Encounter.Failure.self) { try narrower.placeEncounters() }
    }

    /// An orbit too short for its time even at the last widening is opened to parabolic, as
    /// before.
    @Test func aBoundOrbitBeyondWideningIsOpened() {
        var scene = Self.pair(.rigid)
        scene.encounters = [Encounter(pericentre: 3, eccentricity: 0.6, massRatio: 1, pericentreTime: 2_000)]
        scene.placeEncountersGivingWay()
        #expect(scene.encounters[0].eccentricity >= 1)
    }

    @Test func encountersMustFormATree() {
        var scene = SceneConfig.contemplation(particleCount: 100_000, seed: 3, galaxies: 3)
        scene.encounters = [
            Encounter(
                primary: 0, secondary: 1, pericentre: 8, eccentricity: 1, massRatio: 1, pericentreTime: 100),
            Encounter(
                primary: 2, secondary: 1, pericentre: 8, eccentricity: 1, massRatio: 1, pericentreTime: 100),
        ]
        #expect(throws: Encounter.Failure.notPlacedYet(2)) { try scene.placeEncounters() }
    }

    /// Each secondary is aimed at where its primary actually is at the passage, so a third
    /// galaxy lands on its pericentre as well, and the group as a whole stays put.
    @Test(arguments: [Halos.rigid, .live])
    func aGroupIsBuiltPairByPair(halos: Halos) throws {
        var scene = SceneConfig.contemplation(particleCount: 100_000, seed: 5, galaxies: 3)
        for index in scene.galaxies.indices {
            scene.galaxies[index].haloParticleRatio = halos == .live ? 1.5 : 0
        }
        scene.encounters = [
            Encounter(
                primary: 0, secondary: 1, pericentre: 9, eccentricity: 1, massRatio: 0.6, pericentreTime: 120),
            Encounter(
                primary: 0, secondary: 2, pericentre: 12, eccentricity: 1.2, massRatio: 0.3,
                pericentreTime: 300, planeTilt: 1.0, planeTurn: 2.5),
        ]
        try scene.placeEncounters()
        Self.expectLanded(scene, within: 0.02)
        let masses = scene.galaxies.map(\.potential.mass)
        let momentum = zip(scene.galaxies, masses).reduce(SIMD3<Float>.zero) { $0 + $1.0.velocity * $1.1 }
        let centre = zip(scene.galaxies, masses).reduce(SIMD3<Float>.zero) { $0 + $1.0.position * $1.1 }
        #expect(simd_length(momentum) < 1e-3 * masses.reduce(0, +))
        #expect(simd_length(centre) < 1e-2 * masses.reduce(0, +))
    }

    /// Five galaxies, more than the generator draws, with one hung off a secondary.
    @Test func fiveGalaxiesArePlaced() {
        var scene = SceneConfig.contemplation(particleCount: 100_000, seed: 11, galaxies: 4)
        var fifth = scene.galaxies[1]
        fifth.name = "Fifth"
        scene.galaxies.append(fifth)
        scene.encounters.append(
            Encounter(
                primary: 1, secondary: 4, pericentre: 10, eccentricity: 1.3, massRatio: 0.3,
                pericentreTime: 250, planeTilt: 2))
        scene.placeEncountersGivingWay()
        let positions = scene.galaxies.map(\.position)
        #expect(positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
        for i in positions.indices {
            for j in positions.indices where j > i {
                #expect(simd_distance(positions[i], positions[j]) > 1)
            }
        }
    }

    @Test(arguments: [nil, 2, 3, 4] as [Int?])
    func generatedScenesArePlaced(galaxies: Int?) {
        for seed: UInt64 in 1...6 {
            let scene = SceneConfig.contemplation(particleCount: 200_000, seed: seed, galaxies: galaxies)
            guard !scene.encounters.isEmpty else { continue }
            let found = Self.passages(scene)
            #expect(found.allSatisfy { $0 != nil })
            if scene.galaxies.count == 2 { Self.expectLanded(scene, within: 0.01) }
        }
    }

    @Test func aClipMovesThePassagesIntoIt() throws {
        var scene = SceneConfig.contemplation(particleCount: 200_000, seed: 7, galaxies: 2)
        let window = scene.clipWindow(settleSteps: 400, steps: 3_600)
        scene.retimeEncounters(from: SceneConfig.contemplationWindow(haste: 0), to: window)
        #expect(window.contains(scene.encounters[0].pericentreTime))
        scene.placeEncountersGivingWay()
        Self.expectLanded(scene, within: 0.01)
    }

    @Test func aSceneWrittenBeforeEncountersStillReads() throws {
        let scene = SceneConfig.merger(particleCount: 1_000)
        var json = try JSONSerialization.jsonObject(with: scene.encoded()) as! [String: Any]
        json.removeValue(forKey: "encounters")
        let decoded = try SceneConfig.decoded(from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded == scene)
        #expect(try SceneFile(scene).encoded().range(of: Data("encounters".utf8)) == nil)
    }

    @Test func theSceneFileKeepsTheEncounters() throws {
        let scene = SceneConfig.contemplation(particleCount: 300_000, seed: 3, galaxies: 3)
        let read = try SceneFile.decoded(from: SceneFile(scene).encoded())
        #expect(read.encounters == scene.encounters)
        #expect(read.scene(particleCount: 300_000).encounters == scene.encounters)
    }
}
