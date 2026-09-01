import simd

/// Places a galaxy's visible particles. The potential is analytic and spherical in every
/// case, so this only decides where the tracers sit and how fast they move.
public enum DiskSampler {
    /// Inverts the cumulative mass of an exponential disk, M(<x) proportional to
    /// 1 - (1 + x) exp(-x), by Newton iteration. `x` is radius in scale lengths.
    static func inverseExponentialCDF(_ u: Float, truncation: Float) -> Float {
        let target = u * (1 - (1 + truncation) * exp(-truncation))
        var x: Float = 1.7
        for _ in 0..<24 {
            let e = exp(-x)
            let f = 1 - (1 + x) * e - target
            let df = x * e
            if df < 1e-12 { break }
            let next = x - f / df
            x = min(max(next, 0), truncation)
        }
        return x
    }

    /// Inverts the sech^2 vertical profile.
    static func inverseSech2CDF(_ u: Float) -> Float {
        let clamped = min(max(u, 1e-6), 1 - 1e-6)
        return atanh(2 * clamped - 1)
    }

    /// Radius enclosing a fraction `u` of a Plummer sphere.
    static func inversePlummerRadius(_ u: Float, scale: Float) -> Float {
        let clamped = min(max(u, 0), 0.999_9)
        let t = pow(clamped, 2.0 / 3.0)
        return scale * sqrt(t / max(1 - t, 1e-6))
    }

    /// Radius enclosing a fraction `u` of a Hernquist sphere.
    static func inverseHernquistRadius(_ u: Float, scale: Float) -> Float {
        let root = sqrt(min(max(u, 0), 0.999_9))
        return scale * root / max(1 - root, 1e-6)
    }

    /// Fraction of the mass inside `radius`, used to truncate the spheroid samplers.
    static func enclosedFraction(_ potential: GalaxyPotential, radius: Float) -> Float {
        let a = potential.scaleRadius
        switch potential.profile {
        case .plummer:
            let r2 = radius * radius
            return r2 * radius / pow(r2 + a * a, 1.5)
        case .hernquist:
            let s = radius + a
            return radius * radius / (s * s)
        }
    }

    /// Tracer density, up to a constant. Only ratios are used.
    static func density(_ potential: GalaxyPotential, radius: Float) -> Float {
        let a = potential.scaleRadius
        switch potential.profile {
        case .plummer:
            return pow(radius * radius + a * a, -2.5)
        case .hernquist:
            let r = max(radius, 1e-4)
            let s = r + a
            return 1 / (r * s * s * s)
        }
    }

    /// Dispersion of an untruncated isotropic tracer population in its own potential.
    /// Exact for Plummer; the Hernquist form loses precision very close to the centre, so it
    /// falls back to its asymptotic expansion there.
    static func untruncatedDispersionSquared(
        _ potential: GalaxyPotential, radius: Float
    ) -> Float {
        let a = potential.scaleRadius
        let gm = Physics.gravitationalConstant * potential.mass
        switch potential.profile {
        case .plummer:
            return gm / (6 * sqrt(radius * radius + a * a))
        case .hernquist:
            let x = radius / a
            if x < 0.02 { return gm / (12 * a) * (-2 * log(max(x, 1e-6)) - 25.0 / 6.0) }
            let s = 1 + x
            let term =
                12 * x * s * s * s * log(s / x)
                - x / s * (25 + 52 * x + 42 * x * x + 12 * x * x * x)
            return max(gm / (12 * a) * term, 0)
        }
    }

    /// Dispersion once the population is cut off at `edge`. Solving the Jeans equation over
    /// a finite range removes the pressure that supported the discarded envelope, so the
    /// untruncated value is too high and the sphere would expand.
    static func velocityDispersion(
        _ potential: GalaxyPotential, radius: Float, edge: Float
    ) -> Float {
        let inner = untruncatedDispersionSquared(potential, radius: radius)
        let outer = untruncatedDispersionSquared(potential, radius: edge)
        let ratio = density(potential, radius: edge) / max(density(potential, radius: radius), 1e-30)
        return sqrt(max(inner - outer * ratio, 0))
    }

