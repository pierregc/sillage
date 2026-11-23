#if canImport(simd)
    import simd
#else
    import Foundation
#endif

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
    /// The dust ring's pull in the plane, as a speed squared, every `ringStep` kpc from the
    /// centre; empty without a ring.
    private let ringCurve: [Float]
    private let ringStep: Float
    private let ringMass: Float
    /// The flattened bulge's pull in the plane, as a speed squared, every `bulgeStep` kpc from
    /// the centre: empty unless the galaxy takes its bulge apart (`bulgeApart`).
    private let bulgeCurve: [Float]
    private let bulgeStep: Float

    public init(config: GalaxyConfig, selfGravitating: Bool = true) {
        self.config = config
        self.selfGravitating = selfGravitating
        let diskMass = config.potential.mass * config.diskMassFraction
        let scale = max(config.diskScaleLength, 1e-3)
        let own = config.bulgeApart == true ? 1 - min(max(config.bulgeFraction, 0), 0.9) : 1
        self.centralDensity = diskMass * own / (2 * .pi * scale * scale)
        let bulgeShare = min(max(config.bulgeFraction, 0), 0.9)
        let flattening = min(max(config.bulgeFlattening, 0.05), 1)
        let squeezed = config.bulgeApart == true && flattening < 1
        if selfGravitating, bulgeShare > 0, squeezed || config.bulgeFade != nil {
            let a = max(config.bulgeExtent * config.diskScaleLength, 1e-3)
            let step = 4 * a * config.bulgeCut / Float(Self.bulgeSamples - 1)
            bulgeStep = step
            bulgeCurve = (0..<Self.bulgeSamples).map {
                Self.flattenedBulgeSpeedSquared(
                    mass: diskMass * bulgeShare, scale: a, flattening: squeezed ? flattening : 1,
                    radius: Float($0) * step, cut: config.bulgeCut, fade: config.bulgeFade)
            }
        } else {
            bulgeStep = 1
            bulgeCurve = []
        }
        if selfGravitating, let ring = config.drawnDustRing {
            let disk = diskMass * (1 - min(max(config.bulgeFraction, 0), 0.9))
            let mass = disk * Self.shares(config).dust * ring.share
            let reach = (ring.radius + 4 * ring.width) * 2
            let step = reach / Float(Self.ringSamples - 1)
            ringMass = mass
            ringStep = step
            ringCurve = (0..<Self.ringSamples).map {
                Self.ringSpeedSquared(mass: mass, ring: ring, radius: Float($0) * step)
            }
        } else {
            ringMass = 0
            ringStep = 1
            ringCurve = []
        }
    }

    static let ringSamples = 192
    static let bulgeSamples = 1024

    /// What the bulge adds to the square of the circular speed in its own plane, flattened as
    /// the sampler draws it: a Hernquist sphere cut at six scale radii, its mass kept inside, and
    /// squeezed along the disk's axis. A spheroid pulls harder in its plane than the sphere it
    /// was squeezed from, a tenth at a flattening of 0.7 between one and three scale radii, which
    /// is nothing under a small bulge and a fifteenth of the launch speed's square under one of
    /// three quarters. Summed over its shells (Binney and Tremaine, equation 2.132).
    /// With a `fade` the shells thin out from that share of the cut to nothing at the cut.
    static func flattenedBulgeSpeedSquared(
        mass: Float, scale: Float, flattening: Float, radius: Float,
        cut: Float = DiskSampler.bulgeTruncation, fade: Float? = nil
    ) -> Float {
        guard mass > 0, radius > 0 else { return 0 }
        let a = Double(scale)
        let r = Double(radius)
        let edge = a * Double(cut)
        let held = bulgeHeld(scale: a, edge: edge, fade: fade)
        let squeeze = 1 - Double(flattening) * Double(flattening)
        let reach = min(r, edge)
        let shells = 400
        func kept(_ m: Double) -> Double {
            Double(DiskSampler.bulgeKept(radius: Float(m), edge: Float(edge), fade: fade))
        }
        var total = 0.0
        for shell in 0..<shells {
            let m = (Double(shell) + 0.5) * reach / Double(shells)
            total += m * kept(m) / ((m + a) * (m + a) * (m + a) * (r * r - squeeze * m * m).squareRoot())
        }
        total *= reach / Double(shells)
        return Float(2 * Double(Physics.gravitationalConstant) * Double(mass) * a * total / held)
    }

    /// The share of a whole Hernquist sphere of scale `a` that a bulge cut at `edge` holds.
    static func bulgeHeld(scale a: Double, edge: Double, fade: Float?) -> Double {
        guard fade != nil else { return (edge / (edge + a)) * (edge / (edge + a)) }
        let shells = 400
        var held = 0.0
        for shell in 0..<shells {
            let m = (Double(shell) + 0.5) * edge / Double(shells)
            held +=
                2 * a * m * Double(DiskSampler.bulgeKept(radius: Float(m), edge: Float(edge), fade: fade))
                / ((m + a) * (m + a) * (m + a))
        }
        return held * edge / Double(shells)
    }

    private func bulgeSpeedSquared(atRadius radius: Float, mass: Float) -> Float {
        let at = radius / bulgeStep
        let index = Int(at)
        guard index < bulgeCurve.count - 1 else {
            return Physics.gravitationalConstant * mass / max(radius, 1e-4)
        }
        let t = at - Float(index)
        return bulgeCurve[index] * (1 - t) + bulgeCurve[index + 1] * t
    }

    /// What a ring of gas adds to the square of the circular speed at `radius`: nothing to
    /// speak of well inside it, less than nothing just inside, where it pulls outward, and a
    /// point mass's share far outside. Summed over circles across the ring's width, each
    /// softened by a fifth of that width.
    static func ringSpeedSquared(mass: Float, ring: GalaxyConfig.DustRing, radius: Float) -> Float {
        guard mass > 0, radius > 0 else { return 0 }
        let r = Double(radius)
        let softening = max(0.2 * Double(ring.width), 0.025 * Double(ring.radius))
        let inner = Double(ring.widths.inner)
        // As close together across a long inner slope as across the ring itself.
        let circles = ring.innerWidth == nil ? 41 : 41 + 2 * Int((20 * inner / Double(ring.width)).rounded())
        let angles = 128
        var total = 0.0
        var weights = 0.0
        for circle in 0..<circles {
            var x = -3 + 6 * Double(circle) / Double(circles - 1)
            var circleRadius = Double(ring.radius) + Double(ring.width) * x
            if ring.innerWidth != nil {
                // Evenly from three inner spreads inside to three outer ones outside.
                circleRadius =
                    Double(ring.radius) - 3 * inner
                    + 3 * (inner + Double(ring.width)) * Double(circle) / Double(circles - 1)
                let offset = circleRadius - Double(ring.radius)
                x = offset / (offset < 0 ? inner : Double(ring.width))
            }
            guard circleRadius > 0 else { continue }
            let weight = exp(-0.5 * x * x) * circleRadius
            var pull = 0.0
            for angle in 0..<angles {
                let c = cos((Double(angle) + 0.5) * .pi / Double(angles))
                let d2 =
                    r * r + circleRadius * circleRadius - 2 * r * circleRadius * c + softening * softening
                pull += (r - circleRadius * c) / (d2 * d2.squareRoot())
            }
            total += weight * pull / Double(angles)
            weights += weight
        }
        guard weights > 0 else { return 0 }
        return Float(Double(Physics.gravitationalConstant) * Double(mass) * r * total / weights)
    }

    private func ringSpeedSquared(atRadius radius: Float) -> Float {
        guard !ringCurve.isEmpty else { return 0 }
        let at = radius / ringStep
        let index = Int(at)
        guard index < ringCurve.count - 1 else {
            return Physics.gravitationalConstant * ringMass / max(radius, 1e-4)
        }
        let t = at - Float(index)
        return ringCurve[index] * (1 - t) + ringCurve[index + 1] * t
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
        guard selfGravitating, config.kind.isRotating else {
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

        if !bulgeCurve.isEmpty {
            squared += bulgeSpeedSquared(atRadius: r, mass: stellar * bulgeShare)
        } else if bulgeShare > 0 {
            // Spherical: the bulge's flattening moves this by less than the sampling noise.
            // Truncated, though, and that part does show — a sphere cut at six scale radii
            // carries the whole of its mass inside them and pulls a third harder there than
            // the profile it was cut from.
            let a = max(config.bulgeExtent * config.diskScaleLength, 1e-3)
            let bulge = GalaxyPotential(profile: .hernquist, mass: stellar * bulgeShare, scaleRadius: a)
            let held = DiskSampler.enclosedFraction(
                bulge, radius: a * config.bulgeCut)
            let inside = min(DiskSampler.enclosedFraction(bulge, radius: r) / max(held, 1e-3), 1)
            squared += Physics.gravitationalConstant * bulge.mass * inside / r
        }
        squared += Self.diskSpeedSquared(config, mass: stellar * (1 - bulgeShare), radius: r)
        squared += ringSpeedSquared(atRadius: r)
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
        let (dust, ionised, outskirt) = shares(config)
        let thin = max(1 - dust - ionised - outskirt, 0)
        // The dust a ring holds pulls from where it stands (`ringSpeedSquared`).
        let spread = 1 - (config.drawnDustRing?.share ?? 0)
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
                mass: held * dust * spread, scaleLength: scale * DiskSampler.dustScaleMultiplier,
                radius: radius)
            + Physics.gravitationalConstant * mass * outskirt * inside / max(radius, 1e-4)
    }

    /// Shares of the disk's mass in the gas, the young knots and the outskirts: the gas's own
    /// when it has one, the rest in proportion.
    static func shares(_ config: GalaxyConfig) -> (dust: Float, ionised: Float, outskirt: Float) {
        var dust = min(max(config.dustFraction, 0), 0.8)
        var ionised = min(max(config.starFormingFraction, 0), 0.3)
        var outskirt = min(max(config.outskirtFraction, 0), 0.5)
        if let gas = config.dustMassFraction, dust > 0, config.dustFraction < 0.8 {
            let rest = (1 - min(max(gas, 0), 0.8)) / (1 - dust)
            dust = min(max(gas, 0), 0.8)
            ionised *= rest
            outskirt *= rest
        }
        return (dust, ionised, outskirt)
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

    /// How fast a grain lifted a little off the plane swings through it, in radians a time unit:
    /// Poisson's equation at the mid-plane, the density of the stellar layer, the bulge and the
    /// halo there less what the rotation curve's slope takes.
    public func verticalFrequency(atRadius radius: Float) -> Float {
        let r = max(radius, 1e-3)
        let scale = max(config.diskScaleLength, 1e-3)
        let truncation = max(config.diskTruncation, 0.5)
        let stellar = config.potential.mass * config.diskMassFraction
        let bulgeShare = min(max(config.bulgeFraction, 0), 0.9)
        let disk = stellar * (1 - bulgeShare) / max(1 - (1 + truncation) * exp(-truncation), 1e-3)
        let (dust, _, outskirt) = Self.shares(config)
        let height = max(config.diskThickness, 1e-3)
        // The stars' layer and the gas's thinner, longer one; a ring's own gas is left out.
        func layer(_ mass: Float, length: Float, height: Float) -> Float {
            r < length * truncation ? mass / (2 * .pi * length * length) * exp(-r / length) / (2 * height) : 0
        }
        var density =
            layer(disk * max(1 - dust - outskirt, 0), length: scale, height: height)
            + layer(
                disk * dust * (1 - (config.drawnDustRing?.share ?? 0)),
                length: scale * DiskSampler.dustScaleMultiplier, height: height * 0.45)
        if bulgeShare > 0 {
            let a = max(config.bulgeExtent * scale, 1e-3)
            let edge = a * config.bulgeCut
            let flattening = min(max(config.bulgeFlattening, 0.05), 1)
            let whole = GalaxyPotential(profile: .hernquist, mass: 1, scaleRadius: a)
            let inside = max(
                Float(Self.bulgeHeld(scale: Double(a), edge: Double(edge), fade: config.bulgeFade)), 1e-3)
            density +=
                stellar * bulgeShare * a / (2 * .pi) * DiskSampler.density(whole, radius: r)
                * DiskSampler.bulgeKept(radius: r, edge: edge, fade: config.bulgeFade) / (inside * flattening)
        }
        var haloMass = config.potential.mass * (1 - config.diskMassFraction)
        if config.haloParticleCount > 0 {
            let edge = max(config.haloExtent, 1) * config.potential.scaleRadius
            haloMass /= min(max(DiskSampler.enclosedFraction(config.potential, radius: edge), 0.05), 1)
        }
        let a = config.potential.scaleRadius
        let shape: Float = config.potential.profile == .hernquist ? a / (2 * .pi) : 3 * a * a / (4 * .pi)
        density += haloMass * shape * DiskSampler.density(config.potential, radius: r)
        let step = max(r * 0.01, 1e-4)
        let ahead = circularSpeed(atRadius: r + step)
        let behind = circularSpeed(atRadius: r - step)
        let slope = (ahead * ahead - behind * behind) / (2 * step)
        return sqrt(max(4 * .pi * Physics.gravitationalConstant * density - slope / r, 1e-8))
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

    /// The rate the painted pattern turns at and the streaming is computed for, in radians
    /// per time unit, unsigned: `patternShare` of the circular frequency at two scale lengths.
    /// The disk's own pattern turns at 0.8 to 1.0 of it, with corotation at 2.1 to 2.3 scale
    /// lengths, where real spirals have theirs (docs/notes/lumpy-arms.md). A galaxy described
    /// before the field, `patternShare` zero, keeps half the analytic potential's rate, 0.42
    /// of the material's, which beat against the matter.
    public func patternSpeed() -> Float {
        let reference = max(config.diskScaleLength * 2, 0.5)
        guard config.patternShare > 0 else {
            return config.potential.circularSpeed(atRadius: reference) / reference * 0.5
        }
        return circularSpeed(atRadius: reference) / reference * config.patternShare
    }

    /// Where a pattern at `patternSpeed` resonates with the disk: the inner Lindblad radius,
    /// inside which a density wave at that speed cannot exist, and the corotation radius,
    /// outside which the streaming reverses. Read on a grid of a twentieth of a scale length;
    /// the Lindblad radius is zero and the corotation infinite when the curve never crosses.
    public func resonances(of patternSpeed: Float) -> (lindblad: Float, corotation: Float) {
        let scale = max(config.diskScaleLength, 1e-3)
        var lindblad: Float = 0
        var corotation: Float = .infinity
        var previous: Float?
        for step in 1...240 {
            let r = Float(step) * 0.05 * scale
            let value = circularSpeed(atRadius: r) / r - epicyclicFrequency(atRadius: r) / 2 - patternSpeed
            if let p = previous, p > 0, value <= 0 {
                lindblad = r - 0.025 * scale
                break
            }
            previous = value
        }
        for step in 1...240 {
            let r = Float(step) * 0.05 * scale
            if circularSpeed(atRadius: r) / r < patternSpeed {
                corotation = r
                break
            }
        }
        return (lindblad, corotation)
    }

    /// Toomre Q actually realised by a given radial dispersion, for verification.
    public func toomreQ(atRadius radius: Float, radialDispersion sigma: Float) -> Float {
        let kappa = epicyclicFrequency(atRadius: radius)
        let density = surfaceDensity(atRadius: radius)
        return sigma * kappa / max(3.36 * Physics.gravitationalConstant * density, 1e-12)
    }
}
