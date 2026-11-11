import SillageCore
#if canImport(simd)
    import simd
#else
    import Foundation
#endif

/// What a renderer holds of each massive particle besides where it is and when its stars
/// formed: 28 bytes a particle, made here once for the Metal renderer and for the CUDA one
/// (#276), which only hold them in buffers of their own. A light tracer's are in its word.
public struct ParticleAttributes: Sendable {
    /// How many values each array holds: the particles, never fewer than one.
    public var count: Int
    /// The particles a frame draws, which come first: dark matter is left out.
    public var drawnCount: Int
    public var population: [Float]
    public var formation: [Float]
    public var luminosity: [Float]
    public var component: [UInt32]
    public var galaxy: [UInt32]
    /// Two things a particle carries that never change: how much cooler its composition makes
    /// it read, and how wide its kernel is drawn.
    ///
    /// The composition is taken from `birthRadius` and not from where the particle stands now:
    /// a star flung out of a nucleus by an encounter keeps the composition of the nucleus.
    public var traits: [SIMD2<Float>]
    /// Each particle's birth radius in its galaxy's scale lengths, where the colour ramps
    /// look it up (#119).
    public var rampKeys: [Float]
    /// Each galaxy's scale length, in which a tracer's composition and ramp key are read.
    public var tracerScales: [Float]
    public var galaxySlots: Int
    /// One over the mean light per unit mass across this scene at t = 0.
    public var luminosityNormalisation: Float

    public init(_ particles: ParticleSystem) {
        let count = max(particles.count, 1)
        self.count = count
        drawnCount = particles.visibleCount > 0 ? particles.visibleCount : particles.count
        func attribute<T>(_ values: [T], _ fallback: T) -> [T] {
            values.count == count ? values : [T](repeating: fallback, count: count)
        }
        // Sorting every galaxy's radii is most of what building the two costs, so once.
        let birthScales =
            particles.birthRadius.count == particles.count
            ? Self.scaleLengths(particles.birthRadius, of: particles) : [:]
        population = attribute(particles.population, Float(0.5))
        formation = attribute(particles.formation, ParticleSystem.ancient)
        luminosity = attribute(particles.luminosity, Float(1))
        component = attribute(particles.component, UInt32(0))
        galaxy = attribute(particles.galaxyIndex, UInt32(0))
        traits = Self.traits(of: particles, scales: birthScales)
        rampKeys = Self.rampKeys(of: particles, birthScales: birthScales)
        tracerScales = (0..<TracerWord.galaxyLimit).map { birthScales[UInt32($0)] ?? 0 }
        galaxySlots = Int(particles.galaxyIndex.max() ?? 0) + 1
        luminosityNormalisation = Self.luminosityNormalisation(formation: particles.formation)
    }

    /// One over the mean light per unit mass of particles formed at `formation`, read on about
    /// fifty thousand of them.
    public static func luminosityNormalisation(formation: [Float]) -> Float {
        var totalLight: Float = 0
        var lit = 0
        let step = max(formation.count / 50_000, 1)
        for index in stride(from: 0, to: formation.count, by: step) {
            let born = formation[index]
            guard born > -1e8, born < 1e8 else { continue }
            totalLight +=
                StellarPopulation.sampled(ageMyr: -born * Float(Physics.megayearsPerTimeUnit))
                .lightPerMass
            lit += 1
        }
        return lit > 0 ? Float(lit) / max(totalLight, 1e-6) : 1
    }

    /// The colour-temperature multiplier each particle carries for its composition, one per
    /// particle, in the order the buffers are uploaded.
    ///
    /// Stored as the multiplier rather than as the abundance so that the slope relating the
    /// two lives in exactly one place, in `StellarPopulation`, instead of being written once
    /// here and once in the shader where it could drift.
    ///
    /// The scale length is measured off the sample rather than passed in: the renderer is not
    /// given the scene, and for an exponential disk the median radius is 1.678 scale lengths,
    /// which is a sturdier way to ask the question than trusting a configuration field to
    /// still describe the particles by the time they arrive here.
    static func traits(of particles: ParticleSystem, scales scaleLength: [UInt32: Float])
        -> [SIMD2<Float>]
    {
        let count = particles.count
        let scales =
            particles.kernelScale.count == count
            ? particles.kernelScale : [Float](repeating: 1, count: count)
        guard particles.birthRadius.count == count else {
            return (0..<max(count, 1)).map { SIMD2<Float>(1, $0 < scales.count ? scales[$0] : 1) }
        }
        return (0..<count).map { index in
            guard let scale = scaleLength[particles.galaxyIndex[index]] else {
                return SIMD2<Float>(1, scales[index])
            }
            let warming = StellarPopulation.metallicityWarming(
                StellarPopulation.metallicity(
                    atScaleLengths: particles.birthRadius[index] / scale))
            return SIMD2<Float>(warming, scales[index])
        }
    }

