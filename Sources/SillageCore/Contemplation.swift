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
    /// Encounters are drawn as geometry and placed backwards from their pericentres, which
    /// fall inside `contemplationWindow(haste:)`; `retimeEncounters` moves them into the clip a
    /// scene is actually shown in. `haste` brings the window earlier: a one minute scene that
    /// opens on a wide separation is a minute of two specks drifting.
    /// The physics and the colours come from two streams of the seed, so a different
    /// `lookSeed` repaints the same scene and a change to what the look draws moves nothing.
    public static func contemplation(
        particleCount: Int = 700_000, seed: UInt64, haste: Float = 0, galaxies: Int? = nil,
        lookSeed: UInt64? = nil
    ) -> SceneConfig {
        var generator = SeededGenerator(seed: seed)
        // The palette used to be this draw; skipping it keeps the physics of every earlier seed.
        _ = generator.next()
        var looks = SeededGenerator(seed: lookSeed ?? Self.lookSeed(for: seed))
        let palette = Palette.all[Int(looks.next() % UInt64(Palette.all.count))]

        // Weighted towards encounters, which are what has something happening in them, but a
        // single disk turning slowly is worth sitting with too.
        let roll = generator.uniform() * (1 - 0.45 * haste)
        let window = contemplationWindow(haste: haste)
        var scene: SceneConfig
        // An asked-for count overrides the roll, which is how a library covers the whole range
        // instead of drawing the same two shapes all night.
        if let galaxies, galaxies >= 3 {
            scene = group(
                count: particleCount, galaxies: min(galaxies, 4), palette: palette,
                generator: &generator, window: window)
        } else if galaxies == 1 {
            scene = solitary(
                particleCount: particleCount, palette: palette, generator: &generator)
        } else if galaxies == 2 {
            scene =
                roll < 0.5
                ? encounter(
                    particleCount: particleCount, palette: palette, generator: &generator,
                    close: true, window: window)
                : companion(
                    particleCount: particleCount, palette: palette, generator: &generator,
                    window: window)
        } else if roll < 0.42 {
            scene = encounter(
                particleCount: particleCount, palette: palette, generator: &generator,
                close: true, window: window)
        } else if roll < 0.70 {
            scene = encounter(
                particleCount: particleCount, palette: palette, generator: &generator,
                close: false, window: window)
        } else if roll < 0.86 {
            scene = solitary(particleCount: particleCount, palette: palette, generator: &generator)
        } else {
            scene = companion(
                particleCount: particleCount, palette: palette, generator: &generator,
                window: window)
        }
        scene.seed = seed
        scene.finishGenerated(using: &generator)
        return scene
    }

    /// What every generated scene shares once its galaxies and encounters are drawn.
    mutating func finishGenerated(using generator: inout SeededGenerator) {
        solver = .barnesHut
        let hole = hasBlackHole
        for index in galaxies.indices {
            // A rigid analytic halo. Live dark matter would triple the particle count for
            // material that reaches no pixel, and what it buys — dynamical friction, so a
            // pair actually merges — is not what an eleven minute scene is watching. Except
            // beside a black hole: a rigid halo takes no reaction from a mass a tenth of its
            // own, and the hole would pull on a galaxy that cannot move.
            galaxies[index].haloParticleRatio = hole && galaxies[index].kind != .blackHole ? 1.5 : 0
            // Gas standing in for itself: without it a disk heats until its arms stop coming,
            // which is exactly the stretch of a scene somebody is sitting through.
            let cooling = generator.uniform(in: 180...320)
            galaxies[index].dissipationTime = galaxies[index].kind == .blackHole ? 0 : cooling
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
        timeStepScale = generator.uniform(in: 0.7...1.1)
        // Barnes-Hut's accuracy knob, and the cheapest thing to spend here. With the
        // quadrupole, 1.0 costs less force pass than the monopole's 0.85 did (15.5 against
        // 18.7 ms at 450 000 particles) and is more accurate, and nobody is measuring
        // anything in this mode.
        openingAngle = 1.0
        retune()
        placeEncountersGivingWay()
    }

    /// Where a generated scene's pericentres fall when nothing says which clip it is for, in Myr.
    public static func contemplationWindow(haste: Float) -> ClosedRange<Float> {
        let pull = 1 - 0.6 * min(max(haste, 0), 1)
        return 60 * pull...420 * pull
    }

    /// A disk's attitude against its orbit. Prograde more often than not: it is the passage
    /// that raises the long tails.
    private static func attitude(_ generator: inout SeededGenerator) -> Encounter.Disk {
        Encounter.Disk(
            inclination: generator.uniform(in: 0...1.45),
            argument: generator.uniform(in: 0...(2 * .pi)),
            spin: generator.uniform() < 0.65 ? .prograde : .retrograde)
    }

    /// An orbital plane anywhere, so the camera does not always find the orbit face on.
    private static func plane(
        _ encounter: inout Encounter, _ generator: inout SeededGenerator
    ) {
        encounter.planeTilt = generator.uniform(in: -0.7...0.7)
        encounter.planeTurn = generator.uniform(in: 0...(2 * .pi))
        encounter.pericentreAngle = generator.uniform(in: 0...(2 * .pi))
    }

    /// The seed of the look stream when none is given.
    public static func lookSeed(for seed: UInt64) -> UInt64 {
        var mixer = SeededGenerator(seed: seed ^ 0x4C4F_4F4B_5354_524D)
        return mixer.next()
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
        // The orientation and spin drawn here hold for a disk alone; an encounter replaces them
        // with its own.
        let arms = [2, 2, 2, 3, 4, 5][Int(generator.next() % 6)]
        return GalaxyConfig(
            name: name,
            particleCount: count,
            potential: GalaxyPotential(
                profile: .hernquist, mass: mass,
                scaleRadius: scaleLength * generator.uniform(in: 0.9...1.7)),
            diskScaleLength: scaleLength,
            // Wide on purpose. Everything about the shape of a galaxy may vary; only where it
            // starts may not, or the two never meet and there is nothing to watch.
            diskTruncation: generator.uniform(in: 3.2...6.0),
            diskThickness: generator.uniform(in: 0.08...0.62),
            armCount: arms,
            // Fewer arms carry more contrast; a five-armed floccculent disk wants less.
            armStrength: generator.uniform(in: 0.6...1.0) * (arms <= 2 ? 1 : 0.75),
            armPitch: generator.uniform(in: 0.28...0.62),
            dustFraction: generator.uniform(in: 0.14...0.38),
            starFormingFraction: generator.uniform(in: 0.008...0.045),
            // Kept small on purpose. A heavy bulge puts a seventh of the stars on tight
            // orbits about the centre, and at any distance worth watching from that reads as
            // a swarm of yellow points rather than as the core of a galaxy.
            bulgeExtent: generator.uniform(in: 0.06...0.18),
            bulgeFraction: generator.uniform(in: 0.01...0.09),
            bulgeFlattening: generator.uniform(in: 0.45...0.95),
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
        window: ClosedRange<Float>
    ) -> SceneConfig {
        let scaleA = generator.uniform(in: 2.8...6.2)
        let scaleB = generator.uniform(in: 2.6...5.8)
        let a = disk(
            "Première", count: particleCount / 2, colour: palette.primary, generator: &generator,
            scaleLength: scaleA, mass: generator.uniform(in: 42...60))
        let b = disk(
            "Seconde", count: particleCount - particleCount / 2, colour: palette.secondary,
            generator: &generator, scaleLength: scaleB, mass: generator.uniform(in: 38...56))
        var meeting = Encounter(
            pericentre: generator.uniform(in: close ? 4...12 : 14...30),
            eccentricity: generator.uniform(in: close ? 0.75...1.15 : 0.9...1.4),
            massRatio: generator.uniform(in: 0.55...1.0),
            pericentreTime: window.lowerBound
                + generator.uniform(in: 0.2...0.55) * (window.upperBound - window.lowerBound),
            primaryDisk: attitude(&generator), secondaryDisk: attitude(&generator))
        plane(&meeting, &generator)
        var scene = SceneConfig(name: "Contemplation", galaxies: [a, b], centerSoftening: 1.2)
        scene.encounters = [meeting]
        return scene
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

    /// Three or four disks, each passing the first in turn, its passages spread over the
    /// window so the scene keeps happening. The centre of mass stays at rest: a group that
    /// drifts leaves the frame, and the camera has no way to know it should follow.
    private static func group(
        count: Int, galaxies: Int, palette: Palette, generator: inout SeededGenerator,
        window: ClosedRange<Float>
    ) -> SceneConfig {
        let names = ["Première", "Deuxième", "Troisième", "Quatrième"]
        var built: [GalaxyConfig] = []
        var masses: [Float] = []
        for index in 0..<galaxies {
            let share = index == 0 ? 1 : generator.uniform(in: 0.5...1.0)
            let mass = generator.uniform(in: 30...58) * share
            masses.append(mass)
            built.append(
                disk(
                    names[index],
                    count: index == 0 ? count - count / galaxies * (galaxies - 1) : count / galaxies,
                    colour: index % 2 == 0 ? palette.primary : palette.secondary,
                    generator: &generator,
                    scaleLength: generator.uniform(in: 2.6...5.0) * share.squareRoot(),
                    mass: mass))
        }
        // The heaviest goes first, so the galaxy the others pass is the one least thrown about
        // by them.
        let order = masses.indices.sorted { masses[$0] > masses[$1] }
        built = order.enumerated().map { rank, index in
            var galaxy = built[index]
            galaxy.name = names[rank]
            galaxy.color = rank % 2 == 0 ? palette.primary : palette.secondary
            return galaxy
        }
        masses = order.map { masses[$0] }
        let span = window.upperBound - window.lowerBound
        var encounters: [Encounter] = []
        for index in 1..<galaxies {
            let along = 0.15 + 0.6 * (Float(index) - generator.uniform(in: 0.2...0.8)) / Float(galaxies - 1)
            var meeting = Encounter(
                primary: 0, secondary: index,
                pericentre: generator.uniform(in: 5...18),
                eccentricity: generator.uniform(in: 0.9...1.3),
                massRatio: masses[index] / masses[0],
                pericentreTime: window.lowerBound + along * span,
                primaryDisk: attitude(&generator), secondaryDisk: attitude(&generator))
            plane(&meeting, &generator)
            encounters.append(meeting)
        }
        var scene = SceneConfig(name: "Contemplation", galaxies: built, centerSoftening: 1.2)
        scene.encounters = encounters
        return scene
    }

    /// A big disk with a small dense thing falling through it.
    private static func companion(
        particleCount: Int, palette: Palette, generator: inout SeededGenerator,
        window: ClosedRange<Float>
    ) -> SceneConfig {
        let small = particleCount / 9
        let host = disk(
            "Hôte", count: particleCount - small, colour: palette.primary, generator: &generator,
            scaleLength: generator.uniform(in: 4.4...6.0), mass: generator.uniform(in: 55...70))
        var intruder = GalaxyConfig(
            name: "Intrus",
            particleCount: small,
            kind: .globular,
            potential: GalaxyPotential(
                profile: .plummer, mass: generator.uniform(in: 9...16),
                scaleRadius: generator.uniform(in: 1.2...2.2)),
            diskScaleLength: generator.uniform(in: 1.4...2.4),
            color: palette.secondary)
        intruder.dustFraction = 0.04
        // Fast and close: it punches through the disk rather than orbiting it.
        var meeting = Encounter(
            pericentre: generator.uniform(in: 2...9),
            eccentricity: generator.uniform(in: 1.1...2.2),
            massRatio: intruder.potential.mass / host.potential.mass,
            pericentreTime: window.lowerBound
                + generator.uniform(in: 0.2...0.5) * (window.upperBound - window.lowerBound),
            primaryDisk: attitude(&generator),
            secondaryDisk: Encounter.Disk(spin: .retrograde))
        plane(&meeting, &generator)
        var scene = SceneConfig(
            name: "Contemplation", galaxies: [host, intruder], centerSoftening: 1.2)
        scene.encounters = [meeting]
        return scene
    }
}
