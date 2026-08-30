import simd

extension SceneConfig {
    /// A scene generated for its looks rather than for a question about dynamics.
    ///
    /// Level 1 on purpose. Tracers in rigid potentials cost one cheap kernel a step, which
    /// leaves the whole GPU to the picture: contemplation has to hold its frame rate for
    /// hours, and a tree that gets slower as a merger concentrates cannot promise that. The
    /// tidal bridges and tails a close passage raises are Toomre's 1972 result and need no
    /// self-gravity; the arms are painted by the density wave the renderer already carries.
    public static func contemplation(particleCount: Int = 1_600_000, seed: UInt64) -> SceneConfig {
        var generator = SeededGenerator(seed: seed)
        let palette = Palette.all[Int(generator.next() % UInt64(Palette.all.count))]

        // Weighted towards encounters, which are what has something happening in them, but a
        // single disk turning slowly is worth sitting with too.
        let roll = generator.uniform()
        var scene: SceneConfig
        if roll < 0.42 {
            scene = encounter(
                particleCount: particleCount, palette: palette, generator: &generator, close: true)
        } else if roll < 0.70 {
            scene = encounter(
                particleCount: particleCount, palette: palette, generator: &generator, close: false)
        } else if roll < 0.86 {
            scene = solitary(particleCount: particleCount, palette: palette, generator: &generator)
        } else {
            scene = companion(particleCount: particleCount, palette: palette, generator: &generator)
        }
        scene.solver = .restricted
        scene.seed = seed
        scene.timeStep = 0.02
        // Slow. The whole point is that nothing is in a hurry.
        scene.timeStepScale = generator.uniform(in: 0.35...0.85)
        scene.retune()
        return scene
    }

    /// Colour pairs that hold together. A galaxy's colour is a tint over the population
    /// ramp, so these are leanings rather than paint.
    struct Palette: Sendable {
        var primary: SIMD3<Float>
        var secondary: SIMD3<Float>

        static let all: [Palette] = [
            // Warm and cold, the classic pairing: an old red disk meeting a young blue one.
            Palette(
                primary: SIMD3(1.00, 0.84, 0.58), secondary: SIMD3(0.60, 0.79, 1.00)),
            // Both cold, nearly monochrome. Reads as depth rather than as colour.
            Palette(
                primary: SIMD3(0.74, 0.86, 1.00), secondary: SIMD3(0.86, 0.92, 1.00)),
            // Gold and rose.
            Palette(
                primary: SIMD3(1.00, 0.78, 0.44), secondary: SIMD3(1.00, 0.72, 0.78)),
            // Green-white against amber, which the tone curve pulls towards a pale sea.
            Palette(
                primary: SIMD3(0.80, 1.00, 0.92), secondary: SIMD3(1.00, 0.80, 0.52)),
            // Deep violet against ice.
            Palette(
                primary: SIMD3(0.78, 0.70, 1.00), secondary: SIMD3(0.68, 0.92, 1.00)),
        ]
    }

    /// A varied disk. Everything structural is drawn from a range wide enough that two of
    /// them are plainly different galaxies, and narrow enough that neither is ugly.
    private static func disk(
        _ name: String, count: Int, colour: SIMD3<Float>, generator: inout SeededGenerator,
        scaleLength: Float, mass: Float
    ) -> GalaxyConfig {
        let arms = [2, 2, 2, 3, 4, 5][Int(generator.next() % 6)]
        return GalaxyConfig(
            name: name,
            particleCount: count,
            potential: GalaxyPotential(
                profile: .hernquist, mass: mass, scaleRadius: scaleLength * 1.25),
            diskScaleLength: scaleLength,
            diskTruncation: generator.uniform(in: 3.6...5.2),
            diskThickness: generator.uniform(in: 0.16...0.42),
            armCount: arms,
            // Fewer arms carry more contrast; a five-armed floccculent disk wants less.
            armStrength: generator.uniform(in: 0.6...1.0) * (arms <= 2 ? 1 : 0.75),
            armPitch: generator.uniform(in: 0.28...0.62),
            dustFraction: generator.uniform(in: 0.14...0.38),
            starFormingFraction: generator.uniform(in: 0.008...0.045),
            bulgeExtent: generator.uniform(in: 0.11...0.26),
            bulgeFraction: generator.uniform(in: 0.05...0.26),
            color: colour,
            clumpiness: generator.uniform(in: 0.18...0.44),
            armIrregularity: generator.uniform(in: 0.3...0.78),
            inclination: generator.uniform(in: -1.2...1.2),
            positionAngle: generator.uniform(in: 0...6.28),
            spin: generator.uniform() < 0.5 ? .prograde : .retrograde)
    }

