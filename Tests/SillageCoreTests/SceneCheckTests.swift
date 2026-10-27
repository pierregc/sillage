import Foundation
import Testing
import simd

@testable import SillageCore

@Suite("Scene sanity check")
struct SceneCheckTests {
    /// Two disks that meet at the pericentre asked for, inside the window.
    static func meeting(
        pericentre: Float = 8, eccentricity: Float = 1, time: Float = 150
    ) throws -> SceneConfig {
        var scene = SceneConfig.merger(particleCount: 100_000)
        scene.solver = .barnesHut
        for index in scene.galaxies.indices { scene.galaxies[index].haloParticleRatio = 0 }
        scene.encounters = [
            Encounter(
                pericentre: pericentre, eccentricity: eccentricity, massRatio: 1,
                pericentreTime: time)
        ]
        try scene.placeEncounters()
        return scene
    }

    static let window: ClosedRange<Float> = 50...400

    @Test func aPassageInsideTheWindowIsAccepted() throws {
        let check = SceneCheck.evaluate(try Self.meeting(), window: Self.window)
        #expect(check.accepted, "\(check.reasons)")
        let closest = try #require(check.closestApproach)
        #expect(abs(closest.distance - 8) < 0.5)
        #expect(abs(closest.time - 150) < 5)
    }

    @Test func aPassageAfterTheWindowIsRejected() throws {
        let scene = try Self.meeting(pericentre: 8, time: 900)
        let check = SceneCheck.evaluate(scene, window: Self.window)
        #expect(!check.accepted)
        #expect(check.reasons.contains { if case .noApproach = $0 { true } else { false } })
    }

    @Test func aPassageTooWideToTouchIsRejected() throws {
        let scene = try Self.meeting(pericentre: 400, eccentricity: 1.5)
        let check = SceneCheck.evaluate(scene, window: Self.window)
        #expect(check.reasons.contains { if case .noApproach = $0 { true } else { false } })
    }

    @Test func aLoneDiskHasNothingToApproach() {
        var scene = SceneConfig.isolatedDisk(particleCount: 10_000)
        scene.solver = .barnesHut
        let check = SceneCheck.evaluate(scene, window: Self.window)
        #expect(check.accepted)
        #expect(check.closestApproach == nil)
    }

    @Test(arguments: [Float(0.6), 4.5])
    func aDiskOutsideTheToomreRangeIsRejected(q: Float) throws {
        var scene = try Self.meeting()
        scene.galaxies[1].toomreQ = q
        let check = SceneCheck.evaluate(scene, window: Self.window)
        let flagged = check.reasons.compactMap { reason -> Int? in
            if case .unstableDisk(let galaxy, _) = reason { galaxy } else { nil }
        }
        #expect(flagged == [1])
        #expect(abs(try #require(check.toomre).lowerBound - min(q, 1.4)) < 0.05)
    }

    @Test func aSpheroidHasNoDiskToJudge() throws {
        var scene = try Self.meeting()
        scene.galaxies[1].kind = .globular
        scene.galaxies[1].toomreQ = 0.1
        #expect(SceneCheck.evaluate(scene, window: Self.window).accepted)
    }

    @Test func galaxiesThatStartOnTopOfEachOtherAreRejected() throws {
        var scene = try Self.meeting()
        scene.galaxies[0].position = SIMD3(-2, 0, 0)
        scene.galaxies[1].position = SIMD3(2, 0, 0)
        scene.galaxies[0].velocity = SIMD3(0, 0.5, 0)
        scene.galaxies[1].velocity = SIMD3(0, -0.5, 0)
        let check = SceneCheck.evaluate(scene, window: Self.window)
        #expect(check.reasons.contains { if case .overlapAtStart = $0 { true } else { false } })
        #expect(try #require(check.startClearance) < 1)
    }

    @Test func aGalaxyFlungOutOfTheFrameIsRejected() throws {
        var scene = try Self.meeting()
        // Fast enough to be a thousand kiloparsecs away by the end of the window.
        scene.galaxies[1].velocity += SIMD3(15, 0, 0)
        let check = SceneCheck.evaluate(scene, window: 50...1500)
        #expect(check.reasons.contains { if case .leavesFrame = $0 { true } else { false } })
        #expect(check.fieldRatio > SceneCheck.Limits().field)
    }

    @Test func everyReasonReadsAsASentence() {
        let reasons: [SceneCheck.Reason] = [
            .noApproach(closest: 30, needed: 12), .unstableDisk(galaxy: 1, toomre: 0.6),
            .overlapAtStart(first: 0, second: 1, separation: 3, limit: 9),
            .leavesFrame(radius: 800, limit: 300),
        ]
        for reason in reasons { #expect(!reason.description.contains("\n")) }
        #expect(reasons[1].description.contains("0.60"))
    }

    /// A generated library is mostly accepted and the check costs next to nothing: it has to
    /// be able to run on every draw.
    @Test func generatedScenesMostlyPassAndAreJudgedQuickly() {
        var accepted = 0
        let start = Date()
        let seeds = 1...40
        for seed in seeds {
            var scene = SceneConfig.contemplation(
                particleCount: 20_000, seed: UInt64(seed) &* 7919, haste: 0.5, galaxies: 2)
            scene.retimeEncounters(
                from: SceneConfig.contemplationWindow(haste: 0.5),
                to: scene.clipWindow(settleSteps: 400, steps: 3_000))
            scene.placeEncountersGivingWay()
            if scene.sanityCheck(settleSteps: 400, steps: 3_000).accepted { accepted += 1 }
        }
        #expect(accepted >= 30)
        #expect(Date().timeIntervalSince(start) < 20)
    }

    /// A camera follows a black hole while it is near its host and lets it go as it leaves.
    @Test func aCameraFramesABlackHoleOnlyNearItsHost() {
        let scene = Archetype.blackHolePass.scene(batchSeed: 2, occurrence: 0, particleCount: 10_000)
        let reach = SceneCheck.reach(scene.galaxies[0])
        let host = SIMD3<Float>(5, -3, 1)
        func framed(at distance: Float) -> SIMD3<Float> {
            scene.framedCentres([host, host + SIMD3(distance, 0, 0)])[1]
        }
        #expect(framed(at: reach * 0.8) == host + SIMD3(reach * 0.8, 0, 0))
        #expect(framed(at: reach * 2.5) == host)
        let leaving = stride(from: reach, through: reach * 2, by: reach / 20).map {
            simd_distance(framed(at: $0), host)
        }
        #expect(leaving.max()! < reach * 1.5 && leaving.last! < 1e-4)
        let pair = SceneConfig.merger(particleCount: 1_000)
        let far = [SIMD3<Float>(0, 0, 0), SIMD3<Float>(500, 0, 0)]
        #expect(pair.framedCentres(far) == far)
    }
}
