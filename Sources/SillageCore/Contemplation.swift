import simd

extension SceneConfig {
    /// A scene generated for its looks rather than for a question about dynamics.
    ///
    /// Level 2, because level 1 has nothing inside it to fly through: painted arms look right
    /// from far off and go flat the moment the camera enters the disk. Self-gravity is what
    /// makes structure that holds up close.
    ///
    /// What makes that affordable is that nothing here is in a hurry. The solver is paced to
    /// a rate of simulated time rather than run flat out, so it takes the share of the GPU
    /// that rate needs and no more — see `contemplationMyrPerSecond`. A generous time step
    /// buys the rest: measured through pericentre, 8x the tuned step sits inside the
    /// encounter's own chaotic scatter.
    /// `haste` pulls the two galaxies together at the start so the passage happens early.
    /// A one minute scene that opens on a wide separation is a minute of two specks drifting.
    public static func contemplation(
        particleCount: Int = 700_000, seed: UInt64, haste: Float = 0
    ) -> SceneConfig {
        var generator = SeededGenerator(seed: seed)
        let palette = Palette.all[Int(generator.next() % UInt64(Palette.all.count))]

        // Weighted towards encounters, which are what has something happening in them, but a
        // single disk turning slowly is worth sitting with too.
        let roll = generator.uniform() * (1 - 0.45 * haste)
        var scene: SceneConfig
        if roll < 0.42 {
            scene = encounter(
                particleCount: particleCount, palette: palette, generator: &generator,
                close: true, haste: haste)
        } else if roll < 0.70 {
            scene = encounter(
                particleCount: particleCount, palette: palette, generator: &generator,
                close: false, haste: haste)
        } else if roll < 0.86 {
            scene = solitary(particleCount: particleCount, palette: palette, generator: &generator)
        } else {
            scene = companion(particleCount: particleCount, palette: palette, generator: &generator)
        }
        scene.solver = .barnesHut
        scene.seed = seed
        for index in scene.galaxies.indices {
            // A rigid analytic halo. Live dark matter would triple the particle count for
            // material that reaches no pixel, and what it buys — dynamical friction, so a
            // pair actually merges — is not what an eleven minute scene is watching.
            scene.galaxies[index].haloParticleRatio = 0
            // Gas standing in for itself: without it a disk heats until its arms stop coming,
            // which is exactly the stretch of a scene somebody is sitting through.
            scene.galaxies[index].dissipationTime = generator.uniform(in: 180...320)
        }
        // Fewer, larger steps. Each one costs a tree built across every core as much as it
        // costs the GPU, so halving their number is worth twice what tuning the force pass
        // is: measured against a sixty hertz schedule, this is most of the difference between
        // a smooth minute and a stuttering one. Accuracy is not the currency here — through
        // pericentre, 16x the tuned step sits inside the encounter's own chaotic scatter, and
        // 32x is where it visibly leaves it.
        // Small steps, taken often. A large step is cheaper for the same simulated time and
        // that is exactly the wrong trade here: what the eye reads as motion is the rate at
        // which positions change, and four large steps a second make a galaxy jump while the
        // starfield, which follows only the camera, glides past it.
        scene.timeStepScale = generator.uniform(in: 0.7...1.1)
        // Barnes-Hut's accuracy knob, and the cheapest thing to spend here. Measured on a
        // concentrated cluster, 0.85 against the usual 0.6 is most of a factor of two off the
        // force pass for a mean error of half a percent — which is a fifth of what changing
        // the time step already costs, and nobody is measuring anything in this mode.
        scene.openingAngle = 0.85
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
        particleCount: Int, palette: Palette, generator: inout SeededGenerator, close: Bool,
        haste: Float = 0
    ) -> SceneConfig {
        let separation =
            generator.uniform(in: close ? 46...72 : 90...150) * (1 - 0.42 * haste)
        let speed = generator.uniform(in: close ? 0.48...0.62 : 0.34...0.46) * (1 + 0.2 * haste)
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
