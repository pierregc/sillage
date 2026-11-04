import Foundation

/// How strongly a disk answers its own perturbations, which is what the batch generators draw
/// for a spiral of three to five arms instead of its Toomre Q (#181).
///
/// Plummer softening weakens the pull of a wave of wavenumber k on a thin disk by exp(-k eps),
/// and a sech^2 layer of height z0 by about 1 / (1 + k z0), so the disk answers as an
/// unsoftened razor-thin one would at Q over that factor. Taken at the wavenumber that grows
/// fastest near Q 1.2 and with the thickness the disk keeps once the cooling has thinned it,
/// that effective Q sorted twelve generated spirals at 100 000 particles a galaxy: from 2.08 up
/// they faded to a smooth disk, under it they kept their arms (docs/notes/lumpy-arms.md).
public enum DiskResponse {
    /// The effective Q a spiral of three to five arms is drawn at: where the generated disks
    /// that kept their arms sat, and where large ones kept theirs without a bar.
    public static let drawnRange: ClosedRange<Float> = 1.75...1.95
    /// Where a small one is drawn instead, at the same place in the range. At equal response a
    /// small disk answers less than a large one, between a bar under 1.70 and a smooth disk
    /// from 1.77 (docs/notes/lumpy-arms.md).
    public static let smallRange: ClosedRange<Float> = 1.72...1.76
    /// The Toomre Q a two-armed spiral is drawn at: two arms ride the painted wave the streaming
    /// holds, and a large disk keeps this draw.
    public static let twoArmedToomreQ: ClosedRange<Float> = 1.25...1.45
    /// The response a small two-armed one is given instead, at the place of its draw of Q:
    /// drawn at its Q, a small two-armed disk faded where a large one kept its arms.
    public static let smallTwoArmedRange: ClosedRange<Float> = 1.80...1.86
    /// The scale length under which a spiral is small, in kpc: the category of #181.
    public static let smallScaleLength: Float = 4.2
    /// Visible particles a galaxy, shared by mass, for the softening the response is drawn at:
    /// a night's exploration, which Auto sizes between 50 000 and 200 000. A run with more
    /// particles is softened less, so the scene file keeps the response and each run solves Q
    /// for it at its own softening (`SceneConfig.solveToomreQ`).
    public static let referenceParticlesPerGalaxy = 100_000
    /// A scene is refused under a Toomre Q of 1, so a soft, thick disk stops here and answers
    /// less than it was drawn for.
    public static let lowestToomreQ: Float = 1.05

    /// The Toomre Q that gives `galaxy` the effective Q `effective` at `softening`, in kpc.
    public static func toomreQ(effective: Float, of galaxy: GalaxyConfig, softening: Float) -> Float {
        max(effective * gravityLeft(galaxy, softening: softening), lowestToomreQ)
    }

    public static func effectiveToomreQ(_ galaxy: GalaxyConfig, softening: Float) -> Float {
        galaxy.toomreQ / max(gravityLeft(galaxy, softening: softening), 1e-3)
    }

    /// The response a generated spiral is given once its size is known: its drawn one, at the
    /// same place in `smallRange` when it is small, or for a small two-armed one the place of
    /// its draw of Q in `smallTwoArmedRange`. Nil for a large two-armed one, which keeps its Q.
    public static func target(of galaxy: GalaxyConfig) -> Float? {
        let small = galaxy.diskScaleLength < smallScaleLength
        if let drawn = galaxy.effectiveToomreQ {
            return small ? moved(drawn, from: drawnRange, to: smallRange) : drawn
        }
        guard small, galaxy.kind == .spiral, galaxy.armCount <= 2 else { return nil }
        return moved(galaxy.toomreQ, from: twoArmedToomreQ, to: smallTwoArmedRange)
    }

    static func moved(_ value: Float, from: ClosedRange<Float>, to: ClosedRange<Float>) -> Float {
        let place = (value - from.lowerBound) / (from.upperBound - from.lowerBound)
        return to.lowerBound + min(max(place, 0), 1) * (to.upperBound - to.lowerBound)
    }

    /// The response a disk drawn for `drawn` keeps at every count from the reference one up:
    /// `drawn`, or the stiffer one the floor of Q leaves it at `referenceSoftening`. Kept so, a
    /// softer run never finds the floor and a hires disk answers as the explore preview did.
    public static func response(drawn: Float, of galaxy: GalaxyConfig, referenceSoftening: Float)
        -> Float
    {
        max(drawn, lowestToomreQ / max(gravityLeft(galaxy, softening: referenceSoftening), 1e-3))
    }

    /// The share of the disk's own pull on the wave that grows left by the softening and by its
    /// late thickness.
    public static func gravityLeft(_ galaxy: GalaxyConfig, softening: Float) -> Float {
        let k = wavenumber(galaxy)
        return exp(-k * max(softening, 0)) / (1 + k * lateThickness(galaxy))
    }

