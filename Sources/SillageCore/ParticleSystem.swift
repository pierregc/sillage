import simd

/// What a particle represents. Stars emit, HII regions emit strongly in a narrow band, and
/// dust absorbs rather than emits, so the renderer treats them differently.
public enum ParticleComponent: UInt32, Codable, Sendable, CaseIterable {
    case star = 0
    case hiiRegion = 1
    case dust = 2
    /// Dark matter. Carries mass and is never drawn.
    case halo = 3
    /// Old stars in the spheroid. Drawn exactly like a disk star, but held up by random
    /// motion rather than by rotation, so anything that acts on the disk has to leave it be.
    case bulge = 4

    public var isVisible: Bool { self != .halo }
    /// Emits starlight, so it frames a picture and carries the exposure.
    public var emits: Bool { self == .star || self == .hiiRegion || self == .bulge }
}

/// Structure-of-arrays particle storage. `positions` is laid out so it can back a
/// Metal buffer directly: SIMD3<Float> has a 16-byte stride, matching float3 in MSL.
public struct ParticleSystem: Sendable {
    public var positions: [SIMD3<Float>]
    public var velocities: [SIMD3<Float>]
    /// Which galaxy each particle started in, for per-galaxy colouring.
    public var galaxyIndex: [UInt32]
    /// Galactocentric radius at t = 0, for radial colour ramps.
    public var birthRadius: [Float]
    /// Stellar population, 0 for an old warm population and 1 for young blue stars.
    public var population: [Float]
    /// Per-particle brightness multiplier. Star-forming knots are far brighter than the mean.
    public var luminosity: [Float]
    public var component: [UInt32]
    /// Particle mass. Zero for the restricted solver, where tracers are massless.
    public var mass: [Float]

    public var count: Int { positions.count }

    public init(capacity: Int = 0) {
        positions = []
        velocities = []
        galaxyIndex = []
        birthRadius = []
        population = []
        luminosity = []
        component = []
        mass = []
        reserveCapacity(capacity)
    }

    public mutating func reserveCapacity(_ capacity: Int) {
        positions.reserveCapacity(capacity)
        velocities.reserveCapacity(capacity)
        galaxyIndex.reserveCapacity(capacity)
        birthRadius.reserveCapacity(capacity)
        population.reserveCapacity(capacity)
        luminosity.reserveCapacity(capacity)
        component.reserveCapacity(capacity)
        mass.reserveCapacity(capacity)
    }

    /// Exposes positions and velocities together for in-place integration. Going through the
    /// struct keeps the two exclusive accesses distinct, which nesting them at the call site
    /// would not.
    public mutating func withState(
        _ body: (inout [SIMD3<Float>], inout [SIMD3<Float>]) -> Void
    ) {
        body(&positions, &velocities)
    }

    public mutating func append(
        position: SIMD3<Float>,
        velocity: SIMD3<Float>,
        galaxy: UInt32,
        radius: Float,
        population stellarAge: Float = 0.5,
        luminosity brightness: Float = 1,
        component kind: ParticleComponent = .star,
        mass particleMass: Float = 0
    ) {
        positions.append(position)
        velocities.append(velocity)
        galaxyIndex.append(galaxy)
        birthRadius.append(radius)
        population.append(stellarAge)
        luminosity.append(brightness)
        component.append(kind.rawValue)
        mass.append(particleMass)
    }
}
