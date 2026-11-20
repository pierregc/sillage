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

    /// The gas only ever takes energy away, and once the stream has come back, the run holds a
    /// disk: tracers bound inside 20 r_s, and some swallowed.
    @Test func theStreamComesBackAsADisk() throws {
        var scene = TidalDisruption()
        scene.tracers = 20000
        let run = try TidalRun(scene: scene)
        func energy(_ frame: TidalFrame) -> Double {
            var total = 0.0
            for (p, v) in zip(frame.positions, frame.velocities) where v.w >= 0 {
                let r = simd_length(SIMD3<Float>(p.x, p.y, p.z))
                total += Double(simd_length_squared(SIMD3<Float>(v.x, v.y, v.z)) / 2 - 1 / (r - 1))
            }
            return total
        }
        let released = energy(run.frame)
        run.step(Int(3000 / scene.timeStep))
        let frame = run.frame
        #expect(energy(frame) < released)
        let alive = frame.velocities.filter { $0.w >= 0 }.count
        let inside = zip(frame.positions, frame.velocities).filter { p, v in
            v.w >= 0 && simd_length(SIMD3<Float>(p.x, p.y, p.z)) < 20
        }.count
        #expect(alive < scene.tracers)
        #expect(inside > scene.tracers / 20)
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