    public static func randomDirection(_ generator: inout SeededGenerator) -> SIMD3<Float> {
        let cosTheta = generator.uniform(in: -1...1)
        let sinTheta = sqrt(max(1 - cosTheta * cosTheta, 0))
        let phi = generator.uniform() * 2 * .pi
        return SIMD3<Float>(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta)
    }

    /// Speed of one particle in a pressure-supported sphere.
    ///
    /// Plummer has a known isotropic distribution function, f(E) proportional to (-E) to the
    /// 7/2, and von Neumann rejection on q = v / v_escape samples it exactly. Matching only
    /// the second moment with a Gaussian gives the right pressure but the wrong shape, and
    /// the cluster then relaxes by several percent in its first orbit.
    ///
    /// Hernquist has no comparably short closed form, so it keeps the Jeans dispersion with
    /// a Gaussian and accepts that small initial adjustment.
    static func speedSample(
        _ potential: GalaxyPotential,
        radius: Float,
        edge: Float,
        using generator: inout SeededGenerator
    ) -> Float {
        switch potential.profile {
        case .plummer:
            var q: Float = 0
            for _ in 0..<64 {
                q = generator.uniform()
                let g = q * q * pow(max(1 - q * q, 0), 3.5)
                if generator.uniform() * 0.1 <= g { break }
            }
            return q * potential.escapeSpeed(atRadius: radius)
        case .hernquist:
            let sigma = velocityDispersion(potential, radius: radius, edge: edge)
            let escape = potential.escapeSpeed(atRadius: radius)
            var speed: Float = 0
            for _ in 0..<32 {
                let draw = SIMD3<Float>(
                    generator.normal(), generator.normal(), generator.normal())
                speed = simd_length(draw) * sigma
                if speed < escape { break }
            }
            return speed
        }
    }

    /// `selfGravitating` switches the velocity structure from near-circular tracer orbits to
    /// a Toomre-stable disk and gives every particle a mass.
    public static func sample(
        _ config: GalaxyConfig,
        galaxyIndex: UInt32,
        selfGravitating: Bool = false,
        into system: inout ParticleSystem,
        using generator: inout SeededGenerator
    ) {
        switch config.kind {
        case .spiral, .disk:
            // The bulge takes its stars out of the disk's share rather than adding to it, so
            // the galaxy keeps the particle count and the stellar mass it was asked for.
            let bulge = config.bulgeParticleCount
            sampleDisk(
                config, galaxyIndex: galaxyIndex, count: config.particleCount - bulge,
                selfGravitating: selfGravitating, into: &system, using: &generator)
            sampleBulge(
                config, galaxyIndex: galaxyIndex, count: bulge,
                selfGravitating: selfGravitating, into: &system, using: &generator)
        case .globular:
            sampleSpheroid(
                config, galaxyIndex: galaxyIndex, selfGravitating: selfGravitating,
                into: &system, using: &generator)
        }
        if selfGravitating {
            sampleHalo(config, galaxyIndex: galaxyIndex, into: &system, using: &generator)
        }
    }

