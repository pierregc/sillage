import Foundation
import Testing

@testable import SillageCore

#if canImport(simd)
    import simd
#endif

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
    /// A bulge has to stay a bulge. Drawn from an untruncated Hernquist it did not: a tenth
    /// of it stood beyond eight scale radii, which at the extents a galaxy is given is more
    /// than a disk scale length, and the picture had old red stars scattered out among the
    /// arms with nothing around them to belong to.
    @Test func theBulgeStaysNearTheCentre() {
        let config = Self.spiral(bulge: 0.4)
        let system = Self.sampled(config)
        let scale = config.bulgeExtent * config.diskScaleLength
        var radii = [Float]()
        for i in 0..<system.count
        where system.component[i] == ParticleComponent.bulge.rawValue {
            radii.append(simd_length(system.positions[i]))
        }
        try? #require(!radii.isEmpty)
        radii.sort()
        #expect(radii[radii.count - 1] <= scale * DiskSampler.bulgeTruncation * 1.001)
        #expect(radii[Int(0.9 * Float(radii.count - 1))] < scale * 5)
        // And it is not merely small: the profile inside is the one it was cut from.
        #expect(radii[radii.count / 2] > scale)
        #expect(radii[radii.count / 2] < scale * 2.5)
    }

    /// No arm reaches inside the bulge, so no young arm stars either. Proximity there was
    /// the neutral 0.5 and a fifth of the core was drawn young, which made it blue-white
    /// face-on and hid the bulge.
    @Test func theCoreHasNoYoungDiskStars() {
        let config = Self.spiral(bulge: 0.15)
        let system = Self.sampled(config)
        let inner = 0.4 * config.bulgeExtent * config.diskScaleLength
        var young = 0
        var all = 0
        for i in 0..<system.count
        where system.component[i] == ParticleComponent.star.rawValue
            && system.birthRadius[i] < inner
        {
            all += 1
            if -system.formation[i] * Float(Physics.megayearsPerTimeUnit) < 1_000 { young += 1 }
        }
        try? #require(all > 100)
        #expect(Double(young) / Double(all) < 0.02)
    }

    /// The outskirts stand well off the plane, so edge-on they are most of what is seen
    /// there. At 1.7 % of the light they made a cloud of yellow points; a stellar halo holds
    /// well under one per cent.
    @Test func theOutskirtsCarryLittleLight() {
        let system = Self.sampled(Self.spiral(bulge: 0.15))
        var outskirts = 0.0
        var total = 0.0
        for i in 0..<system.count {
            guard let kind = ParticleComponent(rawValue: system.component[i]), kind.emits
            else { continue }
            let age = -system.formation[i] * Float(Physics.megayearsPerTimeUnit)
            let light = Double(
                system.luminosity[i] * StellarPopulation.sampled(ageMyr: age).lightPerMass)
            total += light
            if kind == .outskirt { outskirts += light }
        }
        #expect(outskirts > 0)
        #expect(outskirts / total < 0.008)
    }

    @Test func theBulgeIsPressureSupportedNotRotating() throws {
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
        try #require(n > 0)
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

@Suite("Calm disk sampling")
struct CalmDiskSamplingTests {
    private func scene(_ change: (inout GalaxyConfig) -> Void = { _ in }) -> SceneConfig {
        var scene = SceneConfig.isolatedDisk(particleCount: 60_000)
        scene.solver = .barnesHut
        scene.galaxies[0].kind = .spiral
        scene.galaxies[0].armStrength = 0.95
        scene.galaxies[0].bulgeFraction = 0
        change(&scene.galaxies[0])
        return scene
    }

    /// |sum e^{2 i phi}| / N over the particles of one component between 1.5 and 3 scale
    /// lengths: half the sinusoid's contrast.
    private func amplitude2(_ system: ParticleSystem, _ component: ParticleComponent, scale: Float)
        -> Float
    {
        var re: Float = 0
        var im: Float = 0
        var count: Float = 0
        for index in 0..<system.count where system.component[index] == component.rawValue {
            let p = system.positions[index]
            let radius = (p.x * p.x + p.y * p.y).squareRoot()
            guard radius > 1.5 * scale, radius < 3 * scale else { continue }
            let phi = atan2(p.y, p.x)
            re += cos(2 * phi)
            im += sin(2 * phi)
            count += 1
        }
        return count > 0 ? (re * re + im * im).squareRoot() / count : 0
    }

    /// The old stars carry the wave a real old disk carries; the light keeps the painted
    /// contrast through the young population.
    @Test func theOldStarsCarryLessOfTheWaveThanTheYoung() {
        let scene = scene()
        let system = RestrictedSolver.sampleParticles(for: scene)
        let scale = scene.galaxies[0].diskScaleLength
        let old = amplitude2(system, .star, scale: scale)
        let young = amplitude2(system, .dust, scale: scale)
        #expect(old > 0.05 && old < 0.25)
        #expect(young > 2 * old)

        var strong = scene
        strong.galaxies[0].armMassContrast = 0.95
        let asPainted = amplitude2(RestrictedSolver.sampleParticles(for: strong), .star, scale: scale)
        #expect(asPainted > 1.8 * old)
    }

    /// Inside corotation the streaming is inward at the crest and absent without the knob.
    @Test func theStreamingIsInwardAtTheCrestInsideCorotation() {
        func inflowAtCrest(_ scene: SceneConfig) -> Float {
            let system = RestrictedSolver.sampleParticles(for: scene)
            let galaxy = scene.galaxies[0]
            let equilibrium = DiskEquilibrium(config: galaxy, selfGravitating: true)
            let resonances = equilibrium.resonances(of: equilibrium.patternSpeed())
            let shape = SpiralPattern.Shape(
                arms: galaxy.armCount, windRate: galaxy.armWindRate, irregularity: 0, index: 0)
            var inward: Float = 0
            var count: Float = 0
            let star = ParticleComponent.star.rawValue
            for index in 0..<system.count where system.component[index] == star {
                let p = system.positions[index]
                let radius = (p.x * p.x + p.y * p.y).squareRoot()
                guard radius > resonances.lindblad * 1.3, radius < resonances.corotation * 0.9 else {
                    continue
                }
                let phi = atan2(p.y, p.x)
                // On the clean ridge, where the crest of the wave is.
                let extent = radius / galaxy.diskScaleLength
                guard SpiralPattern.ridge(extent: extent, phi: phi, shape: shape) > 0.9 else { continue }
                let v = system.velocities[index]
                inward -= (v.x * p.x + v.y * p.y) / radius
                count += 1
            }
            return count > 0 ? inward / count : 0
        }
        let streaming = inflowAtCrest(scene { $0.armIrregularity = 0 })
        let still = inflowAtCrest(
            scene {
                $0.armIrregularity = 0
                $0.armStreaming = 0
            })
        #expect(streaming > 0.02)
        #expect(abs(still) < 0.01)
    }

    @Test func clumpsBelongToTheYoungPopulationByDefault() {
        let galaxy = GalaxyConfig(
            name: "d", particleCount: 10,
            potential: GalaxyPotential(profile: .hernquist, mass: 50, scaleRadius: 5), diskScaleLength: 4)
        #expect(galaxy.clumpiness < galaxy.youngClumpiness)
        #expect(galaxy.armMassContrast < galaxy.armStrength)
    }

    /// A galaxy written before the calm disk reads as it was written, so a scene explored
    /// before it gives the same particles at hires and an old take paints the same wave.
    @Test func anOlderGalaxyReadsAsItWasWritten() throws {
        var galaxy = GalaxyConfig(
            name: "old", particleCount: 10,
            potential: GalaxyPotential(profile: .hernquist, mass: 50, scaleRadius: 5), diskScaleLength: 4)
        galaxy.clumpiness = 0.2
        galaxy.armStrength = 0.8
        galaxy.armMassContrast = 0.25
        galaxy.armStreaming = 0.6
        galaxy.youngClumpiness = 0.45
        let encoded = try JSONEncoder().encode(galaxy)
        var json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let fields = [
            "armMassContrast", "armStreaming", "youngClumpiness", "massLopsidedness", "patternShare",
        ]
        for key in fields { json.removeValue(forKey: key) }
        let data = try JSONSerialization.data(withJSONObject: json)
        let read = try JSONDecoder().decode(GalaxyConfig.self, from: data)
        #expect(abs(read.youngClumpiness - 0.5) < 1e-6)
        #expect(read.armMassContrast == 0.8 && read.armStreaming == 0)
        #expect(read.massLopsidedness == 0.30 && read.patternShare == 0)
        let round = try JSONDecoder().decode(GalaxyConfig.self, from: encoded)
        #expect(round == galaxy)

        // The same through a scene file, and `--calm` moves it onto the calm disk.
        var scene = SceneConfig.isolatedDisk(particleCount: 1_000)
        scene.galaxies[0] = galaxy
        let fileData = try SceneFile(scene).encoded()
        var fileJSON = try #require(try JSONSerialization.jsonObject(with: fileData) as? [String: Any])
        var galaxies = try #require(fileJSON["galaxies"] as? [[String: Any]])
        for key in fields { galaxies[0].removeValue(forKey: key) }
        fileJSON["galaxies"] = galaxies
        var file = try SceneFile.decoded(from: JSONSerialization.data(withJSONObject: fileJSON))
        let old = file.scene(particleCount: 1_000).galaxies[0]
        #expect(old.armMassContrast == 0.8 && old.armStreaming == 0 && old.patternShare == 0)
        file.galaxies[0].adoptCalmDisk()
        let calm = file.scene(particleCount: 1_000).galaxies[0]
        #expect(calm.armStreaming == 1 && calm.patternShare > 0 && calm.armMassContrast < 0.8)
        #expect(calm.clumpiness == 0.2)
    }

    /// `--calm` moves a galaxy described before the calm disk onto it and leaves one already
    /// on it as it was drawn; the old young attachment clamps the clumpiness as the sampler did.
    @Test func calmLeavesACalmGalaxyAlone() {
        var drawn = GalaxyConfig(
            name: "drawn", particleCount: 10,
            potential: GalaxyPotential(profile: .hernquist, mass: 50, scaleRadius: 5), diskScaleLength: 4)
        drawn.armMassContrast = 0.42
        drawn.youngClumpiness = 0.58
        let before = drawn
        drawn.adoptCalmDisk()
        #expect(drawn == before)

        var old = before
        old.patternShare = 0
        old.armStreaming = 0
        old.adoptCalmDisk()
        #expect(old.patternShare > 0 && old.armStreaming == 1)
        #expect(GalaxyConfig.legacy(clumpiness: -0.2, armStrength: 0.8).youngClumpiness == 0.3)
        #expect(GalaxyConfig.legacy(clumpiness: 1.4, armStrength: 0.8).youngClumpiness == 0.97)
    }

    /// Given a share of the disk's mass, the gas weighs that while its dust particles stay as
    /// many, and the disk launched on the curve that mass makes (#218); without one a grain
    /// weighs what a star does, and a file written before reads without the field.
    @Test func theGasWeighsItsOwnShare() throws {
        func weighed(_ scene: SceneConfig) -> (gas: Double, disk: Double, grains: Int) {
            let system = RestrictedSolver.sampleParticles(for: scene)
            var gas = 0.0
            var disk = 0.0
            var grains = 0
            for index in 0..<system.count
            where system.component[index] < ParticleComponent.halo.rawValue
                || system.component[index] == ParticleComponent.outskirt.rawValue
            {
                disk += Double(system.mass[index])
                if system.component[index] == ParticleComponent.dust.rawValue {
                    gas += Double(system.mass[index])
                    grains += 1
                }
            }
            return (gas, disk, grains)
        }
        let drawn = scene()
        let before = weighed(drawn)
        #expect(abs(before.gas / before.disk - Double(drawn.galaxies[0].dustFraction)) < 0.01)
        let light = scene { $0.dustMassFraction = 0.12 }
        let after = weighed(light)
        #expect(after.grains == before.grains)
        #expect(abs(after.gas / after.disk - 0.12) < 0.01)
        #expect(abs(after.disk / before.disk - 1) < 0.005)
        let inner = drawn.galaxies[0].diskScaleLength
        let curve = { (galaxy: GalaxyConfig) in
            DiskEquilibrium(config: galaxy, selfGravitating: true).circularSpeed(atRadius: inner)
        }
        #expect(curve(light.galaxies[0]) > curve(drawn.galaxies[0]))
        var same = drawn.galaxies[0]
        same.dustMassFraction = same.dustFraction
        #expect(abs(curve(same) / curve(drawn.galaxies[0]) - 1) < 1e-5)

        let file = try SceneFile(light).encoded()
        #expect(
            try SceneFile.decoded(from: file).scene(particleCount: 1_000).galaxies[0].dustMassFraction == 0.12
        )
        #expect(!String(decoding: try SceneFile(drawn).encoded(), as: UTF8.self).contains("dustMassFraction"))
    }

    /// A galaxy read as it was written samples exactly as before the calm disk: the stars at
    /// the painted contrast, nothing added to their velocities.
    @Test func theOldModelSamplesTheStarsAtThePaintedContrast() {
        let calm = scene()
        var old = calm
        let legacy = GalaxyConfig.legacy(clumpiness: old.galaxies[0].clumpiness, armStrength: 0.95)
        old.galaxies[0].armMassContrast = legacy.armMassContrast
        old.galaxies[0].youngClumpiness = legacy.youngClumpiness
        old.galaxies[0].massLopsidedness = legacy.massLopsidedness
        old.galaxies[0].armStreaming = 0
        old.galaxies[0].patternShare = 0
        let scale = calm.galaxies[0].diskScaleLength
        let before = amplitude2(RestrictedSolver.sampleParticles(for: old), .star, scale: scale)
        let after = amplitude2(RestrictedSolver.sampleParticles(for: calm), .star, scale: scale)
        #expect(before > 1.8 * after)
    }
}

