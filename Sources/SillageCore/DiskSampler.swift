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

    static func randomDirection(_ generator: inout SeededGenerator) -> SIMD3<Float> {
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

    public static func sample(
        _ config: GalaxyConfig,
        galaxyIndex: UInt32,
        into system: inout ParticleSystem,
        using generator: inout SeededGenerator
    ) {
        switch config.kind {
        case .spiral, .disk:
            sampleDisk(config, galaxyIndex: galaxyIndex, into: &system, using: &generator)
        case .globular:
            sampleSpheroid(config, galaxyIndex: galaxyIndex, into: &system, using: &generator)
        }
    }

    private static func sampleDisk(
        _ config: GalaxyConfig,
        galaxyIndex: UInt32,
        into system: inout ParticleSystem,
        using generator: inout SeededGenerator
    ) {
        let rotation = config.orientation
        let spin = config.spin.sign
        let arms = config.kind == .spiral ? max(config.armCount, 0) : 0
        let strength = arms > 0 ? min(max(config.armStrength, 0), 0.95) : 0
        let windRate = 1 / max(tan(config.armPitch), 1e-3)

        for _ in 0..<config.particleCount {
            var radius: Float = 0
            var phi: Float = 0
            // Rejection sampling against a logarithmic spiral gives arms without changing
            // the underlying exponential radial profile.
            for _ in 0..<24 {
                radius =
                    config.diskScaleLength
                    * inverseExponentialCDF(generator.uniform(), truncation: config.diskTruncation)
                phi = generator.uniform() * 2 * .pi
                if strength <= 0 { break }
                let wound = phi - windRate * log(max(radius, 1e-3) / config.diskScaleLength)
                let density = 1 + strength * cos(Float(arms) * wound)
                if generator.uniform() * (1 + strength) <= density { break }
            }

            let height = config.diskThickness * inverseSech2CDF(generator.uniform())
            let local = SIMD3<Float>(radius * cos(phi), radius * sin(phi), height)

            let speed = config.potential.circularSpeed(atRadius: radius)
            let tangential = SIMD3<Float>(-sin(phi), cos(phi), 0) * (speed * spin)
            let scatter = SIMD3<Float>(generator.normal(), generator.normal(), generator.normal())
            let localVelocity = tangential + scatter * (speed * config.velocityDispersion)

            system.append(
                position: rotation * local + config.position,
                velocity: rotation * localVelocity + config.velocity,
                galaxy: galaxyIndex,
                radius: radius
            )
        }
    }

    private static func sampleSpheroid(
        _ config: GalaxyConfig,
        galaxyIndex: UInt32,
        into system: inout ParticleSystem,
        using generator: inout SeededGenerator
    ) {
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
                radius: radius
            )
        }
    }
}
