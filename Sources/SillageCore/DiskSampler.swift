import simd

/// Populates a galaxy's disk with particles on near-circular orbits.
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

    public static func sample(
        _ config: GalaxyConfig,
        galaxyIndex: UInt32,
        into system: inout ParticleSystem,
        using generator: inout SeededGenerator
    ) {
        let rotation = config.orientation
        let spin = config.spin.sign

        for _ in 0..<config.particleCount {
            let radius = config.diskScaleLength
                * inverseExponentialCDF(generator.uniform(), truncation: config.diskTruncation)
            let phi = generator.uniform() * 2 * .pi
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
}