@Suite("Dust ring")
struct DustRingTests {
    private static let ring = GalaxyConfig.DustRing(radius: 10, width: 1)

    private func scene(_ change: (inout GalaxyConfig) -> Void = { _ in }) -> SceneConfig {
        var scene = SceneConfig.isolatedDisk(particleCount: 60_000)
        scene.galaxies[0].kind = .spiral
        change(&scene.galaxies[0])
        return scene
    }

    private func radii(_ system: ParticleSystem, _ component: ParticleComponent) -> [Double] {
        (0..<system.count).filter { system.component[$0] == component.rawValue }
            .map { Double(system.birthRadius[$0]) }
    }

    private func inBand(_ radii: [Double]) -> Double {
        let ring = Self.ring
        let near = radii.filter { abs($0 - Double(ring.radius)) < 3 * Double(ring.width) }
        return Double(near.count) / Double(max(radii.count, 1))
    }

    /// The dust stands at the ring's radius with the spread asked, as thin a layer as before,
    /// not faded by the disk's edge, and the stars stay where they were.
    @Test func theRingGathersTheDust() {
        let plain = RestrictedSolver.sampleParticles(for: scene())
        let ringed = RestrictedSolver.sampleParticles(for: scene { $0.dustRing = Self.ring })
        let dust = radii(ringed, .dust)
        let mean = dust.reduce(0, +) / Double(dust.count)
        let spread = (dust.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(dust.count)).squareRoot()
        #expect(abs(mean - 10) < 0.1)
        #expect(abs(spread - 1) < 0.1)
        #expect(inBand(dust) > 0.99)
        #expect(inBand(radii(plain, .dust)) < 0.5)
        #expect(abs(Double(dust.count) / Double(radii(plain, .dust).count) - 1) < 0.03)

        let stars = radii(ringed, .star)
        let before = radii(plain, .star)
        let starMean: Double = stars.reduce(0, +) / Double(stars.count)
        let beforeMean: Double = before.reduce(0, +) / Double(before.count)
        #expect(abs(starMean / beforeMean - 1) < 0.02)

        func dustOf(_ system: ParticleSystem) -> (height: Double, opacity: Double) {
            let grains = (0..<system.count).filter { system.component[$0] == ParticleComponent.dust.rawValue }
            let height =
                grains.reduce(0.0) { $0 + Double(abs(system.positions[$1].z)) } / Double(grains.count)
            let opacity = grains.reduce(0.0) { $0 + Double(system.luminosity[$1]) } / Double(grains.count)
            return (height, opacity)
        }
        #expect(abs(dustOf(ringed).height / dustOf(plain).height - 1) < 0.1)
        #expect(dustOf(ringed).opacity > dustOf(plain).opacity)
    }

