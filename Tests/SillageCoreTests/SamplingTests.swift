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
        #expect(system.galaxyIndex.allSatisfy { $0 == 0 })

        // Stars are placed in clumps of finite size, so a few near the edge spill past the
        // truncation radius. The profile is what has to hold, not a hard bound: the bulk
        // stays inside, and nothing lands far outside. Dust is drawn from a wider profile
        // because gas is far less centrally concentrated than starlight.
        let starRadii = (0..<system.count)
            .filter { system.component[$0] == ParticleComponent.star.rawValue }
            .map { system.birthRadius[$0] }
        let beyond = starRadii.filter { $0 > 16 }.count
        #expect(Double(beyond) / Double(starRadii.count) < 0.05)
        #expect(starRadii.allSatisfy { $0 <= 16 * 1.6 })
        #expect(system.birthRadius.allSatisfy { $0 <= 16 * 2.0 })
        #expect(system.component.contains(ParticleComponent.dust.rawValue))
        #expect(system.component.contains(ParticleComponent.hiiRegion.rawValue))
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

    /// Amplitude of the m-fold azimuthal Fourier mode, in the disk plane.
    private func armAmplitude(_ kind: GalaxyKind, arms: Int) -> Float {
        let config = GalaxyConfig(
            name: "arms",
            particleCount: 40_000,
            kind: kind,
            potential: GalaxyPotential(profile: .hernquist, mass: 50, scaleRadius: 5),
            diskScaleLength: 4,
            armCount: arms
        )
        var system = ParticleSystem()
        var generator = SeededGenerator(seed: 21)
        DiskSampler.sample(config, galaxyIndex: 0, into: &system, using: &generator)

        let wind = 1 / tan(config.armPitch)
        var real: Float = 0
        var imaginary: Float = 0
        for position in system.positions {
            let radius = sqrt(position.x * position.x + position.y * position.y)
            let phase =
                Float(arms)
                * (atan2(position.y, position.x)
                    - wind * log(max(radius, 1e-3) / config.diskScaleLength))
            real += cos(phase)
            imaginary += sin(phase)
        }
        return sqrt(real * real + imaginary * imaginary) / Float(system.count)
    }

    /// Clumping gives even a featureless disk some azimuthal structure by chance, so the
    /// test compares the two kinds rather than holding the disk to an absolute zero.
    @Test func spiralArmsModulateDensityMoreThanAPlainDisk() {
        let spiral = armAmplitude(.spiral, arms: 2)
        let disk = armAmplitude(.disk, arms: 2)
        #expect(spiral > 0.12)
        #expect(spiral > 2 * disk)
    }

    @Test func globularIsSphericalAndNotRotating() {
        let config = GalaxyConfig(
            name: "globular",
            particleCount: 30_000,
            kind: .globular,
            potential: GalaxyPotential(profile: .plummer, mass: 40, scaleRadius: 4),
            diskScaleLength: 4,
            diskTruncation: 5
        )
        var system = ParticleSystem()
        var generator = SeededGenerator(seed: 5)
        DiskSampler.sample(config, galaxyIndex: 0, into: &system, using: &generator)

        var extent = SIMD3<Float>.zero
        var angularMomentum = SIMD3<Float>.zero
        var speed: Float = 0
        for index in 0..<system.count {
            let p = system.positions[index]
            extent += SIMD3<Float>(abs(p.x), abs(p.y), abs(p.z))
            angularMomentum += simd_cross(p, system.velocities[index])
            speed += simd_length(system.velocities[index])
        }
        extent /= Float(system.count)
        // No axis is preferred, and the net spin is negligible next to the random motion.
        #expect(abs(extent.x - extent.z) / extent.x < 0.06)
        #expect(abs(extent.y - extent.z) / extent.y < 0.06)
        #expect(
            simd_length(angularMomentum) / Float(system.count) < 0.1 * speed / Float(system.count) * extent.x)
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
