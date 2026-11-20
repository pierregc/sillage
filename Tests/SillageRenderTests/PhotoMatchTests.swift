import Foundation
import SillageCore
import Testing

@testable import SillageRender

#if canImport(simd)
    import simd
#endif

@Suite("Photo match")
struct PhotoMatchTests {
    /// Frames held in memory: every other star of a restricted Antennae run, `parity` choosing
    /// which, so a picture drawn from one half is matched with the other.
    struct Memory: PhotoMatch.Frames {
        var times: [Double]
        var positions: [[SIMD3<Float>]]
        var centresByFrame: [[SIMD3<Float>]]
        var parity: Int

        var count: Int { times.count }
        func megayears(_ frame: Int) -> Double { times[frame] }
        func stars(_ frame: Int, limit: Int) -> PhotoMatch.Stars {
            let kept = Swift.stride(from: parity, to: positions[frame].count, by: 2).map {
                positions[frame][$0]
            }
            return PhotoMatch.Stars(positions: kept, light: [Float](repeating: 1, count: kept.count))
        }
        func centres(_ frame: Int) -> [SIMD3<Float>] { centresByFrame[frame] }
    }

    /// 48 frames, 10 Myr apart from 150 Myr, of an Antennae drawn from the archetype at 4 000
    /// stars, run on the restricted solver at four times its step.
    static let run: Memory = {
        var scene = Archetype.antennae.scene(batchSeed: 1, occurrence: 0, particleCount: 4_000)
        scene.solver = .restricted
        scene.timeStep *= 4
        let solver = RestrictedSolver(scene: scene)
        let myrPerStep = Double(scene.timeStep) * Physics.megayearsPerTimeUnit
        var memory = Memory(times: [], positions: [], centresByFrame: [], parity: 0)
        var next = 150.0
        while memory.times.count < 48 {
            let now = Double(solver.time) * Physics.megayearsPerTimeUnit
            if now + myrPerStep / 2 >= next {
                memory.times.append(now)
                memory.positions.append(solver.particles.positions)
                memory.centresByFrame.append(solver.centers)
                next += 10
            }
            solver.step()
        }
        return memory
    }()

    static let truth = PhotoMatch.View(
        elevation: 35, azimuth: 140, roll: 25, kpcPerWidth: 260, origin: SIMD2(0.5, 0.42))
    static let truthFrame = 30

    /// Frame 30 of the run's even half from the true view, with a little noise and one pixel in
    /// twenty masked.
    static let picture: PhotoMatch.Picture = {
        let width = 96
        let height = 80
        let blank = PhotoMatch.Picture(
            width: width, height: height, light: [Float](repeating: 1, count: width * height), depth: 2.5)
        let grid = PhotoMatch.Target(blank, ceiling: -1, sigma: 0.6)
        var shown = run
        shown.parity = 0
        let stars = shown.stars(truthFrame, limit: .max)
        var light = PhotoMatch.render(
            PhotoMatch.Screen(stars, centres: [], elevation: truth.elevation, azimuth: truth.azimuth),
            view: truth, on: grid)
        let reference = PhotoMatch.percentile(light, 0.995)
        var generator = SeededGenerator(seed: 320)
        for index in light.indices {
            light[index] += reference * 0.002 * (generator.uniform() * 2 - 1)
            if generator.uniform() < 0.05 { light[index] = .nan }
        }
        return PhotoMatch.Picture(width: width, height: height, light: light, depth: 2.5, source: "synthetic")
    }()

    static var searched: Memory {
        var memory = run
        memory.parity = 1
        return memory
    }

    static var options: PhotoMatch.Options {
        var options = PhotoMatch.Options()
        options.moment = run.times[truthFrame] + 60
        options.within = 120
        var guess = truth
        guess.elevation += 15
        guess.azimuth -= 15
        guess.roll += 20
        options.view = guess
        options.span = 40
        options.coarseFrames = 12
        options.directionStep = 10
        return options
    }