    /// A share of the dust in the ring leaves the rest where it is drawn without one.
    @Test func theShareSplitsTheDust() {
        let plain = inBand(radii(RestrictedSolver.sampleParticles(for: scene()), .dust))
        let half = scene { $0.dustRing = GalaxyConfig.DustRing(radius: 10, width: 1, share: 0.5) }
        let found = inBand(radii(RestrictedSolver.sampleParticles(for: half), .dust))
        #expect(abs(found - (0.5 + 0.5 * plain)) < 0.03)
    }

    /// A ring that cannot be drawn is no ring: the sample is the one without the field.
    @Test func aRingOfNothingChangesNothing() {
        let plain = RestrictedSolver.sampleParticles(for: scene())
        for ring in [
            GalaxyConfig.DustRing(radius: 10, width: 1, share: 0),
            GalaxyConfig.DustRing(radius: 10, width: 0), GalaxyConfig.DustRing(radius: 0, width: 1),
        ] {
            let same = RestrictedSolver.sampleParticles(for: scene { $0.dustRing = ring })
            #expect(same.positions == plain.positions)
            #expect(same.velocities == plain.velocities)
            #expect(same.luminosity == plain.luminosity)
        }
    }

    /// The scene file keeps the ring, reads a ring without a share as the whole dust, and a
    /// scene without one is written without the field.
    @Test func theSceneFileKeepsTheRing() throws {
        let ringed = scene { $0.dustRing = GalaxyConfig.DustRing(radius: 9, width: 1.2, share: 0.8) }
        let file = try SceneFile(ringed).encoded()
        let read = try SceneFile.decoded(from: file).scene(particleCount: 1_000).galaxies[0].dustRing
        #expect(read == GalaxyConfig.DustRing(radius: 9, width: 1.2, share: 0.8))
        #expect(!String(decoding: try SceneFile(scene()).encoded(), as: UTF8.self).contains("dustRing"))
        let bare = try JSONDecoder().decode(
            GalaxyConfig.DustRing.self, from: Data(#"{"radius": 9, "width": 1.2}"#.utf8))
        #expect(bare.share == 1)
    }

    /// The rotation curve counts the ring's gas where it stands: against the pull of the
    /// sampled grains themselves, weaker inside the ring than without it, stronger outside.
    @Test func theCurveCountsTheRingWhereItStands() {
        let heavy = scene {
            $0.dustMassFraction = 0.3
            $0.dustRing = Self.ring
        }
        let galaxy = heavy.galaxies[0]
        let system = RestrictedSolver.sampleParticles(for: heavy)
        let grains = (0..<system.count).filter { system.component[$0] == ParticleComponent.dust.rawValue }
        let mass = grains.reduce(Float(0)) { $0 + system.mass[$1] }
        func summed(_ radius: Float) -> Double {
            var total = 0.0
            for step in 0..<8 {
                let angle = Float(step) * .pi / 4
                let at = SIMD3<Float>(radius * cos(angle), radius * sin(angle), 0)
                for index in grains {
                    let d = at - system.positions[index]
                    let r2 = Double(simd_length_squared(d)) + 0.04
                    total +=
                        Double(system.mass[index]) * Double(simd_dot(d, at) / radius) / (r2 * r2.squareRoot())
                }
            }
            return total / 8 * Double(radius)
        }
        for (radius, tolerance) in [(Float(6), 0.2), (13.5, 0.2), (20, 0.05)] {
            let curve = Double(DiskEquilibrium.ringSpeedSquared(mass: mass, ring: Self.ring, radius: radius))
            #expect(abs(curve / summed(radius) - 1) < tolerance)
        }
        #expect(DiskEquilibrium.ringSpeedSquared(mass: mass, ring: Self.ring, radius: 6) < 0)

        var spread = galaxy
        spread.dustRing = nil
        let curve = { (galaxy: GalaxyConfig, radius: Float) in
            DiskEquilibrium(config: galaxy, selfGravitating: true).circularSpeed(atRadius: radius)
        }
        #expect(curve(galaxy, 14) > curve(spread, 14))
        #expect(curve(galaxy, 6) < curve(spread, 6))
        #expect(abs(curve(galaxy, 60) / curve(spread, 60) - 1) < 0.01)
    }

    /// A companion resized by its encounter's mass ratio has its ring resized with it.
    @Test func theRingFollowsTheMassRatio() throws {
        var scene = SceneConfig.merger()
        scene.galaxies[1].dustRing = Self.ring
        let length = scene.galaxies[1].diskScaleLength
        scene.encounters = [Encounter(pericentre: 8, eccentricity: 1, massRatio: 0.25, pericentreTime: 100)]
        try scene.placeEncounters()
        let stretch = scene.galaxies[1].diskScaleLength / length
        #expect(abs(stretch - 1) > 0.05)
        #expect(abs((scene.galaxies[1].dustRing?.radius ?? 0) - 10 * stretch) < 1e-4)
        #expect(abs((scene.galaxies[1].dustRing?.width ?? 0) - stretch) < 1e-4)
    }

    /// With an inner width the dust thickens to the rim: a long slope inside the radius, a short
    /// one outside, the share on each side that of its width, and the file keeps the field.
    @Test func theRingThickensToItsRim() throws {
        let rim = GalaxyConfig.DustRing(radius: 10, width: 0.5, innerWidth: 3)
        let sloped = scene { $0.dustRing = rim }
        let dust = radii(RestrictedSolver.sampleParticles(for: sloped), .dust)
        let outside = dust.filter { $0 > 10 }
        let inside = dust.filter { $0 <= 10 }
        let share = Double(outside.count) / Double(dust.count)
        #expect(abs(share - 0.5 / 3.5) < 0.04)
        func rms(_ radii: [Double]) -> Double {
            (radii.reduce(0) { $0 + ($1 - 10) * ($1 - 10) } / Double(radii.count)).squareRoot()
        }
        #expect(abs(rms(outside) - 0.5) < 0.06)
        #expect(abs(rms(inside) - 3) < 0.3)
        let fifth = { (from: Double) in Double(dust.filter { $0 > from && $0 <= from + 1 }.count) }
        #expect(fifth(9) > 1.5 * fifth(6))
        #expect(fifth(6) > 1.5 * fifth(3))

        let read = try SceneFile.decoded(from: SceneFile(sloped).encoded())
            .scene(particleCount: 1_000).galaxies[0].dustRing
        #expect(read == rim)
        let even = scene { $0.dustRing = GalaxyConfig.DustRing(radius: 10, width: 1, innerWidth: 1) }
        let plain = scene { $0.dustRing = Self.ring }
        #expect(
            RestrictedSolver.sampleParticles(for: even).positions
                == RestrictedSolver.sampleParticles(for: plain).positions)
    }

    /// Asked, the star-forming regions stand on the ring with the dust; not asked, where they were.
    @Test func theRingBearsItsYoungStars() throws {
        let plain = radii(
            RestrictedSolver.sampleParticles(for: scene { $0.dustRing = Self.ring }), .hiiRegion)
        let born = scene { $0.dustRing = GalaxyConfig.DustRing(radius: 10, width: 1, young: 1) }
        let young = radii(RestrictedSolver.sampleParticles(for: born), .hiiRegion)
        #expect(abs(Double(young.count) / Double(plain.count) - 1) < 0.1)
        #expect(inBand(young) > 0.99)
        #expect(inBand(plain) < 0.5)
        let read = try SceneFile.decoded(from: SceneFile(born).encoded())
            .scene(particleCount: 1_000).galaxies[0].dustRing
        #expect(read?.young == 1)
    }

    /// A ring's own thickness thins its layer and the vertical motion with it.
    @Test func theRingHasItsOwnLayer() {
        func layer(_ ring: GalaxyConfig.DustRing) -> (height: Double, speed: Double) {
            let system = RestrictedSolver.sampleParticles(for: scene { $0.dustRing = ring })
            let grains = (0..<system.count).filter { system.component[$0] == ParticleComponent.dust.rawValue }
            let height =
                grains.reduce(0.0) { $0 + Double(abs(system.positions[$1].z)) } / Double(grains.count)
            let speed =
                grains.reduce(0.0) { $0 + Double(abs(system.velocities[$1].z)) } / Double(grains.count)
            return (height, speed)
        }
        let usual = layer(Self.ring)
        let thickness = scene().galaxies[0].diskThickness
        let thin = layer(GalaxyConfig.DustRing(radius: 10, width: 1, thickness: thickness * 0.09))
        #expect(abs(thin.height / usual.height - 0.2) < 0.03)
        #expect(abs(thin.speed / usual.speed - 0.09) < 0.02)
    }

    /// Asked for threads, the ring's dust runs in a few long ones: in a narrow sector it stands at
    /// a handful of radii with room between them, the layer keeps its height, the ring its place,
    /// and the grains go round cold, without the stars' random motion in the plane.
    @Test func theRingIsDrawnInThreads() throws {
        let thickness = scene().galaxies[0].diskThickness * 0.2
        let strands = GalaxyConfig.DustRing(radius: 10, width: 1, thickness: thickness)
        var threads = strands
        threads.threads = 24
        func drawn(_ ring: GalaxyConfig.DustRing) -> (
            filled: Double, height: Double, mean: Double, outward: Double
        ) {
            let system = RestrictedSolver.sampleParticles(for: scene { $0.dustRing = ring })
            let grains = (0..<system.count).filter { system.component[$0] == ParticleComponent.dust.rawValue }
            var cells = Set<Int>()
            var squares = 0.0
            var radius = 0.0
            var outward = 0.0
            for index in grains {
                let at = system.positions[index]
                let r = Double((at.x * at.x + at.y * at.y).squareRoot())
                let sector = Int((Double(atan2(at.y, at.x)) + .pi) / (2 * .pi) * 90)
                cells.insert(sector * 1_000 + Int(r / 0.1))
                squares += Double(at.z * at.z)
                radius += r
                let speed = system.velocities[index]
                let out = Double(speed.x * at.x + speed.y * at.y) / r
                outward += out * out
            }
            return (
                Double(cells.count) / (90 * 60), (squares / Double(grains.count)).squareRoot(),
                radius / Double(grains.count), (outward / Double(grains.count)).squareRoot()
            )
        }
        let short = drawn(strands)
        let long = drawn(threads)
        #expect(long.filled < 0.5 * short.filled)
        #expect(abs(long.height / short.height - 1) < 0.35)
        #expect(abs(long.mean - 10) < 0.5)
        // One grain in fourteen stands between the threads and keeps the disk's motion.
        #expect(long.outward < 0.4 * short.outward)

        let read = try SceneFile.decoded(from: SceneFile(scene { $0.dustRing = threads }).encoded())
            .scene(particleCount: 1_000).galaxies[0].dustRing
        #expect(read?.threads == 24)
        var none = strands
        none.threads = 0
        #expect(
            RestrictedSolver.sampleParticles(for: scene { $0.dustRing = none }).positions
                == RestrictedSolver.sampleParticles(for: scene { $0.dustRing = strands }).positions)
    }

