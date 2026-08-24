import simd

/// Level 1: galaxies are rigid analytic potentials moving under their mutual attraction,
/// and disk particles are massless tracers. Cost is O(N) per step.
public final class RestrictedSolver: Solver {
    public let kind: SolverKind = .restricted
    public let scene: SceneConfig
    public private(set) var particles: ParticleSystem
    public private(set) var time: Float = 0

    private var galaxyCenters: GalaxyCenters
    private let potentials: [GalaxyPotential]

    public var centers: [SIMD3<Float>] { galaxyCenters.float }

    public convenience init(scene: SceneConfig) {
        self.init(scene: scene, particles: RestrictedSolver.sampleParticles(for: scene))
    }

    /// Builds a solver over an explicit particle set, for replays and hand-built conditions.
    public init(scene: SceneConfig, particles: ParticleSystem) {
        self.scene = scene
        self.potentials = scene.galaxies.map(\.potential)
        self.galaxyCenters = GalaxyCenters(scene: scene)
        self.particles = particles
    }

    public static func sampleParticles(for scene: SceneConfig) -> ParticleSystem {
        var system = ParticleSystem(capacity: scene.totalParticleCount)
        var generator = SeededGenerator(seed: scene.seed)
        let selfGravitating = scene.solver == .barnesHut
        for (index, galaxy) in scene.galaxies.enumerated() {
            DiskSampler.sample(
                galaxy, galaxyIndex: UInt32(index), selfGravitating: selfGravitating,
                into: &system, using: &generator)
        }
        return system
    }

    /// Overwrites the state of a single particle. Used to set up analytic test orbits.
    public func place(_ index: Int, position: SIMD3<Float>, velocity: SIMD3<Float>) {
        particles.positions[index] = position
        particles.velocities[index] = velocity
    }

    public func step() {
        let dt = scene.timeStep
        let half = dt / 2
        let (before, after) = galaxyCenters.step(timeStep: Double(dt))

        particles.withState { positions, velocities in
            positions.withUnsafeMutableBufferPointer { p in
                velocities.withUnsafeMutableBufferPointer { v in
                    for i in p.indices {
                        var x = p[i]
                        var speed = v[i]
                        speed += acceleration(at: x, centers: before) * half
                        x += speed * dt
                        speed += acceleration(at: x, centers: after) * half
                        p[i] = x
                        v[i] = speed
                    }
                }
            }
        }

        time += dt
    }

    private func acceleration(at position: SIMD3<Float>, centers: [SIMD3<Float>]) -> SIMD3<Float> {
        var total = SIMD3<Float>.zero
        for g in potentials.indices {
            total += potentials[g].acceleration(at: position - centers[g])
        }
        return total
    }

    /// Total energy of the galaxy centres alone. Constant to integrator accuracy.
    public func centerEnergy() -> Double { galaxyCenters.energy() }

    public func centerMomentum() -> SIMD3<Double> { galaxyCenters.momentum() }
}
