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
        // The thin disk stops; the galaxy does not. The thick disk and inner halo are sampled
        // from a longer exponential and past the truncation on purpose — a disk that ends at a
        // radius you can name has a rim, and no galaxy has one. They still have to be a small
        // part of it and they still have to end somewhere.
        let outskirts = (0..<system.count)
            .filter { system.component[$0] == ParticleComponent.outskirt.rawValue }
            .map { system.birthRadius[$0] }
        #expect(!outskirts.isEmpty)
        #expect(Double(outskirts.count) / Double(starRadii.count) < 0.3)
        #expect(outskirts.allSatisfy { $0 <= 16 * 5 })
        #expect(system.birthRadius.allSatisfy { $0 <= 16 * 5 })
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

        let wind = config.armWindRate
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

    /// Trailing arms, whichever way the disk turns: follow one ridge outward and it has to
    /// fall behind the rotation. Leading arms are what a fixed winding sign produces, and
    /// they are what no spiral galaxy shows.
    @Test func armsTrailTheRotationForEitherSpin() {
        for spin in [Spin.prograde, Spin.retrograde] {
            var config = GalaxyConfig(
                name: "arms",
                particleCount: 100,
                potential: GalaxyPotential(profile: .hernquist, mass: 50, scaleRadius: 5),
                diskScaleLength: 4,
                spin: spin
            )
            config.armPitch = 0.46

            // A ridge satisfies phi = phase + windRate * log(radius / scale), so this is how
            // far the arm has swung between two and four scale lengths.
            let swing = config.armWindRate * (log(4 as Float) - log(2 as Float))
            // Positive spin turns towards increasing phi, so trailing means the outer end
            // sits at the angle the disk has already left behind.
            #expect(swing * config.spin.sign < 0)
        }
    }

    private static func spiral(bulge: Float) -> GalaxyConfig {
        var config = GalaxyConfig(
            name: "bulge",
            particleCount: 60_000,
            potential: GalaxyPotential(profile: .hernquist, mass: 50, scaleRadius: 5),
            diskScaleLength: 4
        )
        config.bulgeFraction = bulge
        config.haloParticleRatio = 0
        return config
    }

    private static func sampled(_ config: GalaxyConfig, seed: UInt64 = 7) -> ParticleSystem {
        var system = ParticleSystem()
        var generator = SeededGenerator(seed: seed)
        DiskSampler.sample(config, galaxyIndex: 0, into: &system, using: &generator)
        return system
    }

    /// A bulge is a spheroid, not the inner part of the disk. Without one the centre is as
    /// flat as everything around it, which is what this used to measure.
    @Test func theBulgeIsRounderThanTheDisk() {
        // Measured over a couple of bulge scale radii. Any window near the disk's own scale
        // height makes a plain disk look round too, which says nothing.
        func shape(bulge: Float) -> (axisRatio: Double, aboveThePlane: Double) {
            let config = Self.spiral(bulge: bulge)
            let system = Self.sampled(config)
            let limit = 2 * config.bulgeExtent * config.diskScaleLength
            var radial = 0.0
            var vertical = 0.0
            var high = 0
            var n = 0
            for p in system.positions {
                let r = (p.x * p.x + p.y * p.y).squareRoot()
                if r < limit {
                    radial += Double(r * r)
                    vertical += Double(p.z * p.z)
                    if abs(p.z) > 1 { high += 1 }
                    n += 1
                }
            }
            guard n > 0 else { return (0, 0) }
            return (
                (vertical / Double(n)).squareRoot() / (radial / Double(n)).squareRoot(),
                Double(high) / Double(n)
            )
        }
        let flat = shape(bulge: 0)
        let round = shape(bulge: 0.4)
        #expect(flat.axisRatio < 0.35)
        #expect(round.axisRatio > 0.6)
        // A sech^2 disk 0.3 kpc thick cannot put stars a kiloparsec off the plane; a bulge can.
        #expect(flat.aboveThePlane < 0.01)
        #expect(round.aboveThePlane > 0.04)
    }

    /// The signature of a bulge on an image: light above what the disk alone would put there.
    @Test func theBulgeRaisesTheCentreAboveTheExponential() {
        func centralExcess(bulge: Float) -> Double {
            let config = Self.spiral(bulge: bulge)
            let system = Self.sampled(config)
            let scale = Double(config.diskScaleLength)
            func surfaceDensity(inner: Double, outer: Double) -> Double {
                var n = 0
                for p in system.positions {
                    let r = Double((p.x * p.x + p.y * p.y).squareRoot())
                    if r >= inner, r < outer { n += 1 }
                }
                return Double(n) / (.pi * (outer * outer - inner * inner))
            }
            // Measured against the exponential the outer disk defines, so the ratio is one
            // for a disk with no bulge whatever its normalisation.
            let core = surfaceDensity(inner: 0, outer: 0.5) / exp(-0.25 / scale)
            let disk = surfaceDensity(inner: 3, outer: 5) / exp(-4 / scale)
            return core / disk
        }
        #expect(centralExcess(bulge: 0) < 1.6)
        #expect(centralExcess(bulge: 0.15) > 4)
    }

    /// Held up by random motion rather than by rotation, which is what separates a bulge from
    /// the disk it sits in.
    @Test func theBulgeIsPressureSupportedNotRotating() {
        let config = Self.spiral(bulge: 0.4)
        let system = Self.sampled(config)
        let limit = 2 * config.bulgeExtent * config.diskScaleLength
        var rotation = 0.0
        var dispersion = 0.0
        var n = 0
        for i in 0..<system.count {
            let p = system.positions[i]
            let v = system.velocities[i]
            let r = (p.x * p.x + p.y * p.y).squareRoot()
            guard r < limit, r > 1e-3 else { continue }
            let along = SIMD3<Float>(-p.y / r, p.x / r, 0)
            rotation += Double(simd_dot(v, along))
            dispersion += Double(simd_length_squared(v))
            n += 1
        }
        guard n > 0 else { return }
        let mean = abs(rotation / Double(n))
        let sigma = (dispersion / Double(n)).squareRoot()
        #expect(sigma > 0)
        #expect(mean / sigma < 0.5)
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