    /// The stellar bulge: a flattened Hernquist spheroid held up by its own random motions.
    ///
    /// This is a component, not a label. Before it existed the centre of a galaxy was the
    /// inner part of the exponential disk with its stars merely marked as old, so the light
    /// profile had no central excess and the "bulge" was as flat as the disk it sat in.
    private static func sampleBulge(
        _ config: GalaxyConfig,
        galaxyIndex: UInt32,
        count: Int,
        selfGravitating: Bool,
        into system: inout ParticleSystem,
        using generator: inout SeededGenerator
    ) {
        guard count > 0 else { return }
        let scale = max(config.bulgeExtent * config.diskScaleLength, 1e-3)
        let edge = scale * 20
        let shape = GalaxyPotential(profile: .hernquist, mass: 1, scaleRadius: scale)
        let limit = min(enclosedFraction(shape, radius: edge), 0.999)
        let flattening = min(max(config.bulgeFlattening, 0.05), 1)
        let rotation = config.orientation
        let particleMass =
            selfGravitating
            ? config.potential.mass * config.diskMassFraction / Float(max(config.particleCount, 1))
            : 0

        // In tracer mode the particles move in the rigid analytic potential and nothing else,
        // so that is what the bulge must be balanced against.
        let equilibrium = DiskEquilibrium(config: config, selfGravitating: selfGravitating)
        let dispersion = jeansDispersion(
            density: { density(shape, radius: $0) },
            circularSpeed: { equilibrium.circularSpeed(atRadius: $0) },
            inner: scale * 0.005, edge: edge)
        for _ in 0..<count {
            let radius = inverseHernquistRadius(generator.uniform() * limit, scale: scale)
            // Flattened along the disk's own axis, which is what makes a bulge read as part
            // of the galaxy rather than as a sphere dropped into it.
            var local = randomDirection(&generator) * radius
            local.z *= flattening

            let sigma = dispersion(radius)
            let motion = SIMD3<Float>(generator.normal(), generator.normal(), generator.normal())

            system.append(
                position: rotation * local + config.position,
                velocity: rotation * (motion * sigma) + config.velocity,
                galaxy: galaxyIndex,
                radius: radius,
                population: 0,
                luminosity: 0.45 + 1.5 * generator.uniform() * generator.uniform(),
                formation: StarFormation.oldFormation(roll: generator.uniform()),
                component: .bulge,
                mass: particleMass
            )
        }
    }

    /// Isotropic dispersion of a pressure-supported population, from the Jeans equation
    /// solved against whatever weight actually presses on it.
    ///
    /// That is the whole of it. Both the bulge and the dark halo sit inside a galaxy whose
    /// mass is mostly not their own, and a population given only its own weight to balance
    /// comes out far too cold. The integral has no short closed form against a composite
    /// potential, so it is tabulated once over log radius and read back by interpolation.
    /// Mild flattening is ignored: the spherical solution is well inside what a population
    /// loses to its own settling anyway.
    static func jeansDispersion(
        density: (Float) -> Float,
        circularSpeed: (Float) -> Float,
        inner: Float,
        edge: Float
    ) -> (Float) -> Float {
        let samples = 128
        let start = max(inner, 1e-5)
        let step = log(max(edge, start * 2) / start) / Float(samples - 1)
        let radii = (0..<samples).map { start * exp(step * Float($0)) }

        // rho sigma^2 at r is the weight of everything above it, so the integral runs inward
        // from the truncation radius.
        func integrand(_ r: Float) -> Float {
            let speed = circularSpeed(r)
            return density(r) * speed * speed / max(r, 1e-6)
        }
        var pressure = [Float](repeating: 0, count: samples)
        for index in Swift.stride(from: samples - 2, through: 0, by: -1) {
            let a = radii[index]
            let b = radii[index + 1]
            pressure[index] = pressure[index + 1] + 0.5 * (integrand(a) + integrand(b)) * (b - a)
        }
        let sigma = (0..<samples).map { sqrt(max(pressure[$0] / max(density(radii[$0]), 1e-30), 0)) }

        return { radius in
            let position = log(max(radius, start) / start) / step
            let index = min(max(Int(position), 0), samples - 2)
            let blend = min(max(position - Float(index), 0), 1)
            return sigma[index] * (1 - blend) + sigma[index + 1] * blend
        }
    }

