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

    @Test func aFrameReadsBackAsItWasWritten() throws {
        let frame = TidalFrame(
            time: 12.5, positions: [SIMD4<Float>(1, 2, 3, 4), SIMD4<Float>(5, 6, 7, 8)],
            velocities: [SIMD4<Float>(-1, -2, -3, -4), SIMD4<Float>(0, 0, 0, 0.5)])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tidal-\(UUID()).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        try frame.write(to: url)
        let read = try TidalFrame(contentsOf: url)
        #expect(read.time == 12.5)
        #expect(read.positions == frame.positions)
        #expect(read.velocities == frame.velocities)
    }
}