    private func score(_ frame: Int, _ view: PhotoMatch.View, measure: PhotoMatch.Measure = .isophotes)
        -> Double
    {
        let target = PhotoMatch.Target(
            Self.picture, ceiling: -1, sigma: 1.5 * Float(Self.picture.width) / 256, measure: measure)
        let stars = Self.searched.stars(frame, limit: .max)
        return PhotoMatch.score(
            PhotoMatch.Screen(stars, centres: [], elevation: view.elevation, azimuth: view.azimuth),
            view: view, on: target)
    }

    @Test func viewsTurnTheSceneAsTheLookCameraDoes() {
        let side = PhotoMatch.View(elevation: 0, azimuth: 0, roll: 0, kpcPerWidth: 100)
        #expect(side.towardsViewer.y < -0.999)
        #expect(abs(side.place(SIMD3(10, 0, 0)).x - 0.6) < 1e-6)
        #expect(abs(side.place(SIMD3(0, 0, 10)).y - 0.4) < 1e-6)
        #expect(abs(side.place(SIMD3(0, 10, 0)).x - 0.5) < 1e-6)
        let above = PhotoMatch.View(elevation: 90, azimuth: 0, roll: 0, kpcPerWidth: 100)
        #expect(abs(above.place(SIMD3(0, 10, 0)).y - 0.4) < 1e-6)
        #expect(abs(above.place(SIMD3(10, 0, 0)).x - 0.6) < 1e-6)
        let rolled = PhotoMatch.View(elevation: 0, azimuth: 0, roll: 90, kpcPerWidth: 100)
        let placed = rolled.place(SIMD3(10, 0, 0))
        #expect(abs(placed.x - 0.5) < 1e-6 && abs(placed.y - 0.6) < 1e-6)
        let turned = PhotoMatch.View(elevation: 0, azimuth: 90, roll: 0)
        #expect(abs(turned.angle(to: side) - 90) < 1e-9)
        #expect(abs(turned.towardsViewer.x - 1) < 1e-9)
    }

    @Test func aPictureReadsAsTheScriptWritesIt() throws {
        let json = """
            {"version":1,"source":"a.jpg","width":3,"height":2,"depth":2.5,"nuclei":[[0.2,0.3],[0.7,0.4]],
             "light":[0,1,null,2,3,4]}
            """
        let picture = try PhotoMatch.Picture(data: Data(json.utf8))
        #expect(picture.width == 3 && picture.height == 2 && picture.source == "a.jpg")
        #expect(picture.seen == [true, true, false, true, true, true])
        #expect(picture.nuclei == [SIMD2(0.2, 0.3), SIMD2(0.7, 0.4)])
        let mirrored = picture.mirrored()
        #expect(mirrored.light[0].isNaN && mirrored.light[2] == 0 && mirrored.light[3] == 4)
        #expect(abs(mirrored.nuclei![0].x - 0.8) < 1e-12)
        #expect(throws: PhotoMatch.Failure.self) {
            try PhotoMatch.Picture(
                data: Data(#"{"version":1,"width":3,"height":2,"depth":2,"light":[1]}"#.utf8))
        }
    }

    @Test func aMapScoresOneAgainstItselfAndNothingAgainstTheDark() {
        let target = PhotoMatch.Target(Self.picture, ceiling: -1, sigma: 0.6)
        let light = Self.picture.light.map { $0.isNaN ? 0 : $0 }
        let blurred = PhotoMatch.blurred(light, mask: Self.picture.seen, width: 96, height: 80, sigma: 0.6)
        #expect(target.score(blurred) > 0.999)
        #expect(target.score([Float](repeating: 0, count: light.count)) < 1e-6)
        for measure in PhotoMatch.Measure.allCases {
            let value = score(Self.truthFrame, Self.truth, measure: measure)
            #expect(value > 0 && value <= 1)
        }
    }

    /// The cases where the eye is sure: the right moment against 100 Myr earlier, the right
    /// side against the opposite one, whose picture is the mirror.
    @Test func theRightMomentAndSideScoreHigher() {
        let truth = score(Self.truthFrame, Self.truth)
        #expect(truth > score(Self.truthFrame - 10, Self.truth) + 0.1)
        var opposite = Self.truth
        opposite.elevation = -opposite.elevation
        opposite.azimuth += 180
        let best = Swift.stride(from: 0.0, to: 360, by: 10).map { roll -> Double in
            var view = opposite
            view.roll = roll
            return score(Self.truthFrame, view)
        }.max()!
        #expect(truth > best + 0.1)
    }

    @Test func nucleiFixTheRollTheScaleAndTheShift() {
        let centres = Self.run.centres(Self.truthFrame)
        let nuclei = centres.prefix(2).map { Self.truth.place($0) }
        let screen = PhotoMatch.Screen(
            PhotoMatch.Stars(positions: [], light: []), centres: centres, elevation: Self.truth.elevation,
            azimuth: Self.truth.azimuth)
        let placed = PhotoMatch.placements(screen, nuclei: nuclei, view: Self.truth)
        let first = try! #require(placed.first)
        #expect(abs(PhotoMatch.wrapped(first.roll - Self.truth.roll)) < 1e-6)
        #expect(abs(first.kpcPerWidth - Self.truth.kpcPerWidth) < 1e-6)
        #expect(
            abs(first.origin.x - Self.truth.origin.x) < 1e-9
                && abs(first.origin.y - Self.truth.origin.y) < 1e-9)
    }

