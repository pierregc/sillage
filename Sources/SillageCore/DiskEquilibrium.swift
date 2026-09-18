import simd

/// Velocity structure for a self-gravitating disk.
///
/// A cold disk is violently unstable: turn on self-gravity and it fragments within an orbit.
/// Toomre's criterion says a disk resists that when its radial velocity dispersion exceeds
/// 3.36 G Sigma / kappa, and simulations are normally run at Q between 1.2 and 1.6.
/// Everything here follows from that single number, which is why the restricted and
/// self-gravitating modes need genuinely different initial conditions and not just a
/// different force law.
public struct DiskEquilibrium {
    public let config: GalaxyConfig
    /// Tracers move in the rigid analytic potential and feel nothing else, so the two modes
    /// need different rotation curves and not just different force laws.
    public let selfGravitating: Bool
    private let centralDensity: Float

    public init(config: GalaxyConfig, selfGravitating: Bool = true) {
        self.config = config
        self.selfGravitating = selfGravitating
        let diskMass = config.potential.mass * config.diskMassFraction
        let scale = max(config.diskScaleLength, 1e-3)
        self.centralDensity = diskMass / (2 * .pi * scale * scale)
    }

    public func surfaceDensity(atRadius radius: Float) -> Float {
        centralDensity * exp(-radius / max(config.diskScaleLength, 1e-3))
    }

    /// Circular speed of the mass the sampler actually lays down, which is not the analytic
    /// potential it was taken from before.
    ///
    /// That potential stands for the whole galaxy as one sphere. What ends up in the box is a
    /// halo of that shape carrying part of the mass, a flattened exponential disk carrying
    /// the rest, and a bulge inside that. Both stellar pieces sit further in than a Hernquist
    /// of the galaxy's scale radius, and a disk pulls harder in its own plane than a sphere
    /// of the same mass. Handing the disk the sphere's rotation curve left it turning at
    /// about four fifths of what the real field asks for, so it fell inward and heated: the
    /// disks were unstable by construction rather than by any failure of the integrator.
    public func circularSpeed(atRadius radius: Float) -> Float {
        // A spheroidal galaxy's stars follow the potential's own profile at its own scale, and
        // a tracer run has no mass of its own at all, so in both cases the analytic curve was
        // right all along.
        guard selfGravitating, config.kind != .globular else {
            return config.potential.circularSpeed(atRadius: radius)
        }
        let r = max(radius, 1e-4)
        let mass = config.potential.mass
        let stellar = mass * config.diskMassFraction
        let bulgeShare = min(max(config.bulgeFraction, 0), 0.9)

        // Live halo particles are drawn only out to `haloExtent`, and they carry the whole
        // halo mass between them, so inside that radius the profile is denser than the
        // analytic one by exactly the share the truncation left out.
        var haloMass = mass * (1 - config.diskMassFraction)
        if config.haloParticleCount > 0 {
            let edge = max(config.haloExtent, 1) * config.potential.scaleRadius
            let kept = DiskSampler.enclosedFraction(config.potential, radius: edge)
            haloMass /= min(max(kept, 0.05), 1)
        }
        let halo = GalaxyPotential(
            profile: config.potential.profile,
            mass: haloMass,
            scaleRadius: config.potential.scaleRadius)
        var squared = halo.circularSpeed(atRadius: r) * halo.circularSpeed(atRadius: r)

        if bulgeShare > 0 {
            // Spherical: the bulge's flattening moves this by less than the sampling noise.
            // Truncated, though, and that part does show — a sphere cut at six scale radii
            // carries the whole of its mass inside them and pulls a third harder there than
            // the profile it was cut from.
            let a = max(config.bulgeExtent * config.diskScaleLength, 1e-3)
            let bulge = GalaxyPotential(profile: .hernquist, mass: stellar * bulgeShare, scaleRadius: a)
            let held = DiskSampler.enclosedFraction(
                bulge, radius: a * DiskSampler.bulgeTruncation)
            let inside = min(DiskSampler.enclosedFraction(bulge, radius: r) / max(held, 1e-3), 1)
            squared += Physics.gravitationalConstant * bulge.mass * inside / r
        }
        squared += Self.diskSpeedSquared(config, mass: stellar * (1 - bulgeShare), radius: r)
        return sqrt(max(squared, 0))
    }

