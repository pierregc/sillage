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
    /// Visible particles, which the sampler places first so they form a contiguous run.
    ///
    /// Dark matter is most of what a self-gravitating scene integrates and none of what it
    /// draws: at a million and a half stars a galaxy it is three particles in five. Keeping it
    /// out of the front means the renderer, the smoothing field and a recorded take can all
    /// stop at `visibleCount` and never look at it again.
    public private(set) var visibleCount: Int = 0

    /// Moves every visible particle to the front, keeping their order. Called once, after
    /// sampling.
    public mutating func partitionVisibleFirst() {
        var order = [Int]()
        order.reserveCapacity(count)
        for index in 0..<count
        where component[index] != ParticleComponent.halo.rawValue { order.append(index) }
        visibleCount = order.count
        for index in 0..<count
        where component[index] == ParticleComponent.halo.rawValue { order.append(index) }

        func reorder<T>(_ values: inout [T]) {
            guard values.count == order.count else { return }
            var sorted = [T]()
            sorted.reserveCapacity(order.count)
            for index in order { sorted.append(values[index]) }
            values = sorted
        }
        reorder(&positions)
        reorder(&velocities)
        reorder(&galaxyIndex)
        reorder(&birthRadius)
        reorder(&population)
        reorder(&luminosity)
        reorder(&component)
        reorder(&mass)
    }

    /// For a system rebuilt from a file, which holds only what was drawn.
    public mutating func setVisibleCount(_ value: Int) {
        visibleCount = min(max(value, 0), count)
    }

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

extension ParticleSystem {
    /// The radius holding a given share of the light, which is what a camera should frame on.
    /// Weighted rather than geometric: dust absorbs and dark matter does neither, so a halo
    /// three times the size of the disk must not decide how far away the camera sits.
    /// Subsampled, because sorting every radius of five million particles to take a
    /// percentile costs 400 ms and answers the same question as fifty thousand of them.
    public func framingRadius(fraction: Float = 0.96) -> Float? {
        guard !positions.isEmpty else { return nil }
        let step = max(positions.count / 50_000, 1)
        var samples: [(radius: Float, light: Float)] = []
        samples.reserveCapacity(positions.count / step + 1)
        for index in stride(from: 0, to: positions.count, by: step) {
            let radius = simd_length(positions[index])
            guard radius.isFinite else { continue }
            let emits =
                index < component.count
                ? ParticleComponent(rawValue: component[index])?.emits ?? true : true
            let light = emits && index < luminosity.count ? luminosity[index] : 0
            samples.append((radius, light))
        }
        guard !samples.isEmpty else { return nil }
        samples.sort { $0.radius < $1.radius }
        let total = samples.reduce(Float(0)) { $0 + $1.light }
        guard total > 0 else { return samples[Int(Float(samples.count) * 0.9)].radius }
        var running: Float = 0
        for sample in samples {
            running += sample.light
            if running >= total * fraction { return sample.radius }
        }
        return samples[samples.count - 1].radius
    }
}