    /// Dark matter, drawn from the potential's own density and its isotropic distribution
    /// function. These particles are never drawn, but without them the halo carries mass and
    /// no inertia: it raises no wake behind an infalling companion, so there is no dynamical
    /// friction and nothing ever merges.
    private static func sampleHalo(
        _ config: GalaxyConfig,
        galaxyIndex: UInt32,
        into system: inout ParticleSystem,
        using generator: inout SeededGenerator
    ) {
        let count = config.haloParticleCount
        guard count > 0 else { return }
        let potential = config.potential
        let edge = max(config.haloExtent, 1) * potential.scaleRadius
        let limit = min(enclosedFraction(potential, radius: edge), 0.999)
        let particleMass =
            potential.mass * (1 - config.diskMassFraction) / Float(count)

        // The halo's own profile no longer describes the potential it sits in: the stars have
        // been taken out of it and laid down as a disk and a bulge, both further in. Balanced
        // against its own weight alone the halo runs hot and drifts outward, taking the disk
        // with it, so its dispersion is solved against the galaxy as it is actually built.
        let equilibrium = DiskEquilibrium(config: config, selfGravitating: true)
        let dispersion = jeansDispersion(
            density: { density(potential, radius: $0) },
            circularSpeed: { equilibrium.circularSpeed(atRadius: $0) },
            inner: potential.scaleRadius * 0.005, edge: edge)

        for _ in 0..<count {
            let u = generator.uniform() * limit
            let radius =
                potential.profile == .plummer
                ? inversePlummerRadius(u, scale: potential.scaleRadius)
                : inverseHernquistRadius(u, scale: potential.scaleRadius)
            let sigma = dispersion(radius)
            let escape = potential.escapeSpeed(atRadius: radius)
            var speed: Float = 0
            for _ in 0..<32 {
                let draw = SIMD3<Float>(
                    generator.normal(), generator.normal(), generator.normal())
                speed = simd_length(draw) * sigma
                if speed < escape { break }
            }

            system.append(
                position: randomDirection(&generator) * radius + config.position,
                velocity: randomDirection(&generator) * speed + config.velocity,
                galaxy: galaxyIndex,
                radius: radius,
                population: 0,
                luminosity: 0,
                component: .halo,
                mass: particleMass
            )
        }
    }

