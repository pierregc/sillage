import simd

/// Level 1: galaxies are rigid analytic potentials moving under their mutual attraction,
/// and disk particles are massless tracers. Cost is O(N) per step.
public final class RestrictedSolver: Solver {
    public let kind: SolverKind = .restricted
    public let scene: SceneConfig
    public private(set) var particles: ParticleSystem
    public private(set) var time: Float = 0

    /// Galaxy centres are integrated in double precision: there are only a handful of them
    /// and their trajectory sets the whole encounter geometry.
    private var centerPositions: [SIMD3<Double>]
    private var centerVelocities: [SIMD3<Double>]
    private let centerMasses: [Double]
    private let potentials: [GalaxyPotential]
    private let softeningSquared: Double

    private var centerAccelerations: [SIMD3<Double>]
    private var particleAccelerations: [SIMD3<Float>]

    public var centers: [SIMD3<Float>] {
        centerPositions.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }
    }

    public convenience init(scene: SceneConfig) {
        self.init(scene: scene, particles: RestrictedSolver.sampleParticles(for: scene))
    }

    /// Builds a solver over an explicit particle set, for replays and hand-built conditions.
    public init(scene: SceneConfig, particles: ParticleSystem) {
        self.scene = scene
        self.potentials = scene.galaxies.map(\.potential)
        self.centerMasses = scene.galaxies.map { Double($0.potential.mass) }
        self.softeningSquared = Double(scene.centerSoftening * scene.centerSoftening)
        self.centerPositions = scene.galaxies.map { SIMD3<Double>($0.position) }
        self.centerVelocities = scene.galaxies.map { SIMD3<Double>($0.velocity) }
        self.centerAccelerations = Array(repeating: .zero, count: scene.galaxies.count)

        self.particles = particles
        self.particleAccelerations = Array(repeating: .zero, count: particles.count)

        computeAccelerations()
    }

    public static func sampleParticles(for scene: SceneConfig) -> ParticleSystem {
        var system = ParticleSystem(capacity: scene.totalParticleCount)
        var generator = SeededGenerator(seed: scene.seed)
        for (index, galaxy) in scene.galaxies.enumerated() {
            DiskSampler.sample(galaxy, galaxyIndex: UInt32(index), into: &system, using: &generator)
        }
        return system
    }

    /// Overwrites the state of a single particle. Used to set up analytic test orbits.
    public func place(_ index: Int, position: SIMD3<Float>, velocity: SIMD3<Float>) {
        particles.positions[index] = position
        particles.velocities[index] = velocity
        computeAccelerations()
    }

    public func step() {
        let dt = scene.timeStep
        let halfDt = dt / 2

        for i in centerVelocities.indices {
            centerVelocities[i] += centerAccelerations[i] * Double(halfDt)
            centerPositions[i] += centerVelocities[i] * Double(dt)
        }
        for i in particles.velocities.indices {
            particles.velocities[i] += particleAccelerations[i] * halfDt
            particles.positions[i] += particles.velocities[i] * dt
        }

        computeAccelerations()

        for i in centerVelocities.indices {
            centerVelocities[i] += centerAccelerations[i] * Double(halfDt)
        }
        for i in particles.velocities.indices {
            particles.velocities[i] += particleAccelerations[i] * halfDt
        }

        time += dt
    }

    /// Softened Plummer pair force between centres, symmetric so momentum is conserved exactly.
    private func computeAccelerations() {
        for i in centerAccelerations.indices { centerAccelerations[i] = .zero }

        for i in 0..<centerPositions.count {
            for j in (i + 1)..<centerPositions.count {
                let offset = centerPositions[j] - centerPositions[i]
                let d2 = simd_length_squared(offset) + softeningSquared
                let invD3 = 1 / (d2 * d2.squareRoot())
                let g = Double(Physics.G) * invD3
                centerAccelerations[i] += offset * (g * centerMasses[j])
                centerAccelerations[j] -= offset * (g * centerMasses[i])
            }
        }

        let snapshot = centers
        particles.positions.withUnsafeBufferPointer { positions in
            particleAccelerations.withUnsafeMutableBufferPointer { accelerations in
                for index in positions.indices {
                    var total = SIMD3<Float>.zero
                    for g in potentials.indices {
                        total += potentials[g].acceleration(at: positions[index] - snapshot[g])
                    }
                    accelerations[index] = total
                }
            }
        }
    }

    /// Total energy of the galaxy centres alone. Constant to integrator accuracy.
    public func centerEnergy() -> Double {
        var kinetic = 0.0
        for i in centerVelocities.indices {
            kinetic += 0.5 * centerMasses[i] * simd_length_squared(centerVelocities[i])
        }
        var potential = 0.0
        for i in 0..<centerPositions.count {
            for j in (i + 1)..<centerPositions.count {
                let d2 = simd_length_squared(centerPositions[j] - centerPositions[i]) + softeningSquared
                potential -= Double(Physics.G) * centerMasses[i] * centerMasses[j] / d2.squareRoot()
            }
        }
        return kinetic + potential
    }

    public func centerMomentum() -> SIMD3<Double> {
        var total = SIMD3<Double>.zero
        for i in centerVelocities.indices {
            total += centerVelocities[i] * centerMasses[i]
        }
        return total
    }
}