    /// A take's own frame, projected from a known direction and blurred, is found again within a
    /// few degrees and a few frames, from a guess 20 degrees and 60 Myr off; the mirrored picture
    /// scores lower. The scale is searched too, and trades a little against time.
    @Test func aTakesOwnFrameIsFoundAgain() throws {
        let outcome = try PhotoMatch.search(Self.picture, frames: Self.searched, options: Self.options)
        let best = outcome.best
        #expect(abs(best.frame - Self.truthFrame) <= 3)
        #expect(best.view.angle(to: Self.truth) < 5)
        #expect(abs(PhotoMatch.wrapped(best.view.roll - Self.truth.roll)) < 5)
        #expect(abs(best.view.kpcPerWidth / Self.truth.kpcPerWidth - 1) < 0.08)
        #expect(outcome.time.count >= 20 && outcome.roll.count == 91)
        #expect(outcome.takeLevels.count == Self.picture.light.count)
        let mirrored = try PhotoMatch.search(
            Self.picture.mirrored(), frames: Self.searched, options: Self.options)
        #expect(mirrored.best.score < best.score - 0.05)
    }

    /// With the scale known, as a named scene's distance gives it, time is pinned closer.
    @Test func aKnownScalePinsTheMoment() throws {
        var options = Self.options
        options.kpcPerWidth = Self.truth.kpcPerWidth
        let best = try PhotoMatch.search(Self.picture, frames: Self.searched, options: options).best
        #expect(abs(best.frame - Self.truthFrame) <= 1)
        #expect(best.view.angle(to: Self.truth) < 5)
        #expect(best.view.kpcPerWidth == Self.truth.kpcPerWidth)
    }

    @Test func aTakeOnDiskGivesTheLightOfItsShiningStars() throws {
        let scene = SceneConfig.merger(particleCount: 6)
        var system = ParticleSystem()
        let components: [ParticleComponent] = [.star, .dust, .bulge, .hiiRegion, .star, .star]
        for (index, component) in components.enumerated() {
            system.append(
                position: SIMD3(Float(index), 0, 0), velocity: .zero, galaxy: 0, radius: 1, population: 0.5,
                luminosity: Float(index + 1), formation: index == 5 ? 1 : ParticleSystem.ancient,
                component: component)
        }
        let recording = Recording(particleCount: 6, galaxyCount: 1)
        for time: Float in [0, 2] {
            system.positions.withUnsafeBufferPointer {
                recording.append(positions: $0.baseAddress!, time: time, centers: [.zero])
            }
        }
        recording.finish()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "match-\(UUID().uuidString).sillage")
        defer { try? FileManager.default.removeItem(at: url) }
        try RecordingFile.write(recording, scene: scene, particles: system, to: url)
        let frames = try PhotoMatch.TakeFrames(RecordingFile.read(from: url))
        #expect(frames.count == 2)
        #expect(frames.stars(0, limit: 100).light == [1, 3, 4, 5])
        #expect(frames.stars(1, limit: 100).light == [1, 3, 4, 5, 6])
        #expect(abs(frames.megayears(1) - 2 * Physics.megayearsPerTimeUnit) < 1e-3)
    }
}
