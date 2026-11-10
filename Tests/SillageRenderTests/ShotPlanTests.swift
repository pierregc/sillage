import Foundation
import Testing

@testable import SillageCore
@testable import SillageRender
#if canImport(simd)
    import simd
#endif

@Suite("Shot plan")
struct ShotPlanTests {
    /// Two galaxies falling past each other: 120 kpc apart, 8 at frame 300, 240 at the end.
    private func flyby(
        frames: Int = 900, particles: [Int] = [1_000_000, 800_000]
    ) -> ShotPlan.Track {
        let centres = (0..<frames).map { frame -> [SIMD3<Float>] in
            let r = SIMD3<Float>(0.4 * Float(frame - 300), 8, 0)
            return [-r / 2, r / 2]
        }
        return ShotPlan.Track(
            centres: centres, disruption: centres.map { _ in [0, 0] }, reach: [15, 12],
            margin: [20, 16], particles: particles, natal: [SIMD3(0, 0, 1), SIMD3(0, 0, 1)])
    }

    private func plan(_ track: ShotPlan.Track) -> ShotPlan {
        ShotPlan(
            track: track, camera: LookFile.CameraPlan(mode: .director), fieldOfView: 0.6,
            framesPerSecond: 30, seed: 9)
    }

    @Test func theShotsCoverTheClipInOrder() {
        let shots = plan(flyby()).shots
        #expect(shots.first?.start == 0)
        #expect(shots.last?.end == 900)
        for (before, after) in zip(shots, shots.dropFirst()) {
            #expect(before.end == after.start)
            #expect(before.subject != after.subject)
        }
        // Two and a half seconds at the least: a cut sooner than that reads as a flicker.
        for shot in shots { #expect(shot.frames >= 75, "\(shot)") }
    }

    /// A share of the clip, not all of it: the wide shots are what shows the encounter.
    @Test func aShareOfTheClipIsClose() {
        let plan = plan(flyby())
        #expect(plan.closeShare > 0.25 && plan.closeShare < 0.6, "\(plan.closeShare)")
        guard case .disk = plan.shots.first?.subject else {
            Issue.record("opens on \(String(describing: plan.shots.first))")
            return
        }
        guard case .disk = plan.shots.last?.subject else {
            Issue.record("ends on \(String(describing: plan.shots.last))")
            return
        }
        #expect(plan.shots.contains { $0.subject == .wide })
        let pericentre = plan.shots.first { $0.subject == .pericentre(0, 1) }
        #expect(pericentre.map { $0.start < 300 && $0.end > 300 } == true)
    }

    /// Two thirds of the frame or more, which is where a disk stopped reading as particles.
    @Test func aCloseShotFillsTheFrame() {
        let track = flyby()
        let plan = plan(track)
        for aspect: Float in [16.0 / 9.0, 9.0 / 16.0] {
            for shot in plan.shots {
                guard case .disk(let galaxy) = shot.subject else { continue }
                for frame in [shot.start, (shot.start + shot.end) / 2, shot.end - 1] {
                    let camera = plan.camera(atCaptured: Double(frame), aspect: aspect)
                    let distance = simd_distance(camera.eye, camera.target)
                    let half = distance * tan(camera.fieldOfView / 2) * min(aspect, 1)
                    let filled = track.reach[galaxy] / half
                    #expect(filled > 0.7 && filled < 0.95, "\(filled) at \(frame), \(aspect)")
                }
            }
        }
    }

    /// Slow inside a shot: a cut is the only place the camera may jump.
    @Test func theCameraOnlyJumpsAtCuts() {
        let plan = plan(flyby())
        var previous = plan.camera(atCaptured: 0, aspect: 16.0 / 9.0)
        for frame in 1..<900 {
            let camera = plan.camera(atCaptured: Double(frame), aspect: 16.0 / 9.0)
            if !plan.cuts.contains(frame) {
                let moved = simd_distance(camera.eye, previous.eye)
                let reach = simd_distance(camera.eye, camera.target)
                #expect(moved < reach * 0.01, "\(moved) of \(reach) at \(frame)")
            }
            previous = camera
        }
    }

    /// A video drawn at a higher rate than the take asks for positions between frames; across
    /// a cut that must be one shot or the other, never a blend of both.
    @Test func nothingBetweenTwoShotsIsDrawn() {
        let plan = plan(flyby())
        for cut in plan.cuts {
            let before = plan.camera(atCaptured: Double(cut - 1), aspect: 1.5)
            let after = plan.camera(atCaptured: Double(cut), aspect: 1.5)
            for x in [Double(cut) - 0.75, Double(cut) - 0.5, Double(cut) - 0.25] {
                let eye = plan.camera(atCaptured: x, aspect: 1.5).eye
                #expect(
                    simd_distance(eye, before.eye) < 1e-3 || simd_distance(eye, after.eye) < 1e-3)
            }
        }
    }

