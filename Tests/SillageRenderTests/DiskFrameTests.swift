import Testing
import simd

@testable import SillageCore
@testable import SillageRender

@Suite("Density wave")
struct DiskFrameTests {
    private func spiral(_ solver: SolverKind) -> SceneConfig {
        var scene = SceneConfig.isolatedDisk(particleCount: 1_000)
        scene.solver = solver
        scene.galaxies[0].kind = .spiral
        scene.galaxies[0].armStrength = 0.82
        return scene
    }

    /// Arms made of material wind up within an orbit, and a disk holding a fifth of its
    /// galaxy's mass cannot raise a wave of its own to replace them: measured, the m = 2
    /// amplitude falls from 0.21 to 0.03 in 600 Myr and stays there. The painted wave is what
    /// keeps a spiral a spiral, so it has to be on whichever solver is running.
    @Test func theWaveIsPaintedForEitherSolver() {
        for solver in [SolverKind.restricted, SolverKind.barnesHut] {
            let scene = spiral(solver)
            let frames = DiskFrame.make(
                scene: scene, centers: scene.galaxies.map(\.position), time: 0, strength: 1)
            #expect(frames[0].axisV.w > 0.5)
        }
    }

    /// A wave that did not turn would be a material arm again, and would wind up with the
    /// disk. It turns at its own speed, slower than the stars passing through it.
    @Test func theWaveTurnsAtItsOwnSpeed() {
        let scene = spiral(.barnesHut)
        func phase(at time: Float) -> Float {
            DiskFrame.make(
                scene: scene, centers: scene.galaxies.map(\.position), time: time, strength: 1
            )[0].pattern.y
        }
        #expect(phase(at: 0) == 0)
        #expect(abs(phase(at: 10)) > 0)

        // Slower than the disk at two scale lengths, or the pattern would be the material.
        let galaxy = scene.galaxies[0]
        let reference = galaxy.diskScaleLength * 2
        let material = galaxy.potential.circularSpeed(atRadius: reference) / reference
        #expect(abs(phase(at: 1)) < material)
    }

    /// Turning the arms off has to leave a smooth disk rather than a faint pattern.
    @Test func noArmsMeansNoWave() {
        var scene = spiral(.barnesHut)
        scene.galaxies[0].armStrength = 0
        let frames = DiskFrame.make(
            scene: scene, centers: scene.galaxies.map(\.position), time: 0, strength: 1)
        #expect(frames[0].axisV.w == 0)

        var globular = spiral(.barnesHut)
        globular.galaxies[0].kind = .globular
        let spheroid = DiskFrame.make(
            scene: globular, centers: globular.galaxies.map(\.position), time: 0, strength: 1)
        #expect(spheroid[0].axisV.w == 0)
    }
}