    /// Asked for a sheet, the ring's dust is one layer in clouds: cold, far fewer grains well
    /// inside the ring than its own profile puts there, uneven round the ring as `cotton` asks,
    /// and without the field nothing moves.
    @Test func theRingIsLaidAsASheet() throws {
        let plain = GalaxyConfig.DustRing(radius: 10, width: 1)
        func drawn(_ ring: GalaxyConfig.DustRing) -> (inside: Double, uneven: Double, outward: Double) {
            let system = RestrictedSolver.sampleParticles(for: scene { $0.dustRing = ring })
            let grains = (0..<system.count).filter { system.component[$0] == ParticleComponent.dust.rawValue }
            var inside = 0.0
            var outward = 0.0
            var cells = [Double](repeating: 0, count: 120)
            for index in grains {
                let at = system.positions[index]
                let r = Double((at.x * at.x + at.y * at.y).squareRoot())
                if r < 8 { inside += 1 }
                if r > 9, r < 10 { cells[Int((Double(atan2(at.y, at.x)) + .pi) / (2 * .pi) * 119.99)] += 1 }
                let speed = system.velocities[index]
                let out = Double(speed.x * at.x + speed.y * at.y) / r
                outward += out * out
            }
            let mean = cells.reduce(0, +) / 120
            let spread = (cells.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / 120).squareRoot()
            return (
                inside / Double(grains.count), spread / mean, (outward / Double(grains.count)).squareRoot()
            )
        }
        var sheet = plain
        sheet.sheet = 1
        sheet.cotton = 1
        var smooth = sheet
        smooth.cotton = 0
        let strands = drawn(plain)
        let clouds = drawn(sheet)
        let even = drawn(smooth)
        #expect(clouds.inside < 0.5 * strands.inside)
        #expect(clouds.uneven > 2 * even.uneven)
        #expect(clouds.outward < 0.2 * strands.outward)

        let read = try SceneFile.decoded(from: SceneFile(scene { $0.dustRing = sheet }).encoded())
            .scene(particleCount: 1_000).galaxies[0].dustRing
        #expect(read?.sheet == 1 && read?.cotton == 1)
        var none = plain
        none.sheet = 0
        #expect(
            RestrictedSolver.sampleParticles(for: scene { $0.dustRing = none }).positions
                == RestrictedSolver.sampleParticles(for: scene { $0.dustRing = plain }).positions)
    }

    /// A grain lifted a little off the plane swings through it at the rate the mass around it
    /// sets: the curve's figure against Poisson's equation on the density of the particles the
    /// sampler lays down about the plane there, whichever way the bulge is counted.
    @Test func aLiftedGrainSwingsAsTheMassAroundItAsks() {
        for apart in [false, true] {
            let drawn = scene {
                $0.bulgeFraction = 0.5
                $0.bulgeApart = apart
            }
            let galaxy = drawn.galaxies[0]
            let system = RestrictedSolver.sampleParticles(for: drawn)
            let equilibrium = DiskEquilibrium(config: galaxy)
            let radius = 2 * galaxy.diskScaleLength
            let slab = 0.1 * galaxy.diskThickness
            var mass = 0.0
            for index in 0..<system.count {
                let at = system.positions[index]
                let r = (at.x * at.x + at.y * at.y).squareRoot()
                if abs(r - radius) < 0.5, abs(at.z) < slab { mass += Double(system.mass[index]) }
            }
            let density = mass / (2 * Double.pi * Double(radius) * 2 * Double(slab))
            let ahead = Double(equilibrium.circularSpeed(atRadius: radius * 1.01))
            let behind = Double(equilibrium.circularSpeed(atRadius: radius * 0.99))
            let slope = (ahead * ahead - behind * behind) / (0.02 * Double(radius))
            let counted =
                (4 * Double.pi * Double(Physics.gravitationalConstant) * density - slope / Double(radius))
                .squareRoot()
            #expect(abs(Double(equilibrium.verticalFrequency(atRadius: radius)) / counted - 1) < 0.1)
        }
    }

    /// The curve counts a sloped ring's gas where it stands too.
    @Test func theCurveCountsTheSlope() {
        let rim = GalaxyConfig.DustRing(radius: 10, width: 0.5, innerWidth: 3)
        let heavy = scene {
            $0.dustMassFraction = 0.3
            $0.dustRing = rim
        }
        let system = RestrictedSolver.sampleParticles(for: heavy)
        let grains = (0..<system.count).filter { system.component[$0] == ParticleComponent.dust.rawValue }
        let mass = grains.reduce(Float(0)) { $0 + system.mass[$1] }
        func summed(_ radius: Float) -> Double {
            var total = 0.0
            for step in 0..<8 {
                let angle = Float(step) * .pi / 4
                let at = SIMD3<Float>(radius * cos(angle), radius * sin(angle), 0)
                for index in grains {
                    let d = at - system.positions[index]
                    let r2 = Double(simd_length_squared(d)) + 0.04
                    total +=
                        Double(system.mass[index]) * Double(simd_dot(d, at) / radius) / (r2 * r2.squareRoot())
                }
            }
            return total / 8 * Double(radius)
        }
        for (radius, tolerance) in [(Float(5), 0.25), (13.5, 0.2), (20, 0.05)] {
            let curve = Double(DiskEquilibrium.ringSpeedSquared(mass: mass, ring: rim, radius: radius))
            #expect(abs(curve / summed(radius) - 1) < tolerance)
        }
    }
}