    /// For an exponential disk the median radius is 1.678 scale lengths.
    static func scaleLengths(_ radii: [Float], of particles: ParticleSystem) -> [UInt32:
        Float]
    {
        var byGalaxy: [UInt32: [Float]] = [:]
        for index in 0..<particles.count
        where particles.component[index] == ParticleComponent.star.rawValue {
            byGalaxy[particles.galaxyIndex[index], default: []].append(radii[index])
        }
        var scaleLength: [UInt32: Float] = [:]
        for (galaxy, radii) in byGalaxy where !radii.isEmpty {
            let sorted = radii.sorted()
            scaleLength[galaxy] = max(sorted[sorted.count / 2] / 1.678, 1e-3)
        }
        return scaleLength
    }

    /// Birth radius in scale lengths of the particle's own galaxy, one per particle.
    static func rampKeys(of particles: ParticleSystem, birthScales: [UInt32: Float]) -> [Float] {
        let count = particles.count
        let rebuilt = particles.colourRadius.count == count
        let radii = rebuilt ? particles.colourRadius : particles.birthRadius
        guard radii.count == count, count > 0 else {
            return [Float](repeating: 1.7, count: max(count, 1))
        }
        let scales = rebuilt ? scaleLengths(radii, of: particles) : birthScales
        return (0..<count).map { index in
            scales[particles.galaxyIndex[index]].map { radii[index] / $0 } ?? 1.7
        }
    }
}

/// A field star as the star field's pass reads it; mirrors `BackgroundStar` in `Shaders`.
public struct BackgroundStar: Sendable {
    public var direction: SIMD4<Float>
    public var color: SIMD4<Float>

    /// Field stars, placed far enough out that orbiting the galaxy does not parallax them.
    ///
    /// Colours are drawn as temperatures and converted by the same Planckian law the galaxy's
    /// own stars use, rather than picked out of three buckets by hand. The temperature
    /// distribution is the sky's: the overwhelming majority of stars are cool dwarfs, and the
    /// hot blue ones are rare and — because they are enormously more luminous — the ones that
    /// end up bright. Drawing brightness and colour together instead of independently is what
    /// makes a field read as a sky rather than as confetti.
    public static func field(count: Int) -> [BackgroundStar] {
        guard count > 0 else { return [] }
        var generator = SeededGenerator(seed: 0x5111_1A6E)
        var stars: [BackgroundStar] = []
        stars.reserveCapacity(count)
        let shell: Float = 6_000

        for _ in 0..<count {
            let direction = DiskSampler.randomDirection(&generator)
            // Steeply weighted to the cool end, which is what a magnitude-limited field is.
            let heat = pow(generator.uniform(), 2.6)
            let kelvin = 3_000 * pow(28_000 / 3_000, heat)
            let colour = Blackbody.linearSRGB(kelvin: kelvin)
            // Hot stars are the bright ones, because they are enormously more luminous; the
            // exponent bends with temperature rather than a term being added, so that raising
            // the count adds faint stars and not bright ones. Added instead of bent, at ten
            // thousand stars, and the frame came out a wall of diffraction spikes with the
            // galaxy lost behind it.
            let magnitude = pow(generator.uniform(), 6.5 - 2.2 * heat)
            // And a spike belongs to the few that earn one. Every star having one is what
            // makes a field read as a graphic rather than as a sky.
            let spike = DiskSampler.smoothstep(0.80, 0.97, magnitude)
            stars.append(
                BackgroundStar(
                    direction: SIMD4<Float>(
                        direction.x * shell, direction.y * shell, direction.z * shell, magnitude),
                    color: SIMD4<Float>(colour.x, colour.y, colour.z, spike)))
        }
        return stars
    }
}
