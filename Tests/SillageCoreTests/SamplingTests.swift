import Testing
import simd

@testable import SillageCore

@Suite("Sampling")
struct SamplingTests {
    @Test func generatorIsDeterministic() {
        var a = SeededGenerator(seed: 42)
        var b = SeededGenerator(seed: 42)
        var c = SeededGenerator(seed: 43)
        let first = (0..<64).map { _ in a.uniform() }
        #expect(first == (0..<64).map { _ in b.uniform() })
        #expect(first != (0..<64).map { _ in c.uniform() })
    }

    @Test func uniformStaysInRange() {
        var generator = SeededGenerator(seed: 9)
        for _ in 0..<10_000 {
            let value = generator.uniform()
            #expect(value >= 0 && value < 1)
        }
    }

    /// Mean radius of a truncated exponential disk: the ratio of the second to the first
    /// moment of x*exp(-x), which is 1.6774 scale lengths at a truncation of 4.
    @Test func exponentialDiskMatchesAnalyticMean() {
        var generator = SeededGenerator(seed: 7)
        var total = 0.0
        let samples = 200_000
        for _ in 0..<samples {
            total += Double(DiskSampler.inverseExponentialCDF(generator.uniform(), truncation: 4))
        }
        #expect(abs(total / Double(samples) - 1.6774) < 0.02)
    }

    @Test func sampledDiskRespectsTruncation() {
        let config = GalaxyConfig(
            name: "test",
            particleCount: 20_000,
            potential: GalaxyPotential(profile: .hernquist, mass: 50, scaleRadius: 5),
            diskScaleLength: 4,
            diskTruncation: 4
        )
        var system = ParticleSystem()
        var generator = SeededGenerator(seed: 3)
        DiskSampler.sample(config, galaxyIndex: 0, into: &system, using: &generator)

        #expect(system.count == 20_000)
        #expect(system.birthRadius.allSatisfy { $0 <= 16.0001 })
        #expect(system.galaxyIndex.allSatisfy { $0 == 0 })
    }

    @Test func orientationIsRigid() {
        let config = GalaxyConfig(
            name: "tilted",
            particleCount: 1,
            potential: GalaxyPotential(profile: .plummer, mass: 1, scaleRadius: 1),
            diskScaleLength: 1,
            inclination: 0.7,
            positionAngle: 1.3
        )
        let rotation = config.orientation
        let vector = SIMD3<Float>(1, 2, -3)
        #expect(abs(simd_length(rotation * vector) - simd_length(vector)) < 1e-5)
        #expect(abs(simd_determinant(rotation) - 1) < 1e-5)
    }

    @Test func spinFlipsAngularMomentum() {
        func angularMomentum(_ spin: Spin) -> Float {
            let config = GalaxyConfig(
                name: "spin",
                particleCount: 2_000,
                potential: GalaxyPotential(profile: .hernquist, mass: 50, scaleRadius: 5),
                diskScaleLength: 4,
                velocityDispersion: 0,
                spin: spin
            )
            var system = ParticleSystem()
            var generator = SeededGenerator(seed: 11)
            DiskSampler.sample(config, galaxyIndex: 0, into: &system, using: &generator)
            var total: Float = 0
            for i in 0..<system.count {
                total += simd_cross(system.positions[i], system.velocities[i]).z
            }
            return total
        }
        #expect(angularMomentum(.prograde) > 0)
        #expect(angularMomentum(.retrograde) < 0)
    }
}