    /// The pair across the frame and both inside it, at the closest moment.
    @Test func thePericentreHoldsBothCores() {
        let track = flyby()
        let plan = plan(track)
        let camera = plan.camera(atCaptured: 300, aspect: 16.0 / 9.0)
        let forward = simd_normalize(camera.target - camera.eye)
        for centre in track.centres[300] {
            let toward = simd_normalize(centre - camera.eye)
            #expect(acos(simd_dot(forward, toward)) < camera.fieldOfView / 2)
        }
        let line = simd_normalize(track.centres[300][1] - track.centres[300][0])
        let up = simd_normalize(camera.up - simd_dot(camera.up, forward) * forward)
        #expect(abs(simd_dot(line, up)) < 0.2)

        // And still both in frame as they part, at the end of the shot.
        guard let shot = plan.shots.first(where: { $0.subject == .pericentre(0, 1) }) else {
            Issue.record("no pericentre shot")
            return
        }
        let last = plan.camera(atCaptured: Double(shot.end - 1), aspect: 16.0 / 9.0)
        let ahead = simd_normalize(last.target - last.eye)
        let right = simd_normalize(simd_cross(ahead, last.up))
        let above = simd_cross(right, ahead)
        for centre in track.centres[shot.end - 1] {
            let toward = centre - last.eye
            let depth = simd_dot(toward, ahead)
            let half = tan(last.fieldOfView / 2)
            #expect(abs(simd_dot(toward, above)) / depth < half)
            #expect(abs(simd_dot(toward, right)) / depth < half * 16 / 9)
        }
    }

    @Test func aLoneDiskIsFilmedCloseWideClose() {
        let track = ShotPlan.Track(
            centres: Array(repeating: [.zero], count: 600), disruption: Array(repeating: [0], count: 600),
            reach: [15], margin: [20], particles: [500_000], natal: [SIMD3(0, 0, 1)])
        #expect(plan(track).shots.map(\.subject) == [.disk(0), .wide, .disk(0)])
    }

    @Test func aShortClipStaysWide() {
        #expect(plan(flyby(frames: 200)).shots.map(\.subject) == [.wide])
    }

    /// Framed as large, a galaxy of a few hundred thousand particles is soft blots.
    @Test func aSmallGalaxyIsNotFilmedClose() {
        let plan = plan(flyby(particles: [1_000_000, 50_000]))
        #expect(!plan.shots.contains { $0.subject == .disk(1) })
        #expect(plan.shots.contains { $0.subject == .disk(0) })
    }

    @Test func aSeedFullyDeterminesThePlan() {
        let a = plan(flyby())
        let b = plan(flyby())
        #expect(a.shots == b.shots)
        for frame in stride(from: 0, to: 900, by: 37) {
            let one = a.camera(atCaptured: Double(frame), aspect: 1.5)
            let two = b.camera(atCaptured: Double(frame), aspect: 1.5)
            #expect(simd_distance(one.eye, two.eye) < 1e-4)
        }
    }

    /// A tilted disk is thinnest along its normal, whatever the bulge does.
    @Test func thePlaneOfADiskIsFound() {
        let normal = simd_normalize(SIMD3<Float>(0.5, -0.3, 0.8))
        let across = simd_normalize(simd_cross(normal, SIMD3(0, 0, 1)))
        let along = simd_cross(normal, across)
        var generator = SeededGenerator(seed: 3)
        var points: [(offset: SIMD3<Float>, light: Float)] = []
        for _ in 0..<4000 {
            let radius = 10 * generator.uniform()
            let angle = 2 * Float.pi * generator.uniform()
            let height = 0.3 * generator.normal()
            points.append(
                (radius * (cos(angle) * across + sin(angle) * along) + height * normal, 1))
        }
        for _ in 0..<500 {
            points.append((SIMD3(generator.normal(), generator.normal(), generator.normal()), 3))
        }
        #expect(abs(simd_dot(LightMeter.thinnest(points), normal)) > 0.99)
    }

    /// The core is where the particles crowd, not where the centre given says it is.
    @Test func theCoreIsWhereTheLightIs() {
        var generator = SeededGenerator(seed: 4)
        var offsets: [SIMD3<Float>] = []
        for _ in 0..<3000 {
            offsets.append(
                SIMD3(8, 3, 0) + 0.8 * SIMD3(generator.normal(), generator.normal(), generator.normal()))
        }
        for _ in 0..<3000 {
            offsets.append(SIMD3(generator.uniform(in: -30...30), generator.uniform(in: -30...30), 0))
        }
        let core = LightMeter.densest(offsets, from: 15)
        #expect(simd_distance(core, SIMD3(8, 3, 0)) < 0.5, "\(core)")
    }
}