    /// The disk's own contribution, summed over the pieces it is actually laid down as.
    ///
    /// One exponential is not what the sampler builds. The gas disk is drawn half again as
    /// wide as the stars and the thick disk wider still, and every piece is cut at five of
    /// its own scale lengths with the mass the tail would have carried laid down inside
    /// instead. Modelled as a single exponential of the stellar scale length, the curve came
    /// out three per cent fast everywhere between half a scale length and three — measured
    /// against a direct sum over the particles the sampler had just placed — so every star
    /// was launched at the pericentre of the same epicycle. They ran outward together,
    /// fell back together, and the whole disk breathed by eight per cent with a period of
    /// about a hundred and forty megayears before phase mixing damped it. That breathing is
    /// what this exists to remove; the same sum now sits within one per cent.
    static func diskSpeedSquared(_ config: GalaxyConfig, mass: Float, radius: Float) -> Float {
        let scale = max(config.diskScaleLength, 1e-3)
        let dust = min(max(config.dustFraction, 0), 0.8)
        let ionised = min(max(config.starFormingFraction, 0), 0.3)
        let outskirt = min(max(config.outskirtFraction, 0), 0.5)
        let thin = max(1 - dust - ionised - outskirt, 0)
        let truncation = max(config.diskTruncation, 0.5)
        let held = mass / max(1 - (1 + truncation) * exp(-truncation), 1e-3)
        // The thick component stands well off the plane — the sampler spreads it over a third
        // of its own radius — so it pulls in the plane like the mass it has inside r and not
        // like a sheet, which is worth half a per cent of the curve on its own.
        let wide = scale * DiskSampler.outskirtScaleMultiplier
        let x = radius / wide
        let inside = min((1 - (1 + x) * exp(-x)) / max(1 - (1 + truncation) * exp(-truncation), 1e-3), 1)
        return exponentialDiskSpeedSquared(
            mass: held * (thin + ionised), scaleLength: scale, radius: radius)
            + exponentialDiskSpeedSquared(
                mass: held * dust, scaleLength: scale * DiskSampler.dustScaleMultiplier,
                radius: radius)
            + Physics.gravitationalConstant * mass * outskirt * inside / max(radius, 1e-4)
    }

    /// Freeman's rotation curve for a razor-thin exponential disk, the one place a closed
    /// form exists for a flattened distribution. Beyond about fifteen scale lengths the
    /// Bessel product has nothing left to say and the disk pulls like a point mass.
    static func exponentialDiskSpeedSquared(
        mass: Float, scaleLength: Float, radius: Float
    ) -> Float {
        guard mass > 0, radius > 0 else { return 0 }
        let g = Double(Physics.gravitationalConstant)
        let h = Double(scaleLength)
        let r = Double(radius)
        let y = r / (2 * h)
        if y > 30 { return Float(g * Double(mass) / r) }
        let central = Double(mass) / (2 * .pi * h * h)
        // The exponential factors of the two scaled functions cancel in each product.
        let product =
            Bessel.scaledI0(y) * Bessel.scaledK0(y) - Bessel.scaledI1(y) * Bessel.scaledK1(y)
        return Float(max(4 * .pi * g * central * h * y * y * product, 0))
    }

    /// Epicyclic frequency, from the local shear of the rotation curve.
    public func epicyclicFrequency(atRadius radius: Float) -> Float {
        let r = max(radius, 1e-3)
        let step = max(r * 0.01, 1e-4)
        let speed = circularSpeed(atRadius: r)
        let ahead = circularSpeed(atRadius: r + step)
        let behind = circularSpeed(atRadius: max(r - step, 1e-5))
        let slope = (ahead - behind) / (2 * step)
        let omega = speed / r
        return sqrt(max(2 * omega * (omega + slope), 1e-8))
    }

    /// Radial dispersion required for the requested Toomre Q.
    public func radialDispersion(atRadius radius: Float) -> Float {
        let kappa = epicyclicFrequency(atRadius: radius)
        let sigma = surfaceDensity(atRadius: radius)
        return config.toomreQ * 3.36 * Physics.gravitationalConstant * sigma / max(kappa, 1e-6)
    }

    /// Azimuthal dispersion follows from the epicyclic ratio, not from a free choice.
    public func azimuthalDispersion(atRadius radius: Float) -> Float {
        let r = max(radius, 1e-3)
        let omega = circularSpeed(atRadius: r) / r
        let kappa = epicyclicFrequency(atRadius: r)
        return radialDispersion(atRadius: r) * kappa / max(2 * omega, 1e-6)
    }

    /// Vertical dispersion supporting an isothermal sech^2 layer of the configured height.
    public func verticalDispersion(atRadius radius: Float) -> Float {
        let height = max(config.diskThickness, 1e-3)
        return sqrt(
            .pi * Physics.gravitationalConstant * surfaceDensity(atRadius: radius) * height)
    }

    /// Mean streaming speed. Pressure support lets the mean rotation lag the circular speed,
    /// and ignoring that asymmetric drift makes the disk expand over its first orbit.
    public func streamingSpeed(atRadius radius: Float) -> Float {
        let r = max(radius, 1e-3)
        let circular = circularSpeed(atRadius: r)
        let dispersion = radialDispersion(atRadius: r)
        let drift = dispersion * dispersion * (2 * r / max(config.diskScaleLength, 1e-3) - 1)
        return sqrt(max(circular * circular - drift, 0))
    }

    /// Toomre Q actually realised by a given radial dispersion, for verification.
    public func toomreQ(atRadius radius: Float, radialDispersion sigma: Float) -> Float {
        let kappa = epicyclicFrequency(atRadius: radius)
        let density = surfaceDensity(atRadius: radius)
        return sigma * kappa / max(3.36 * Physics.gravitationalConstant * density, 1e-12)
    }
}
