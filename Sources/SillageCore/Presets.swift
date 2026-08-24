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
                    position: SIMD3<Float>(30, 0, 0),
                    velocity: SIMD3<Float>(-0.554, -0.340, 0),
                    inclination: 0.3,
                    positionAngle: 0.5,
                    spin: .prograde
                ),
            ],
            solver: .restricted,
            seed: seed,
            timeStep: 0.02
        )
    }

    /// A small companion on a fast retrograde pass. Shorter, sharper features.
    public static func flyby(particleCount: Int = 500_000, seed: UInt64 = 1) -> SceneConfig {
        SceneConfig(
            name: "Flyby",
            galaxies: [
                GalaxyConfig(
                    name: "Host",
                    particleCount: particleCount * 4 / 5,
                    potential: GalaxyPotential(profile: .hernquist, mass: 60, scaleRadius: 5),
                    diskScaleLength: 4.5,
                    position: .zero,
                    velocity: SIMD3<Float>(0, -0.1, 0),
                    inclination: 0.5,
                    spin: .prograde
                ),
                GalaxyConfig(
                    name: "Companion",
                    particleCount: particleCount / 5,
                    potential: GalaxyPotential(profile: .plummer, mass: 12, scaleRadius: 2.5),
                    diskScaleLength: 2,
                    position: SIMD3<Float>(-45, 25, 10),
                    velocity: SIMD3<Float>(1.1, -0.5, -0.15),
                    inclination: 1.1,
                    positionAngle: 0.3,
                    spin: .retrograde
                ),
            ],
            solver: .restricted,
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
            solver: .restricted,
            seed: seed,
            timeStep: 0.02
        )
    }

    public static let all: [SceneConfig] = [merger(), flyby(), isolatedDisk()]
}
