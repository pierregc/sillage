import Metal
import Testing
import simd

@testable import SillageCore
@testable import SillageRender

@Suite("Light tracers")
struct LightTracerTests {
    private func selfGravitatingDisk(_ count: Int) -> SceneConfig {
        var scene = SceneConfig.isolatedDisk(particleCount: count)
        scene.galaxies[0].kind = .spiral
        scene.galaxies[0].haloParticleRatio = 1.5
        scene.timeStepScale = 8
        scene.retune()
        return scene
    }

    @Test func splittingKeepsEachGalaxysMassAndPutsTheTracersFirst() {
        let scene = selfGravitatingDisk(20_000)
        let sampled = RestrictedSolver.sampleParticles(for: scene)
        let (split, tracers) = ParticleSystem.lightTracers(
            drawn: scene, massive: selfGravitatingDisk(5_000))

        #expect(split.visibleCount == sampled.visibleCount)
        #expect(abs(split.visibleCount - tracers - 5_000) < 400)
        #expect((0..<tracers).allSatisfy { split.mass[$0] == 0 })
        #expect((tracers..<split.count).allSatisfy { split.mass[$0] > 0 })
        #expect(
            (0..<split.visibleCount).allSatisfy {
                split.component[$0] != ParticleComponent.halo.rawValue
            })
        func mass(_ system: ParticleSystem, halo: Bool) -> Double {
            (0..<system.count).reduce(0) {
                (system.component[$1] == ParticleComponent.halo.rawValue) == halo
                    ? $0 + Double(system.mass[$1]) : $0
            }
        }
        for halo in [false, true] {
            let before = mass(sampled, halo: halo)
            #expect(abs(mass(split, halo: halo) - before) / before < 1e-4)
        }
        // The dark matter is drawn at the massive count, 1.5 a massive particle, and none of it
        // was drawn only to be thrown away.
        #expect(split.count - split.visibleCount == 7_500)
        #expect(sampled.count - sampled.visibleCount == 30_000)
    }

    /// Split alone, a sample keeps all of its dark matter: the halo is drawn at the massive
    /// count before, and nothing else moves.
    @Test func theDarkMatterIsDrawnAtTheMassiveCount() {
        let drawn = selfGravitatingDisk(20_000)
        let massive = selfGravitatingDisk(5_000)
        let sampled = RestrictedSolver.sampleParticles(
            for: drawn, haloCounts: massive.galaxies.map(\.haloParticleCount))
        #expect(sampled.visibleCount == 20_000 && sampled.count == 27_500)
        let haloMass = (sampled.visibleCount..<sampled.count).map { Double(sampled.mass[$0]) }
        let expected = Double(drawn.galaxies[0].potential.mass * (1 - drawn.galaxies[0].diskMassFraction))
        #expect(abs(haloMass.reduce(0, +) / expected - 1) < 1e-4)
        let (split, _) = sampled.splittingLightTracers(massive: 5_000, seed: 3)
        #expect(split.count - split.visibleCount == 7_500)
        // Without halo counts, the sample is the one every run without tracers has always had.
        let plain = RestrictedSolver.sampleParticles(for: drawn)
        let again = RestrictedSolver.sampleParticles(for: drawn, haloCounts: nil)
        #expect(plain.positions == again.positions && plain.mass == again.mass)
    }

    /// A tracer walks at the scene's opening angle: at 1.3 the tracers were pulled short and
    /// drifted 4 % off the mass over a merger (docs/notes/light-tracers.md).
    @Test func theTracersWalkAtTheScenesOpeningAngle() throws {
        for angle: Float in [0.9, 0.7] {
            var scene = selfGravitatingDisk(4_000)
            scene.openingAngle = angle
            let (split, tracers) = ParticleSystem.lightTracers(
                drawn: scene, massive: selfGravitatingDisk(1_000))
            let solver = try MetalBarnesHutSolver(scene: scene, particles: split, tracers: tracers)
            #expect(solver.tracerOpeningAngle == angle)
        }
    }

    /// The tree is the massive particles' alone, so adding tracers moves none of them.
    @Test func theMassiveParticlesIgnoreTheirTracers() throws {
        let scene = selfGravitatingDisk(12_000)
        let (split, tracers) = ParticleSystem.lightTracers(
            drawn: scene, massive: selfGravitatingDisk(3_000))
        let alone = split.slice(tracers..<split.count)

        let reference = try MetalBarnesHutSolver(scene: scene, particles: alone)
        let traced = try MetalBarnesHutSolver(scene: scene, particles: split, tracers: tracers)
        reference.step(count: 3)
        traced.step(count: 3)
        let expected = reference.particles.positions
        let positions = traced.particles.positions
        var worst: Float = 0
        for index in expected.indices {
            worst = max(worst, simd_length(expected[index] - positions[tracers + index]))
        }
        // The halo centres are summed in other blocks, which can move a last bit.
        #expect(worst < 1e-5)
    }

    /// A tracer anywhere feels what direct summation over the massive particles says.
    @Test func aTracerFeelsTheMassiveField() throws {
        var generator = SeededGenerator(seed: 5)
        var particles = ParticleSystem(capacity: 6_000)
        var massive: [SIMD3<Float>] = []
        var mass: [Float] = []
        // Tracers first, then the massive cluster.
        for _ in 0..<2_000 {
            let position =
                SIMD3<Float>(generator.normal(), generator.normal(), generator.normal() * 0.3) * 9
            particles.append(position: position, velocity: .zero, galaxy: 0, radius: 1, mass: 0)
        }
        for _ in 0..<4_000 {
            let position =
                SIMD3<Float>(generator.normal(), generator.normal(), generator.normal() * 0.3) * 7
            particles.append(position: position, velocity: .zero, galaxy: 0, radius: 1, mass: 0.002)
            massive.append(position)
            mass.append(0.002)
        }
        particles.setVisibleCount(particles.count)
        var scene = SceneConfig(
            name: "cluster",
            galaxies: [
                GalaxyConfig(
                    name: "cluster", particleCount: 4_000,
                    potential: GalaxyPotential(profile: .plummer, mass: 10, scaleRadius: 3),
                    diskScaleLength: 3, diskMassFraction: 1)
            ],
            solver: .barnesHut, timeStep: 0.001, openingAngle: 0.4, softening: 0.25)
        scene.softening = 0.25

        let solver = try MetalBarnesHutSolver(scene: scene, particles: particles, tracers: 2_000)
        let computed = solver.accelerations
        var meanError: Float = 0
        var worst: Float = 0
        var samples = 0
        for index in stride(from: 0, to: 2_000, by: 23) {
            let reference = BarnesHutTree.directAcceleration(
                at: particles.positions[index], positions: massive, mass: mass, softening: 0.25,
                skipping: -1)
            let error =
                simd_length(computed[index] - reference) / max(simd_length(reference), 1e-6)
            meanError += error
            worst = max(worst, error)
            samples += 1
        }
        meanError /= Float(samples)
        #expect(meanError < 0.02)
        #expect(worst < 0.15)
    }

    /// Tracer gas forms stars at the rate the massive gas around it does, provided the
    /// softening is the massive count's: softened for twice as many, the massive particles
    /// cluster among themselves, which the tracers cannot, and tracer gas formed a third less.
    @Test func tracerGasFormsStarsLikeTheMassiveGas() throws {
        let (split, tracers) = ParticleSystem.lightTracers(
            drawn: selfGravitatingDisk(80_000), massive: selfGravitatingDisk(40_000))
        let solver = try MetalBarnesHutSolver(
            scene: selfGravitatingDisk(40_000), particles: split, tracers: tracers)
        solver.step(count: 400)
        let after = solver.particles

        func share(_ range: Range<Int>) -> (formed: Double, gas: Int) {
            var gas = 0
            var formed = 0
            for index in range where after.component[index] == ParticleComponent.dust.rawValue {
                gas += 1
                if after.formation[index] < 1e8 { formed += 1 }
            }
            return (Double(formed) / Double(max(gas, 1)), gas)
        }
        let light = share(0..<tracers)
        let heavy = share(tracers..<after.visibleCount)
        #expect(light.gas > 0 && heavy.gas > 0)
        #expect(heavy.formed > 0)
        #expect(light.formed > heavy.formed * 0.75 && light.formed < heavy.formed * 1.33)
        // Only gas forms anything.
        for index in 0..<tracers where after.component[index] != ParticleComponent.dust.rawValue {
            #expect(after.formation[index] == split.formation[index])
        }
    }
}