@Suite("Bulge apart")
struct BulgeApartTests {
    private func scene(_ change: (inout GalaxyConfig) -> Void = { _ in }) -> SceneConfig {
        var scene = SceneConfig.isolatedDisk(particleCount: 40_000)
        scene.galaxies[0].kind = .spiral
        scene.galaxies[0].bulgeFraction = 0.75
        change(&scene.galaxies[0])
        return scene
    }

    /// Under a bulge of three quarters the disk's own surface density is a quarter of the stars',
    /// and so are its dispersion and, squared, its drift: launched near its circular speed.
    @Test func theDiskIsLaunchedOnItsOwnDensity() {
        let whole = DiskEquilibrium(
            config: scene { $0.bulgeFlattening = 1 }.galaxies[0], selfGravitating: true)
        let round = scene {
            $0.bulgeFlattening = 1
            $0.bulgeApart = true
        }
        let apart = DiskEquilibrium(config: round.galaxies[0], selfGravitating: true)
        let radius = 3 * scene().galaxies[0].diskScaleLength
        #expect(
            abs(apart.surfaceDensity(atRadius: radius) / whole.surfaceDensity(atRadius: radius) - 0.25) < 1e-4
        )
        #expect(
            abs(apart.radialDispersion(atRadius: radius) / whole.radialDispersion(atRadius: radius) - 0.25)
                < 1e-3)
        #expect(abs(apart.circularSpeed(atRadius: radius) / whole.circularSpeed(atRadius: radius) - 1) < 1e-4)
        let lag = { (equilibrium: DiskEquilibrium) in
            1 - equilibrium.streamingSpeed(atRadius: radius) / equilibrium.circularSpeed(atRadius: radius)
        }
        #expect(lag(apart) < lag(whole) / 8)
    }

    /// Apart, the bulge pulls in the plane as the flattened body the sampler draws: as a sphere
    /// when round, harder when squeezed, against the pull of its own sampled stars.
    @Test func theBulgePullsAsItIsFlattened() {
        let round = DiskEquilibrium.flattenedBulgeSpeedSquared(mass: 10, scale: 2, flattening: 1, radius: 5)
        let held = Float(12.0 / 14.0) * Float(12.0 / 14.0)
        let sphere = Physics.gravitationalConstant * 10 * (5.0 / 7.0) * (5.0 / 7.0) / held / 5
        #expect(abs(round / sphere - 1) < 0.002)
        let squeezed = DiskEquilibrium.flattenedBulgeSpeedSquared(
            mass: 10, scale: 2, flattening: 0.7, radius: 5)
        #expect(squeezed / sphere > 1.07 && squeezed / sphere < 1.14)

        let galaxy = scene {
            $0.bulgeApart = true
            $0.bulgeFlattening = 0.7
            $0.bulgeExtent = 1
        }.galaxies[0]
        let system = RestrictedSolver.sampleParticles(
            for: scene {
                $0.bulgeApart = true
                $0.bulgeFlattening = 0.7
                $0.bulgeExtent = 1
            })
        let stars = (0..<system.count).filter { system.component[$0] == ParticleComponent.bulge.rawValue }
        let mass = stars.reduce(Float(0)) { $0 + system.mass[$1] }
        let a = galaxy.bulgeExtent * galaxy.diskScaleLength
        for radius in [a, 2.5 * a] {
            var total = 0.0
            for step in 0..<8 {
                let angle = Float(step) * .pi / 4
                let at = SIMD3<Float>(radius * cos(angle), radius * sin(angle), 0)
                for index in stars {
                    let d = at - system.positions[index]
                    let r2 = Double(simd_length_squared(d)) + 0.01
                    total +=
                        Double(system.mass[index]) * Double(simd_dot(d, at) / radius) / (r2 * r2.squareRoot())
                }
            }
            let summed = total / 8 * Double(radius) * Double(Physics.gravitationalConstant)
            let curve = Double(
                DiskEquilibrium.flattenedBulgeSpeedSquared(
                    mass: mass, scale: a, flattening: 0.7, radius: radius))
            #expect(abs(curve / summed - 1) < 0.04)
        }
    }

    /// A reach moves the bulge's cut out and fades it there: some of it stands beyond six scale
    /// radii, almost none in the last tenth, the curve follows, and the scene file keeps the field.
    @Test func theBulgeReachesAsFarAsAsked() throws {
        let far = scene {
            $0.bulgeApart = true
            $0.bulgeReach = 12
        }
        let near = scene { $0.bulgeApart = true }
        let a = Double(far.galaxies[0].bulgeExtent * far.galaxies[0].diskScaleLength)
        func bulge(_ scene: SceneConfig) -> [Double] {
            let system = RestrictedSolver.sampleParticles(for: scene)
            return (0..<system.count).filter { system.component[$0] == ParticleComponent.bulge.rawValue }
                .map { Double(system.birthRadius[$0]) }
        }
        let radii = bulge(far)
        #expect((radii.max() ?? 0) <= 12 * a * 1.001)
        let beyond = Double(radii.filter { $0 > 6 * a }.count) / Double(radii.count)
        #expect(beyond > 0.03 && beyond < 0.137)
        #expect(Double(radii.filter { $0 > 10.8 * a }.count) / Double(radii.count) < 0.002)
        let outside = DiskEquilibrium.flattenedBulgeSpeedSquared(
            mass: 10, scale: 2, flattening: 1, radius: 26, cut: 12, fade: 0.4)
        #expect(abs(outside / (Physics.gravitationalConstant * 10 / 26) - 1) < 0.01)
        #expect((bulge(near).max() ?? 0) <= 6 * a * 1.001)
        let inner = Float(3 * a)
        let curve = { (scene: SceneConfig) in
            DiskEquilibrium(config: scene.galaxies[0]).circularSpeed(atRadius: inner)
        }
        #expect(curve(far) < curve(near))
        let file = try SceneFile(far).encoded()
        #expect(try SceneFile.decoded(from: file).scene(particleCount: 1_000).galaxies[0].bulgeReach == 12)
        #expect(!String(decoding: try SceneFile(near).encoded(), as: UTF8.self).contains("bulgeReach"))
    }

    /// With none of its recent star formation kept a disk has no star under a gigayear old,
    /// drawn where it was and moving as it did, and the scene file keeps the field.
    @Test func anOldDiskHasNoYoungStars() throws {
        let quiet = scene { $0.recentStars = 0 }
        func youngest(_ system: ParticleSystem) -> Double {
            (0..<system.count).filter { system.component[$0] == ParticleComponent.star.rawValue }
                .map { -Double(system.formation[$0]) * Physics.megayearsPerTimeUnit }.min() ?? 0
        }
        let usual = RestrictedSolver.sampleParticles(for: scene())
        let old = RestrictedSolver.sampleParticles(for: quiet)
        #expect(youngest(usual) < 100)
        #expect(youngest(old) >= Double(StarFormation.quietYoungestMyr) * 0.999)
        #expect(old.positions == usual.positions)
        #expect(old.velocities == usual.velocities)
        let file = try SceneFile(quiet).encoded()
        #expect(try SceneFile.decoded(from: file).scene(particleCount: 1_000).galaxies[0].recentStars == 0)
        #expect(!String(decoding: try SceneFile(scene()).encoded(), as: UTF8.self).contains("recentStars"))
    }

    /// A nucleus gathers its share of the bulge's stars within a few hundredths of the scale
    /// radius, where the cusp alone holds almost none, as compact stars slower than the bulge's,
    /// and the scene file keeps the field.
    @Test func theNucleusIsAPoint() throws {
        let pointed = scene { $0.nucleus = 0.01 }
        let a = Double(pointed.galaxies[0].bulgeExtent * pointed.galaxies[0].diskScaleLength)
        func inside(_ scene: SceneConfig) -> (share: Double, compact: Double, speed: Double) {
            let system = RestrictedSolver.sampleParticles(for: scene)
            let old = [ParticleComponent.bulge.rawValue, ParticleComponent.star.rawValue]
            let bulge = (0..<system.count).filter { system.component[$0] == ParticleComponent.bulge.rawValue }
            let core = (0..<system.count).filter {
                let at = system.positions[$0]
                return old.contains(system.component[$0])
                    && Double((at.x * at.x + at.y * at.y + at.z * at.z).squareRoot()) < 0.06 * a
            }
            let compact = core.filter {
                system.component[$0] == ParticleComponent.star.rawValue && system.kernelScale[$0] == 0.75
            }
            let speeds = core.map { index -> Double in
                let speed = system.velocities[index]
                return Double(speed.x * speed.x + speed.y * speed.y + speed.z * speed.z)
            }
            return (
                Double(core.count) / Double(bulge.count), Double(compact.count) / Double(max(core.count, 1)),
                (speeds.reduce(0, +) / Double(max(core.count, 1))).squareRoot()
            )
        }
        let plain = inside(scene())
        let nucleus = inside(pointed)
        #expect(plain.share < 0.006)
        #expect(abs(nucleus.share - plain.share - 0.01) < 0.003)
        #expect(nucleus.compact > 0.6)
        #expect(nucleus.speed < 0.7 * plain.speed)
        let file = try SceneFile(pointed).encoded()
        #expect(try SceneFile.decoded(from: file).scene(particleCount: 1_000).galaxies[0].nucleus == 0.01)
        #expect(!String(decoding: try SceneFile(scene()).encoded(), as: UTF8.self).contains("nucleus"))
    }

    /// Absent or false the sample is the one it always was, and the scene file keeps the field.
    @Test func withoutItNothingChanges() throws {
        let plain = RestrictedSolver.sampleParticles(for: scene())
        let off = RestrictedSolver.sampleParticles(for: scene { $0.bulgeApart = false })
        #expect(off.positions == plain.positions)
        #expect(off.velocities == plain.velocities)
        let on = RestrictedSolver.sampleParticles(for: scene { $0.bulgeApart = true })
        #expect(on.velocities != plain.velocities)
        let file = try SceneFile(scene { $0.bulgeApart = true }).encoded()
        #expect(try SceneFile.decoded(from: file).scene(particleCount: 1_000).galaxies[0].bulgeApart == true)
        #expect(!String(decoding: try SceneFile(scene()).encoded(), as: UTF8.self).contains("bulgeApart"))
    }
}