    /// Two comparable disks meeting. `close` decides whether they pass near enough to raise
    /// bridges and tails or merely sail past each other.
    private static func encounter(
        particleCount: Int, palette: Palette, generator: inout SeededGenerator, close: Bool
    ) -> SceneConfig {
        let separation = generator.uniform(in: close ? 46...72 : 90...150)
        let speed = generator.uniform(in: close ? 0.48...0.62 : 0.34...0.46)
        let angle = generator.uniform(in: 0.2...0.9)
        let share = generator.uniform(in: 0.38...0.62)
        let first = Int(Float(particleCount) * share)
        let scaleA = generator.uniform(in: 3.4...5.2)
        let scaleB = generator.uniform(in: 3.0...5.0)

        var a = disk(
            "Première", count: first, colour: palette.primary, generator: &generator,
            scaleLength: scaleA, mass: generator.uniform(in: 42...60))
        var b = disk(
            "Seconde", count: particleCount - first, colour: palette.secondary,
            generator: &generator, scaleLength: scaleB, mass: generator.uniform(in: 38...56))
        a.position = SIMD3(-separation / 2, 0, 0)
        b.position = SIMD3(separation / 2, generator.uniform(in: -8...8), generator.uniform(in: -12...12))
        a.velocity = SIMD3(speed * cos(angle), speed * sin(angle), 0)
        b.velocity = -a.velocity

        return SceneConfig(name: "Contemplation", galaxies: [a, b], centerSoftening: 1.2)
    }

    /// One disk, turning. Larger and more finely drawn, since there is only the one.
    private static func solitary(
        particleCount: Int, palette: Palette, generator: inout SeededGenerator
    ) -> SceneConfig {
        var only = disk(
            "Seule", count: particleCount, colour: palette.primary, generator: &generator,
            scaleLength: generator.uniform(in: 4.2...6.0),
            mass: generator.uniform(in: 46...64))
        only.diskTruncation = generator.uniform(in: 4.4...5.6)
        only.inclination = generator.uniform(in: -0.9...0.9)
        return SceneConfig(name: "Contemplation", galaxies: [only], centerSoftening: 1.2)
    }

    /// A big disk with a small dense thing falling through it.
    private static func companion(
        particleCount: Int, palette: Palette, generator: inout SeededGenerator
    ) -> SceneConfig {
        let small = particleCount / 9
        var host = disk(
            "Hôte", count: particleCount - small, colour: palette.primary, generator: &generator,
            scaleLength: generator.uniform(in: 4.4...6.0), mass: generator.uniform(in: 55...70))
        host.inclination = generator.uniform(in: -0.7...0.7)
        var intruder = GalaxyConfig(
            name: "Intrus",
            particleCount: small,
            kind: .globular,
            potential: GalaxyPotential(
                profile: .plummer, mass: generator.uniform(in: 9...16),
                scaleRadius: generator.uniform(in: 1.2...2.2)),
            diskScaleLength: generator.uniform(in: 1.4...2.4),
            color: palette.secondary,
            position: SIMD3(
                generator.uniform(in: -70 ... -40), generator.uniform(in: 18...40),
                generator.uniform(in: 6...26)),
            velocity: SIMD3(
                generator.uniform(in: 0.75...1.05), generator.uniform(in: -0.55 ... -0.25),
                generator.uniform(in: -0.2...0.0)),
            inclination: generator.uniform(in: 0.6...1.4),
            spin: .retrograde)
        intruder.dustFraction = 0.04
        return SceneConfig(name: "Contemplation", galaxies: [host, intruder], centerSoftening: 1.2)
    }
}
