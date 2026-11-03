import Foundation
import Metal
import Testing
import simd

@testable import SillageCore
@testable import SillageRender

/// The tracers' force error against their opening angle, on scene-0031 at t = 0 and on an
/// isolated disk, against the same tracers walked at 0.3.
@Suite("Debug theta")
struct DebugTheta {
    func errors(sample drawn: SceneConfig, scene file: SceneConfig, massive: Int, thetas: [Float]) throws {
        let sampled = RestrictedSolver.sampleParticles(for: drawn)
        let (split, tracers) = sampled.splittingLightTracers(massive: massive, seed: 3)
        var reference = file
        reference.openingAngle = 0.3
        let exact = try MetalBarnesHutSolver(scene: reference, particles: split, tracers: tracers)
            .accelerations
        for theta in thetas {
            var loose = file
            loose.openingAngle = theta
            let computed = try MetalBarnesHutSolver(scene: loose, particles: split, tracers: tracers)
                .accelerations
            var errors: [Float] = []
            var bias = SIMD3<Double>.zero
            for index in stride(from: 0, to: tracers, by: 7) {
                let truth = exact[index]
                let error = simd_length(computed[index] - truth) / max(simd_length(truth), 1e-9)
                errors.append(error)
                // The part of the error along the true pull: a systematic drag or boost.
                bias += SIMD3<Double>(
                    Double(simd_dot(computed[index] - truth, truth) / max(simd_length_squared(truth), 1e-18)),
                    0, 0)
            }
            errors.sort()
            let mean = errors.reduce(0, +) / Float(errors.count)
            print(
                String(
                    format: "DEBUG %@ theta %.1f: mean %.3f %%, median %.3f %%, p99 %.3f %%, radial bias %.4f %%",
                    file.name, theta, mean * 100, errors[errors.count / 2] * 100,
                    errors[errors.count * 99 / 100] * 100, bias.x / Double(errors.count) * 100))
        }
    }

    @Test func scene0031() throws {
        let path = NSString(string: "~/claude-workspace/sillage/library/2026-10-30-b/scene-0031/scene.json")
            .expandingTildeInPath
        let file = try SceneFile.decoded(from: Data(contentsOf: URL(fileURLWithPath: path)))
        try errors(
            sample: file.scene(particleCount: 2_000_000), scene: file.scene(particleCount: 500_000),
            massive: 500_000, thetas: [0.9, 1.1, 1.3, 1.5])
    }
}
