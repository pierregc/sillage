import Metal
import Testing
import simd

@testable import SillageCore
@testable import SillageRender

@Suite("Debug formation")
struct DebugFormation {
    @Test(arguments: [(400_000, 20), (400_000, 80), (400_000, 320)])
    func rates(_ setup: (Int, Int)) throws {
        var scene = SceneConfig.isolatedDisk(particleCount: setup.0)
        scene.galaxies[0].kind = .spiral
        scene.galaxies[0].haloParticleRatio = 1.5
        scene.timeStepScale = 8
        let massiveScene: SceneConfig = {
            var s = SceneConfig.isolatedDisk(particleCount: setup.0 / 2)
            s.galaxies[0].kind = .spiral
            s.galaxies[0].haloParticleRatio = 1.5
            s.timeStepScale = 8
            s.retune()
            return s
        }()
        scene.retune()
        let sampled = RestrictedSolver.sampleParticles(for: scene)
        let (split, tracers) = sampled.splittingLightTracers(massive: setup.0 / 2, seed: 2)
        let solver = try MetalBarnesHutSolver(scene: massiveScene, particles: split, tracers: tracers)
        solver.step(count: setup.1)
        let after = solver.particles
        func share(_ range: Range<Int>) -> (Double, Int, Int) {
            var gas = 0
            var formed = 0
            for index in range where after.component[index] == ParticleComponent.dust.rawValue {
                gas += 1
                if after.formation[index] < 1e8 { formed += 1 }
            }
            return (Double(formed) / Double(max(gas, 1)), formed, gas)
        }
        print("DEBUG steps \(setup.1) light \(share(0..<tracers)) heavy \(share(tracers..<after.visibleCount))")
    }
}
