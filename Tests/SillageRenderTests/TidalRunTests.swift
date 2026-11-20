import Foundation
import Metal
import Testing

@testable import SillageCore
@testable import SillageRender

#if canImport(simd)
    import simd
#endif

@Suite("Tidal run")
struct TidalRunTests {
    /// Without the gas, the kernel's sub-steps by radius are `TidalDisruption.advance`'s, so the
    /// two agree to floating point noise through the pericentre.
    @Test func theKernelStepsAsTheReference() throws {
        var scene = TidalDisruption()
        scene.tracers = 4000
        scene.stickiness = 0
        scene.viscousOrbits = 0
        let run = try TidalRun(scene: scene)
        let start = run.frame
        run.step(400)
        let end = run.frame
        var worst: Float = 0
        for index in Swift.stride(from: 0, to: scene.tracers, by: 7) {
            let s = start.positions[index]
            let w = start.velocities[index]
            var position = SIMD3<Float>(s.x, s.y, s.z)
            var velocity = SIMD3<Float>(w.x, w.y, w.z)
            for _ in 0..<400 {
                #expect(
                    TidalDisruption.advance(&position, &velocity, by: scene.timeStep, swallow: scene.swallow))
            }
            let e = end.positions[index]
            worst = max(worst, simd_length(position - SIMD3<Float>(e.x, e.y, e.z)) / simd_length(position))
        }
        #expect(worst < 1e-3)
        #expect(abs(Double(end.time) - (run.releaseTime + 100)) < 1e-3)
    }

    /// The first passage binds almost nothing, and once the stream has come back and crossed
    /// itself the gas has the debris lose orbital energy and eccentricity that collisionless
    /// tracers keep (#334).
    @Test func theStreamComesBackAsADisk() throws {
        func after(gas: Bool) throws -> TidalMeasure.Row {
            var scene = TidalDisruption()
            scene.tracers = 200_000
            if !gas {
                scene.stickiness = 0
                scene.viscousOrbits = 0
            }
            let run = try TidalRun(scene: scene)
            let measure = run.measure()
            run.step(Int(2500 / scene.timeStep))
            return run.row(measure)
        }
        let gas = try after(gas: true)
        let none = try after(gas: false)
        #expect(gas.bound < 0.52, "the first passage binds \(gas.bound), from 0.48")
        #expect(gas.circularised > 2 * none.circularised, "\(gas.circularised) against \(none.circularised)")
        #expect(
            gas.eccentricity < none.eccentricity - 0.1, "\(gas.eccentricity) against \(none.eccentricity)")
    }

    /// A frame of `count` tracers in a thin annulus 19 to 21 r_s out, on circular orbits, plus
    /// whatever `motion` adds, from a height each.
    static func annulus(
        count: Int, height: Float, motion: (_ z: Float, _ index: Int) -> SIMD3<Float>
    ) -> TidalFrame {
        var positions: [SIMD4<Float>] = []
        var velocities: [SIMD4<Float>] = []
        var generator = SeededGenerator(seed: 7)
        for index in 0..<count {
            let r = 19 + 2 * generator.uniform()
            let angle = 2 * Float.pi * generator.uniform()
            let z = height * (2 * generator.uniform() - 1)
            let speed = TidalDisruption.circularSpeed(radius: r)
            let extra = motion(z, index)
            positions.append(SIMD4(r * cos(angle), r * sin(angle), z, 0))
            velocities.append(
                SIMD4(-speed * sin(angle) + extra.x, speed * cos(angle) + extra.y, extra.z, 0))
        }
        return TidalFrame(time: 0, positions: positions, velocities: velocities)
    }

    /// The tracers' mean light after a few steps: the heat the gas made of them.
    static func heated(_ frame: TidalFrame, heights: Int, crossing: Float) throws -> Float {
        var scene = TidalDisruption()
        scene.tracers = frame.count
        scene.stickiness = 50
        scene.crossingSpeed = crossing
        scene.viscousOrbits = 0
        var gas = GasGrid()
        gas.heights = heights
        let run = try TidalRun(scene: scene, gas: gas)
        run.resume(from: frame, step: 0)
        run.step(8)
        let light = run.frame.positions.map(\.w)
        return light.reduce(0, +) / Float(light.count)
    }

    /// Tracers falling towards the plane from both sides, as a cloud does at its pericentre, meet
    /// only in the plane, where they cross for real. Over a column the plane's grid sees them
    /// all at once and takes the whole squeeze for a crossing; the grid with height does not.
    @Test func aSqueezeThroughThePlaneIsNotACrossingWithHeight() throws {
        let frame = Self.annulus(count: 200_000, height: 1.5) { z, _ in SIMD3(0, 0, -0.04 * z) }
        let flat = try Self.heated(frame, heights: 1, crossing: 0.05)
        let tall = try Self.heated(frame, heights: 32, crossing: 0.05)
        #expect(flat > 0)
        #expect(tall < flat / 20, "\(tall) against \(flat)")
    }

    /// Two streams through the same place at different speeds go through each other with no gas,
    /// and with it meet at the mean of their velocities.
    @Test func streamsThatCrossMeetAtTheirMeanVelocity() throws {
        let frame = Self.annulus(count: 200_000, height: 0.5) { _, index in
            index % 2 == 0 ? .zero : SIMD3(0, 0, 0)
        }
        // The second stream's tangential speed is half as much again.
        var faster = frame
        for index in stride(from: 1, to: frame.count, by: 2) {
            faster.velocities[index].x *= 1.5
            faster.velocities[index].y *= 1.5
        }
        var scene = TidalDisruption()
        scene.tracers = frame.count
        scene.stickiness = 2000
        scene.viscousOrbits = 0
        func gap(_ frame: TidalFrame) -> Float {
            var (slow, fast): (Float, Float) = (0, 0)
            for index in 0..<frame.count {
                let p = frame.positions[index]
                let v = frame.velocities[index]
                let around = (p.x * v.y - p.y * v.x) / (p.x * p.x + p.y * p.y).squareRoot()
                if index % 2 == 0 { slow += around } else { fast += around }
            }
            return 2 * (fast - slow) / Float(frame.count)
        }
        let run = try TidalRun(scene: scene)
        run.resume(from: faster, step: 0)
        let before = gap(faster)
        run.step(40)
        let after = gap(run.frame)
        // What stays is the threshold's: tracers keep the motion against the mean below it.
        let threshold = 2 * scene.crossingSpeed * TidalDisruption.circularSpeed(radius: 20)
        #expect(after < 1.2 * threshold, "\(after) from \(before)")
        // Momentum goes where it came from.
        let moved = run.frame.velocities.reduce(SIMD3<Float>.zero) { $0 + SIMD3($1.x, $1.y, $1.z) }
        let started = faster.velocities.reduce(SIMD3<Float>.zero) { $0 + SIMD3($1.x, $1.y, $1.z) }
        #expect(simd_length(moved - started) / Float(frame.count) < 0.01)
    }

    /// The grid of the mean flow is summed in fixed point, so two runs of the same scene give
    /// the same tracers to the bit, through the first passage and the crossings after (#332).
    @Test func aRunRepeatsToTheBit() throws {
        var scene = TidalDisruption()
        scene.tracers = 30000
        let steps = Int(1000 / scene.timeStep)
        let first = try TidalRun(scene: scene)
        first.step(steps)
        let second = try TidalRun(scene: scene)
        second.step(steps / 2)
        second.step(steps - steps / 2)
        let (a, b) = (first.frame, second.frame)
        #expect(a.time == b.time)
        #expect(a.positions == b.positions)
        #expect(a.velocities == b.velocities)
        // Something happened: the gas heated part of the stream.
        #expect(a.positions.contains { $0.w > 0 })
    }

    /// A run that goes on from a frame it kept ends where a run that never stopped does, which is
    /// what lets an export draw any moment from a sparse take.
    @Test func aRunGoesOnFromAFrameAsIfItNeverStopped() throws {
        var scene = TidalDisruption()
        scene.tracers = 20000
        let whole = try TidalRun(scene: scene)
        whole.step(1200)
        let resumed = try TidalRun(scene: scene)
        resumed.step(700)
        let kept = resumed.frame
        let again = try TidalRun(scene: scene)
        again.resume(from: kept, step: 700)
        again.step(500)
        #expect(again.time == whole.time)
        #expect(again.frame == whole.frame)
    }

    /// A close up goes from its folder to videos through `hires` and `export`, in both shipped
    /// looks, and a moment between two frames of the take is the one the run had there.
    @Test func aCloseUpGoesFromItsFolderToVideos() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hole-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = SceneFolder(root.appendingPathComponent("batch/hole-0001", isDirectory: true))
        var scene = TidalDisruption()
        scene.tracers = 4000
        scene.duration = 200
        scene.frameInterval = 100
        try folder.create(HoleSceneFile(name: "test", blackHole: scene))
        let header = try HoleStage.run(folder, say: { _ in })
        #expect(Array(header.steps.prefix(3)) == [0, 400, 800] && header.steps.count == 4)
        let take = try HoleTakeFile.Loaded(contentsOf: folder.take)
        let replay = try HoleStage.Replay(take: take)
        #expect(replay.seek(800) == take.frame(2))
        #expect(replay.seek(400) == take.frame(1))
        let run = try TidalRun(scene: scene)
        run.step(600)
        #expect(replay.seek(600) == run.frame)

        for look in [nil, "film"] {
            var options = try HoleExportOptions([
                "--width", "160", "--height", "90", "--seconds", "0.5", "--fps", "8",
            ])
            options.look = look
            let report = try HoleStage.export(folder, options: options, say: { _ in })
            #expect(report.frames == 4)
            #expect(report.bytes > 0)
            #expect(report.url.lastPathComponent == (look == nil ? "1080p.mp4" : "film-1080p.mp4"))
        }
    }
}
