import Foundation
import Testing

@testable import SillageCore
@testable import SillageRender

#if canImport(simd)
    import simd
#endif

@Suite("Light tracers")
struct LightTracerTests {
    func selfGravitatingDisk(_ count: Int) -> SceneConfig {
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

    /// Streamed a chunk at a time, the split keeps the same massive set to the bit and every
    /// tracer as it was, its attributes to the steps they are packed at (#238).
    @Test func streamingSplitsAsTheWholeSampleDid() {
        let drawn = selfGravitatingDisk(30_000)
        let massive = selfGravitatingDisk(6_000)
        let (split, tracers) = ParticleSystem.lightTracers(drawn: drawn, massive: massive)
        var chunks: [LightTracerChunk] = []
        let (set, streamed) = ParticleSystem.streamingLightTracers(
            drawn: drawn, massive: massive, chunk: 4_096
        ) { chunks.append($0) }
        #expect(streamed == tracers)
        #expect(ParticleSystem.lightTracerTotal(drawn: drawn, massive: massive) == split.count)

        let alone = split.slice(tracers..<split.count)
        #expect(set.count == alone.count && set.visibleCount == alone.visibleCount)
        #expect(set.positions == alone.positions && set.velocities == alone.velocities)
        #expect(set.mass == alone.mass && set.galaxyIndex == alone.galaxyIndex)
        #expect(set.component == alone.component && set.formation == alone.formation)
        #expect(set.luminosity == alone.luminosity && set.kernelScale == alone.kernelScale)
        #expect(set.birthRadius == alone.birthRadius && set.population == alone.population)

        let states = chunks.flatMap(\.states)
        let motions = chunks.flatMap(\.motions)
        #expect(states.count == tracers && motions.count == tracers)
        let exact = (0..<min(tracers, states.count)).allSatisfy { index in
            let word = TracerWord(bits: motions[index].w)
            let velocity = SIMD3(
                Float(bitPattern: motions[index].x), Float(bitPattern: motions[index].y),
                Float(bitPattern: motions[index].z))
            return SIMD3(states[index].x, states[index].y, states[index].z) == split.positions[index]
                && velocity == split.velocities[index] && states[index].w == split.formation[index]
                && word.galaxy == split.galaxyIndex[index] && word.component == split.component[index]
                && word.kernelScale == split.kernelScale[index]
        }
        #expect(exact)
        var light: Float = 0
        var radius: Float = 0
        for index in 0..<min(tracers, motions.count) {
            let word = TracerWord(bits: motions[index].w)
            light = max(light, abs(word.luminosity / split.luminosity[index] - 1))
            radius = max(radius, abs(word.birthRadius / max(split.birthRadius[index], 1e-3) - 1))
        }
        #expect(light < 0.03)
        #expect(radius < 6e-4)
    }

    @Test func aTracerWordKeepsItsAttributes() {
        for galaxy: UInt32 in [0, 7, 15] {
            for component in ParticleComponent.allCases {
                for scale in TracerWord.kernelScales {
                    for (light, radius) in [(Float(1), Float(3.2)), (0.05, 0.01), (37, 140), (0, 0)] {
                        let word = TracerWord(
                            galaxy: galaxy, component: component.rawValue, kernelScale: scale,
                            luminosity: light, birthRadius: radius)
                        #expect(word.galaxy == galaxy && word.component == component.rawValue)
                        #expect(word.kernelScale == scale)
                        #expect(light == 0 ? word.luminosity == 0 : abs(word.luminosity / light - 1) < 0.03)
                        #expect(
                            radius == 0 ? word.birthRadius == 0 : abs(word.birthRadius / radius - 1) < 6e-4)
                    }
                }
            }
        }
    }
}
