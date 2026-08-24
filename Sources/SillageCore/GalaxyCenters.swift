import simd

/// The galaxy centres, integrated in double precision. There are only a handful of them and
/// their trajectory sets the whole encounter geometry, so accuracy here is cheap and matters.
/// Shared by the CPU and GPU solvers so both advance the encounter identically.
public struct GalaxyCenters {
    public private(set) var positions: [SIMD3<Double>]
    public private(set) var velocities: [SIMD3<Double>]
    private var accelerations: [SIMD3<Double>]
    private let masses: [Double]
    private let softeningSquared: Double

    public var count: Int { positions.count }

    public init(scene: SceneConfig) {
        positions = scene.galaxies.map { SIMD3<Double>($0.position) }
        velocities = scene.galaxies.map { SIMD3<Double>($0.velocity) }
        masses = scene.galaxies.map { Double($0.potential.mass) }
        softeningSquared = Double(scene.centerSoftening * scene.centerSoftening)
        accelerations = Array(repeating: .zero, count: scene.galaxies.count)
        recomputeAccelerations()
    }

    public var float: [SIMD3<Float>] {
        positions.map { SIMD3<Float>(Float($0.x), Float($0.y), Float($0.z)) }
    }

    /// One leapfrog step. Returns the centre positions before and after the drift, which is
    /// what a particle integrator needs for its two half kicks.
    public mutating func step(timeStep dt: Double) -> (before: [SIMD3<Float>], after: [SIMD3<Float>]) {
        let before = float
        let half = dt / 2
        for i in positions.indices {
            velocities[i] += accelerations[i] * half
            positions[i] += velocities[i] * dt
        }
        recomputeAccelerations()
        for i in positions.indices {
            velocities[i] += accelerations[i] * half
        }
        return (before, float)
    }

    /// Softened Plummer pair force, symmetric so momentum is conserved exactly.
    private mutating func recomputeAccelerations() {
        for i in accelerations.indices { accelerations[i] = .zero }
        for i in 0..<positions.count {
            for j in (i + 1)..<positions.count {
                let offset = positions[j] - positions[i]
                let d2 = simd_length_squared(offset) + softeningSquared
                let g = Double(Physics.gravitationalConstant) / (d2 * d2.squareRoot())
                accelerations[i] += offset * (g * masses[j])
                accelerations[j] -= offset * (g * masses[i])
            }
        }
    }

    public func energy() -> Double {
        var kinetic = 0.0
        for i in velocities.indices {
            kinetic += 0.5 * masses[i] * simd_length_squared(velocities[i])
        }
        var potential = 0.0
        for i in 0..<positions.count {
            for j in (i + 1)..<positions.count {
                let d2 = simd_length_squared(positions[j] - positions[i]) + softeningSquared
                let pair = masses[i] * masses[j] / d2.squareRoot()
                potential -= Double(Physics.gravitationalConstant) * pair
            }
        }
        return kinetic + potential
    }

    public func momentum() -> SIMD3<Double> {
        var total = SIMD3<Double>.zero
        for i in velocities.indices { total += velocities[i] * masses[i] }
        return total
    }
}