    public static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = min(max((x - edge0) / max(edge1 - edge0, 1e-6), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// One position in the disk plane, together with how close it landed to an arm ridge.
    /// Rejection against a logarithmic spiral shapes the azimuthal density without touching
    /// the exponential radial profile. `contrast` above the galaxy's own arm strength makes a
    /// population hug the arms more tightly, which is what dust and HII regions do.
    private static func samplePlanePosition(
        _ config: GalaxyConfig,
        arms: Int,
        contrast: Float,
        windRate: Float,
        minimumRadius: Float,
        phaseOffset: Float = 0,
        scaleMultiplier: Float = 1,
        using generator: inout SeededGenerator
    ) -> (radius: Float, phi: Float, armProximity: Float) {
        var radius: Float = 0
        var phi: Float = 0
        var density: Float = 1
        for _ in 0..<32 {
            radius =
                config.diskScaleLength * scaleMultiplier
                * inverseExponentialCDF(generator.uniform(), truncation: config.diskTruncation)
            phi = generator.uniform() * 2 * .pi
            if radius < minimumRadius { continue }
            if contrast <= 0 {
                density = 1
                break
            }
            // A logarithmic spiral winds without limit toward the centre, so the pattern is
            // faded out inside the bulge where real arms do not reach either.
            let envelope = smoothstep(0.25, 1.1, radius / config.diskScaleLength)
            let local = contrast * envelope
            let wound = phi - windRate * log(max(radius, 1e-3) / config.diskScaleLength)
            density = 1 + local * cos(Float(arms) * wound - phaseOffset)
            if generator.uniform() * (1 + contrast) <= density { break }
        }
        let proximity = contrast > 0 ? min(max((density - 1 + contrast) / (2 * contrast), 0), 1) : 0.5
        return (radius, phi, proximity)
    }

    /// A star-forming complex or one of its sub-clumps, in disk-plane polar coordinates.
    private struct Clump {
        var radius: Float
        var phi: Float
        var spread: Float
    }

    /// Clouds in a disk are not round: differential rotation shears them into arcs within a
    /// fraction of an orbit. Generating them already stretched along the direction of
    /// rotation means a fresh disk looks flocculent rather than like a field of dots.
    private static let shearRatio: Float = 2.6

    private static func scatter(
        _ clump: Clump, using generator: inout SeededGenerator
    ) -> (radius: Float, phi: Float) {
        let radius = max(clump.radius + generator.normal() * clump.spread, 0.03)
        let arc = clump.spread * shearRatio / max(clump.radius, 0.4)
        return (radius, clump.phi + generator.normal() * arc)
    }

    private static func sampleDisk(
        _ config: GalaxyConfig,
        galaxyIndex: UInt32,
        count: Int,
        selfGravitating: Bool,
        into system: inout ParticleSystem,
        using generator: inout SeededGenerator
    ) {
        let equilibrium = DiskEquilibrium(config: config, selfGravitating: selfGravitating)
        let particleMass =
            selfGravitating
            ? config.potential.mass * config.diskMassFraction / Float(max(config.particleCount, 1))
            : 0
        let rotation = config.orientation
        let spin = config.spin.sign
        let arms = config.kind == .spiral ? max(config.armCount, 0) : 0
        let strength = arms > 0 ? min(max(config.armStrength, 0), 0.95) : 0
        let windRate = config.armWindRate
        let bulgeRadius = max(config.bulgeExtent * config.diskScaleLength, 1e-3)
        let dustShare = min(max(config.dustFraction, 0), 0.8)
        let hiiShare = min(max(config.starFormingFraction, 0), 0.3)
        let clumpiness = min(max(config.clumpiness, 0), 1)
        let scale = config.diskScaleLength

        // Star formation is hierarchical: giant complexes, clumps inside them, stars inside
        // those. Drawing every particle straight from the smooth profile is what makes a
        // simulated disk look airbrushed next to a real one.
        // Sizes follow a steep power law rather than one characteristic scale: a few large
        // complexes, many small knots. That is what reads as fractal structure instead of a
        // field of identical blobs.
        var complexes: [Clump] = []
        for _ in 0..<110 {
            let placed = samplePlanePosition(
                config, arms: arms, contrast: min(strength * 1.3, 0.95), windRate: windRate,
                minimumRadius: bulgeRadius * 0.6, using: &generator)
            let u = generator.uniform()
            complexes.append(
                Clump(
                    radius: placed.radius, phi: placed.phi,
                    spread: scale * (0.09 + 0.30 * u * u)))
        }

        var clumps: [Clump] = []
        for _ in 0..<5_000 {
            let parent =
                complexes[Int(generator.uniform() * Float(complexes.count)) % complexes.count]
            let placed = scatter(parent, using: &generator)
            let u = generator.uniform()
            clumps.append(
                Clump(
                    radius: placed.radius, phi: placed.phi,
                    spread: scale * (0.006 + 0.045 * u * u * u)))
        }

        for _ in 0..<max(count, 0) {
            let roll = generator.uniform()
            let component: ParticleComponent =
                roll < dustShare
                ? .dust : (roll < dustShare + hiiShare ? .hiiRegion : .star)

            // Gas, dust and young stars trace the complexes most strongly; the old smooth
            // disk underneath keeps the profile from turning into a field of blobs.
            let attachment = component == .star ? clumpiness : min(clumpiness + 0.3, 0.97)
            var radius: Float
            var phi: Float
            var proximity: Float

            if generator.uniform() < attachment, !clumps.isEmpty {
                let clump = clumps[Int(generator.uniform() * Float(clumps.count)) % clumps.count]
                let placed = scatter(clump, using: &generator)
                radius = placed.radius
                phi = placed.phi
                proximity = 1
            } else {
                let contrast = component == .dust ? min(strength * 1.4, 0.95) : strength
                let placed = samplePlanePosition(
                    config, arms: arms, contrast: contrast, windRate: windRate,
                    minimumRadius: component == .dust ? bulgeRadius * 0.5 : 0,
                    // Inside corotation the gas overtakes the pattern, so it piles up on the
                    // edge of the arm it arrives at and the dust lane sits there rather than
                    // on the ridge. Which edge that is follows the direction of rotation.
                    phaseOffset: component == .dust ? -0.85 * spin : 0,
                    scaleMultiplier: component == .dust ? 1.5 : 1,
                    using: &generator)
                radius = placed.radius
                phi = placed.phi
                proximity = placed.armProximity
            }

            let thickness = component == .dust ? config.diskThickness * 0.45 : config.diskThickness
            let height = thickness * inverseSech2CDF(generator.uniform())
            let local = SIMD3<Float>(radius * cos(phi), radius * sin(phi), height)

            let outward = SIMD3<Float>(cos(phi), sin(phi), 0)
            let along = SIMD3<Float>(-sin(phi), cos(phi), 0)
            let localVelocity: SIMD3<Float>
            if selfGravitating {
                // Anisotropic by construction: the epicyclic ratio fixes how the radial and
                // azimuthal dispersions relate, and the streaming speed lags the circular
                // speed by the asymmetric drift.
                let streaming = equilibrium.streamingSpeed(atRadius: radius)
                localVelocity =
                    outward * (generator.normal() * equilibrium.radialDispersion(atRadius: radius))
                    + along
                    * (streaming * spin
                        + generator.normal() * equilibrium.azimuthalDispersion(atRadius: radius))
                    + SIMD3<Float>(0, 0, 1)
                    * (generator.normal() * equilibrium.verticalDispersion(atRadius: radius))
            } else {
                let speed = config.potential.circularSpeed(atRadius: radius)
                let jitter = SIMD3<Float>(
                    generator.normal(), generator.normal(), generator.normal())
                localVelocity = along * (speed * spin) + jitter * (speed * config.velocityDispersion)
            }

            let diskAge = 0.30 + 0.68 * proximity
            let bulgeWeight = 1 - smoothstep(bulgeRadius * 0.4, bulgeRadius * 1.8, radius)
            // Kept for the tracer solver and for takes written before ages existed, which is
            // the only place it is still read.
            var population = diskAge * (1 - bulgeWeight)
            let edge = radius / scale
            let taper = 1 - smoothstep(config.diskTruncation - 2.1, config.diskTruncation, edge)
            // A wide spread in per-star brightness reads as texture rather than as grain.
            var brightness =
                (0.45 + 1.5 * generator.uniform() * generator.uniform())
                * max(taper, 0.02)

            // When this particle's stars formed. Every star carries a real age now: the disk
            // is drawn from an inside-out history, so its outskirts are the young part, and
            // both the colour and the light per unit mass follow from it. Dust is the gas
            // reservoir and has made nothing yet.
            var formation = StarFormation.sampledFormation(
                edge: edge / max(config.diskTruncation, 1e-3),
                armProximity: proximity, roll: generator.uniform())
            switch component {
            case .hiiRegion:
                population = 1
                brightness = (2.5 + 5 * generator.uniform()) * max(taper, 0.02)
                // A galaxy does not start the run having formed nothing. At a constant rate
                // the ages of what it has already made are uniform, so they are drawn that
                // way: a few knots still ionised, most of them well past it and on their way
                // into the disk's own population.
                formation =
                    -generator.uniform() * StarFormation.seedSpreadMyr
                    / Float(Physics.megayearsPerTimeUnit)
            case .dust:
                population = 0
                brightness = (0.8 + 0.5 * generator.uniform()) * max(taper, 0.02)
                formation = ParticleSystem.unformed
            case .star, .halo, .bulge:
                break
            }

            system.append(
                position: rotation * local + config.position,
                velocity: rotation * localVelocity + config.velocity,
                galaxy: galaxyIndex,
                radius: radius,
                population: population,
                luminosity: brightness,
                formation: formation,
                component: component,
                mass: particleMass
            )
        }
    }

    private static func sampleSpheroid(
        _ config: GalaxyConfig,
        galaxyIndex: UInt32,
        selfGravitating: Bool,
        into system: inout ParticleSystem,
        using generator: inout SeededGenerator
    ) {
        let particleMass =
            selfGravitating
            ? config.potential.mass * config.diskMassFraction / Float(max(config.particleCount, 1))
            : 0
        let potential = config.potential
        let edge = config.diskScaleLength * config.diskTruncation
        let limit = min(enclosedFraction(potential, radius: edge), 0.999)

        for _ in 0..<config.particleCount {
            let u = generator.uniform() * limit
            let radius =
                potential.profile == .plummer
                ? inversePlummerRadius(u, scale: potential.scaleRadius)
                : inverseHernquistRadius(u, scale: potential.scaleRadius)

            let direction = randomDirection(&generator)
            let speed = speedSample(potential, radius: radius, edge: edge, using: &generator)
            let velocity = randomDirection(&generator) * speed

            system.append(
                position: direction * radius + config.position,
                velocity: velocity + config.velocity,
                galaxy: galaxyIndex,
                radius: radius,
                population: 0.04,
                luminosity: 0.8 + 0.5 * generator.uniform(),
                formation: StarFormation.oldFormation(roll: generator.uniform()),
                component: .star,
                mass: particleMass
            )
        }
    }
}
