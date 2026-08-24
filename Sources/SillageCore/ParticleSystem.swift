import simd

/// Structure-of-arrays particle storage. `positions` is laid out so it can back a
/// Metal buffer directly: SIMD3<Float> has a 16-byte stride, matching float3 in MSL.
public struct ParticleSystem: Sendable {
    public var positions: [SIMD3<Float>]
    public var velocities: [SIMD3<Float>]
    /// Which galaxy each particle started in, for per-galaxy colouring.
    public var galaxyIndex: [UInt32]
    /// Galactocentric radius at t = 0, for radial colour ramps.
    public var birthRadius: [Float]

    public var count: Int { positions.count }

    public init(capacity: Int = 0) {
        positions = []
        velocities = []
        galaxyIndex = []
        birthRadius = []
        positions.reserveCapacity(capacity)
        velocities.reserveCapacity(capacity)
        galaxyIndex.reserveCapacity(capacity)
        birthRadius.reserveCapacity(capacity)
    }

    public mutating func append(
        position: SIMD3<Float>,
        velocity: SIMD3<Float>,
        galaxy: UInt32,
        radius: Float
    ) {
        positions.append(position)
        velocities.append(velocity)
        galaxyIndex.append(galaxy)
        birthRadius.append(radius)
    }
}
