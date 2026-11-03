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
    /// that kept their arms sat, and where small ones kept theirs without a bar.
    public static let drawnRange: ClosedRange<Float> = 1.75...1.95
    /// Visible particles a galaxy, shared by mass, for the softening the response is drawn at:
    /// a night's exploration, which Auto sizes between 50 000 and 200 000. A run with more
    /// particles is softened less, so its disks answer more.
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