    /// Where a fluid disk at Q 1.2 grows fastest, 2 / 1.2^2 times kappa^2 / (2 pi G Sigma), at
    /// two scale lengths, in inverse kpc: 1.39 X_2 / h in the probe's `facts`.
    public static func wavenumber(_ galaxy: GalaxyConfig) -> Float {
        // The runs that show a generated scene give its halo particles, and the curve counts a
        // live halo denser inside the extent it is sampled to.
        var live = galaxy
        live.particleCount = max(live.particleCount, 1)
        if live.haloParticleRatio <= 0 { live.haloParticleRatio = 1.5 }
        let equilibrium = DiskEquilibrium(config: live, selfGravitating: true)
        let radius = 2 * max(galaxy.diskScaleLength, 1e-3)
        let kappa = equilibrium.epicyclicFrequency(atRadius: radius)
        let density = max(equilibrium.surfaceDensity(atRadius: radius), 1e-12)
        return 2 / (1.2 * 1.2) * kappa * kappa / (2 * .pi * Physics.gravitationalConstant * density)
    }

    /// The fewest turns at two scale lengths a generated disk sheds its random motion over.
    /// Drawn in megayears alone, a large disk turning in 200 Myr cooled in under one turn and
    /// broke into bound knots, as a gas disk does when it cools faster than it turns (#218).
    public static let coolingTurns: Float = 1.8

    /// The rotation period at two scale lengths, in Myr, under the live halo the runs give.
    public static func turn(of galaxy: GalaxyConfig) -> Float {
        var live = galaxy
        live.particleCount = max(live.particleCount, 1)
        if live.haloParticleRatio <= 0 { live.haloParticleRatio = 1.5 }
        let radius = 2 * max(galaxy.diskScaleLength, 1e-3)
        let speed = max(
            DiskEquilibrium(config: live, selfGravitating: true).circularSpeed(atRadius: radius), 1e-6)
        return 2 * .pi * radius / speed * Float(Physics.megayearsPerTimeUnit)
    }

    /// The cooling a generated disk is given: the time drawn, held to `coolingTurns` turns.
    public static func dissipationTime(drawn: Float, of galaxy: GalaxyConfig) -> Float {
        guard drawn > 0, galaxy.kind.isRotating else { return drawn }
        return max(drawn, coolingTurns * turn(of: galaxy))
    }

    /// A spiral's dust, as a share of its particles, as the generators draw it.
    public static let drawnDust: ClosedRange<Float> = 0.14...0.38
    /// The share of a large spiral's disk mass its gas carries, at the place of its dust draw.
    /// As heavy as its dust, the gas of a large disk, laid down wider than the stars, broke the
    /// outskirts into bound knots cooled over 1.8 to 2.5 turns; a large spiral holds a tenth to a
    /// fifth of its disk in gas (#218). A two-armed one keeps its gas: it carries the painted
    /// wave its arms ride, and none of them knotted once the cooling was held.
    public static let largeDustMass: ClosedRange<Float> = 0.10...0.20

    /// The gas's share of a generated disk's mass: set for a large spiral of three to five
    /// arms, nil otherwise.
    public static func dustMassFraction(of galaxy: GalaxyConfig) -> Float? {
        guard galaxy.kind == .spiral, galaxy.armCount > 2, galaxy.diskScaleLength >= smallScaleLength
        else { return nil }
        return moved(galaxy.dustFraction, from: drawnDust, to: largeDustMass)
    }

    /// The sech^2 height a disk keeps over its last 500 Myr: the cooling thins a thick one to
    /// about half and leaves a thin one near 0.035 scale lengths. Fitted to 31 probe runs of
    /// twelve spirals, 0.005 scale lengths rms.
    public static func lateThickness(_ galaxy: GalaxyConfig) -> Float {
        0.023 * galaxy.diskScaleLength + 0.32 * galaxy.diskThickness
    }

    /// The softening `galaxies` run at with `referenceParticlesPerGalaxy` visible particles a
    /// galaxy, shared by mass as a placed scene shares them, a black hole counting for none.
    public static func referenceSoftening(_ galaxies: [GalaxyConfig]) -> Float {
        let counted = galaxies.filter { $0.kind != .blackHole }.count
        let mass = galaxies.reduce(Float(0)) { $0 + $1.potential.mass }
        guard counted > 0, mass > 0 else { return 0 }
        let counts = SceneConfig.sharedCounts(
            referenceParticlesPerGalaxy * counted,
            weights: galaxies.map { Double($0.potential.mass / mass) }, kinds: galaxies.map(\.kind))
        var scene = SceneConfig(name: "", galaxies: galaxies)
        for index in scene.galaxies.indices { scene.galaxies[index].particleCount = counts[index] }
        return scene.recommendedSoftening
    }
}

extension SceneConfig {
    /// Gives every disk drawn for its response (`GalaxyConfig.effectiveToomreQ`) the Toomre Q
    /// that holds it at `softening`, the one the scene runs at.
    public mutating func solveToomreQ(softening: Float) {
        for index in galaxies.indices {
            guard let effective = galaxies[index].effectiveToomreQ else { continue }
            galaxies[index].toomreQ = DiskResponse.toomreQ(
                effective: effective, of: galaxies[index], softening: softening)
        }
    }
}
