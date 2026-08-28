import Testing
import simd

@testable import SillageCore

@Suite("Restricted solver")
struct SolverTests {
    private func meanRadius(_ solver: RestrictedSolver) -> Double {
        var total = 0.0
        for position in solver.particles.positions { total += Double(simd_length(position)) }
        return total / Double(solver.particles.count)
    }

    @Test func circularOrbitStaysCircular() {
        var scene = SceneConfig.isolatedDisk(particleCount: 1)
        scene.timeStep = 0.005
        let solver = RestrictedSolver(scene: scene)
        let speed = scene.galaxies[0].potential.circularSpeed(atRadius: 8)
        solver.place(0, position: SIMD3<Float>(8, 0, 0), velocity: SIMD3<Float>(0, speed, 0))

        var minimum = Float.infinity
        var maximum: Float = 0
        let steps = Int(2 * Float.pi * 8 / speed / scene.timeStep)
        for _ in 0..<steps {
            solver.step()
            let radius = simd_length(solver.particles.positions[0])
            minimum = min(minimum, radius)
            maximum = max(maximum, radius)
        }
        #expect((maximum - minimum) / 8 < 1e-3)
    }

    @Test func isolatedDiskDoesNotExpand() {
        // Tracer solver, so tracer initial conditions. The preset is self-gravitating, and a
        // disk balanced against its own mass turns faster than the rigid potential alone can
        // hold, so sampling it that way and integrating it this way expands it by design.
        var scene = SceneConfig.isolatedDisk(particleCount: 20_000)
        scene.solver = .restricted
        let solver = RestrictedSolver(scene: scene)
        let before = meanRadius(solver)
        solver.step(count: 400)
        #expect(abs(meanRadius(solver) - before) / before < 0.01)
    }

    /// A pressure-supported sphere sampled in equilibrium with its own potential should
    /// neither expand nor collapse. Cutting the population off at a finite radius leaves the
    /// outer shells slightly under-pressured, so a couple of percent of adjustment over the
    /// first orbit is expected; sampling the wrong velocity distribution gives three times
    /// that, which is what this guards against.
    @Test(arguments: PotentialProfile.allCases)
    func globularStaysInEquilibrium(profile: PotentialProfile) {
        let scene = SceneConfig(
            name: "globular",
            galaxies: [
                GalaxyConfig(
                    name: "cluster",
                    particleCount: 30_000,
                    kind: .globular,
                    potential: GalaxyPotential(profile: profile, mass: 40, scaleRadius: 4),
                    diskScaleLength: 4,
                    diskTruncation: 5
                )
            ],
            timeStep: 0.02
        )
        let solver = RestrictedSolver(scene: scene)
        let before = meanRadius(solver)
        solver.step(count: 600)
        #expect(abs(meanRadius(solver) - before) / before < 0.035)
    }

    @Test func centreEnergyIsConserved() {
        let solver = RestrictedSolver(scene: SceneConfig.merger(particleCount: 2_000))
        let before = solver.centerEnergy()
        solver.step(count: 2_000)
        #expect(abs((solver.centerEnergy() - before) / before) < 1e-5)
    }

    @Test func centreMomentumIsConservedExactly() {
        let solver = RestrictedSolver(scene: SceneConfig.merger(particleCount: 1_000))
        let before = solver.centerMomentum()
        solver.step(count: 1_000)
        #expect(simd_length(solver.centerMomentum() - before) < 1e-9)
    }

    @Test func encounterRaisesTidalTails() {
        let solver = RestrictedSolver(scene: SceneConfig.merger(particleCount: 20_000))
        func extent() -> Float {
            var maximum: Float = 0
            let centres = solver.centers
            for (index, position) in solver.particles.positions.enumerated() {
                maximum = max(
                    maximum, simd_length(position - centres[Int(solver.particles.galaxyIndex[index])]))
            }
            return maximum
        }
        // Pericentre falls around step 1 000 for this preset and the tails need roughly as
        // long again to unwind, so the horizon has to cover the whole passage.
        let before = extent()
        solver.step(count: 4_000)
        #expect(extent() > 2.5 * before)
    }

    @Test func sameSeedGivesSameState() {
        let a = RestrictedSolver(scene: SceneConfig.merger(particleCount: 2_000, seed: 5))
        let b = RestrictedSolver(scene: SceneConfig.merger(particleCount: 2_000, seed: 5))
        a.step(count: 100)
        b.step(count: 100)
        #expect(a.particles.positions == b.particles.positions)
        #expect(a.time == b.time)
    }

    @Test func factoryRejectsUnimplementedSolver() {
        var scene = SceneConfig.merger(particleCount: 100)
        scene.solver = .barnesHut
        #expect(throws: SillageError.self) { try SolverFactory.make(scene) }
    }

    @Test func stateStaysFinite() {
        let solver = RestrictedSolver(scene: SceneConfig.merger(particleCount: 5_000))
        solver.step(count: 3_000)
        #expect(solver.particles.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite })
    }
}
