import simd

extension SceneConfig {
    /// Two comparable disks on a bound, prograde, near-coplanar encounter. The orbit targets
    /// a pericentre near 9 kpc, which is where the companion's tidal pull at the disk edge
    /// overtakes the disk's own gravity: further out nothing is stripped, closer in the disks
    /// are destroyed before they can raise a tail. The disks run to five scale lengths so
    /// there is loosely bound material for the passage to pull out.
    public static func merger(particleCount: Int = 500_000, seed: UInt64 = 1) -> SceneConfig {
        let half = particleCount / 2
        let potential = GalaxyPotential(profile: .hernquist, mass: 50, scaleRadius: 5)

        return SceneConfig(
            name: "Merger",
            galaxies: [
                GalaxyConfig(
                    name: "Primary",
                    particleCount: half,
                    potential: potential,
                    diskScaleLength: 4,
                    diskTruncation: 5,
                    color: SIMD3<Float>(1.00, 0.86, 0.62),
                    position: SIMD3<Float>(-30, 0, 0),
                    velocity: SIMD3<Float>(0.554, 0.340, 0),
                    inclination: 0,
                    spin: .prograde
                ),
                GalaxyConfig(
                    name: "Secondary",
                    particleCount: particleCount - half,
                    potential: potential,
                    diskScaleLength: 4,
                    diskTruncation: 5,
                    color: SIMD3<Float>(0.62, 0.80, 1.00),
                    position: SIMD3<Float>(30, 0, 0),
                    velocity: SIMD3<Float>(-0.554, -0.340, 0),
                    inclination: 0.3,
                    positionAngle: 0.5,
                    spin: .prograde
                ),
            ],
            solver: .barnesHut,
            seed: seed,
            timeStep: 0.02
        )
    }

    /// An unequal pair: a large spiral and a companion a quarter its mass, on a prograde
    /// passage whose pericentre falls at 8.3 kpc, well inside the primary's disk. Equal
    /// masses answer each other symmetrically and the two halves of the picture repeat; a
    /// four to one ratio does not, so the primary keeps its far arm while the near one is
    /// drawn off into a tail and the companion takes the debris.
    public static func encounter(particleCount: Int = 500_000, seed: UInt64 = 1) -> SceneConfig {
        let primaryMass: Float = 70
        let companionMass: Float = 18
        // Split in proportion to mass, so a particle weighs the same in either galaxy. Unequal
        // particle masses heat the lighter disk numerically, which is the one that can least
        // afford it.
        let companion = Int(
            (Double(particleCount) * Double(companionMass / (primaryMass + companionMass)))
                .rounded())

        return SceneConfig(
            name: "Encounter",
            galaxies: [
                GalaxyConfig(
                    name: "Primary",
                    particleCount: particleCount - companion,
                    potential: GalaxyPotential(
                        profile: .hernquist, mass: primaryMass, scaleRadius: 5.5),
                    diskScaleLength: 4.6,
                    diskTruncation: 5,
                    armStrength: 0.88,
                    color: SIMD3<Float>(1.00, 0.93, 0.82),
                    armIrregularity: 0.7,
                    position: SIMD3<Float>(-12.682, 0, 0),
                    velocity: SIMD3<Float>(0.0205, -0.1186, 0),
                    inclination: 0.34,
                    positionAngle: 0.25,
                    spin: .prograde
                ),
                GalaxyConfig(
                    name: "Companion",
                    particleCount: companion,
                    potential: GalaxyPotential(
                        profile: .hernquist, mass: companionMass, scaleRadius: 2.4),
                    diskScaleLength: 2.0,
                    diskTruncation: 4.5,
                    armCount: 3,
                    armStrength: 0.6,
                    bulgeFraction: 0.22,
                    color: SIMD3<Float>(0.86, 0.92, 1.00),
                    armIrregularity: 0.8,
                    position: SIMD3<Float>(49.318, 0, 0),
                    velocity: SIMD3<Float>(-0.0795, 0.4614, 0),
                    inclination: 0.95,
                    positionAngle: 0.7,
                    spin: .prograde
                ),
            ],
            solver: .barnesHut,
            seed: seed,
            timeStep: 0.02
        )
    }

    /// A small companion on a fast retrograde pass. Shorter, sharper features.
    public static func flyby(particleCount: Int = 500_000, seed: UInt64 = 1) -> SceneConfig {
        let companion = particleCount * 3 / 25
        return SceneConfig(
            name: "Flyby",
            galaxies: [
                GalaxyConfig(
                    name: "Host",
                    particleCount: particleCount - companion,
                    potential: GalaxyPotential(profile: .hernquist, mass: 60, scaleRadius: 5),
                    diskScaleLength: 4.5,
                    color: SIMD3<Float>(0.72, 0.85, 1.00),
                    position: SIMD3<Float>.zero,
                    velocity: SIMD3<Float>(0, -0.1, 0),
                    inclination: 0.5,
                    spin: .prograde
                ),
                GalaxyConfig(
                    name: "Companion",
                    particleCount: companion,
                    kind: .globular,
                    potential: GalaxyPotential(profile: .plummer, mass: 12, scaleRadius: 1.6),
                    diskScaleLength: 1.8,
                    color: SIMD3<Float>(1.00, 0.80, 0.55),
                    position: SIMD3<Float>(-45, 25, 10),
                    velocity: SIMD3<Float>(1.1, -0.5, -0.15),
                    inclination: 1.1,
                    positionAngle: 0.3,
                    spin: .retrograde
                ),
            ],
            solver: .barnesHut,
            seed: seed,
            timeStep: 0.02
        )
    }

    /// A single isolated disk. Nothing should move outward: the reference case for validation.
    public static func isolatedDisk(particleCount: Int = 200_000, seed: UInt64 = 1) -> SceneConfig {
        SceneConfig(
            name: "Isolated disk",
            galaxies: [
                GalaxyConfig(
                    name: "Disk",
                    particleCount: particleCount,
                    potential: GalaxyPotential(profile: .hernquist, mass: 50, scaleRadius: 5),
                    diskScaleLength: 4,
                    velocityDispersion: 0
                )
            ],
            solver: .barnesHut,
            seed: seed,
            timeStep: 0.02
        )
    }

    public static let all: [SceneConfig] = [merger(), encounter(), flyby(), isolatedDisk()]

    /// Presets return themselves already tuned for their solver.
    static func tuned(_ scene: SceneConfig) -> SceneConfig {
        var copy = scene
        copy.retune()
        return copy
    }
}
