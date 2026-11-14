#if canImport(simd)
    import simd
#else
    import Foundation
#endif

/// A black hole close up (#314): a cloud of gas falls past it on a parabolic orbit, is torn into
/// a stream, and the stream winds round, crosses itself and settles into a hot disk.
///
/// In the hole's own units rather than the galaxies' kiloparsecs, since gravity has no scale but
/// the hole's: G, its mass and its Schwarzschild radius are all one, so light goes at the square
/// root of two and the time unit is √2 r_s / c, 14 s for a million suns. The hole pulls as
/// Paczyński and Wiita's -1 / (r - 1): the last stable circular orbit at 3, the marginally bound
/// one at 2, and eccentric orbits that precess about as general relativity has them, which is
/// what makes the stream cross itself. The tracers carry no mass, as in `RestrictedSolver`.
public struct TidalDisruption: Codable, Sendable, Equatable {
    public var tracers = 1_000_000
    public var seed: UInt64 = 1
    /// The cloud's centre passes the hole at this distance, on a parabolic orbit in the xy plane
    /// that turns anticlockwise seen from +z.
    public var pericentre: Float = 6
    public var cloudRadius: Float = 1.5
    /// Where the cloud stops holding together on its way in. Its own gravity, which tracers do
    /// not have, keeps it whole until then; after, every tracer follows its own orbit from where
    /// it stands, with the centre's velocity, which is what spreads their energies.
    public var release: Float = 10
    /// Gas: the rate at which a tracer's motion against the mean flow around it turns into
    /// heat, in e-foldings per orbit at its radius. 0 leaves the tracers collisionless.
    public var stickiness: Float = 2
    /// The slowest motion against the mean flow that counts as streams crossing, as a share of
    /// the circular speed at the tracer's radius: below it, a stream's own stretch stays cold.
    public var crossingSpeed: Float = 0.3
    /// The disk's viscosity, as a loss of angular momentum: orbits to lose 1/e of it, 0 for none.
    /// What carries the ring the stream settles into down to the last stable orbit.
    public var viscousOrbits: Float = 40
    /// How long the light of a heating lasts, a short time against any orbit worth watching, so
    /// that a crossing glows where it happens and a stream flung out goes dark.
    public var coolingTime: Float = 10
    /// Tracers that come closer than this are swallowed.
    public var swallow: Float = 1.5
    public var timeStep: Float = 0.25
    /// The run's clock reads zero when the centre passes its pericentre, and stops here.
    public var duration: Float = 5000
    /// Time between the frames a take keeps.
    public var frameInterval: Float = 250

    public init() {}

    /// Light's speed in these units.
    public static let lightSpeed = Float(2).squareRoot()
    public static let innermostStableOrbit: Float = 3
    /// A sub-step is this fraction of a radian of the orbit at the tracer's radius.
    public static let subStepAngle: Float = 0.02
    public static let maximumSubSteps = 512

    public static func potential(radius: Float) -> Float { -1 / (radius - 1) }

    public static func acceleration(at position: SIMD3<Float>) -> SIMD3<Float> {
        let r = simd_length(position)
        let d = max(r - 1, 1e-3)
        return -position / (r * d * d)
    }

    public static func circularSpeed(radius: Float) -> Float { radius.squareRoot() / (radius - 1) }

    /// One over the angular rate of a circular orbit at `radius`.
    public static func dynamicalTime(radius: Float) -> Float {
        max(radius - 1, 1e-3) * radius.squareRoot()
    }

    public static func orbitalPeriod(radius: Float) -> Float {
        2 * .pi * dynamicalTime(radius: radius)
    }

    /// Advances one tracer by `step` in the hole's pull alone, in as many leapfrog sub-steps as
    /// its radius asks for at the start; false once it comes within `swallow`. The Metal run
    /// takes the same steps (`TidalRun`).
    public static func advance(
        _ position: inout SIMD3<Float>, _ velocity: inout SIMD3<Float>, by step: Float,
        swallow: Float
    ) -> Bool {
        let radius = simd_length(position)
        let wanted = step / (subStepAngle * dynamicalTime(radius: radius))
        let count = min(max(Int(wanted.rounded(.up)), 1), maximumSubSteps)
        let h = step / Float(count)
        for _ in 0..<count {
            velocity += acceleration(at: position) * (h / 2)
            position += velocity * h
            if simd_length(position) < swallow { return false }
            velocity += acceleration(at: position) * (h / 2)
        }
        return true
    }

    /// The cloud's centre at one moment of its parabolic orbit.
    public struct Centre: Sendable, Equatable {
        public var time: Double
        public var position: SIMD3<Double>
        public var velocity: SIMD3<Double>
    }

    /// The centre's orbit from beyond `release` to the pericentre, every `spacing` in time, earliest
    /// first. Integrated back from the pericentre, where a parabolic orbit is fixed by its
    /// distance alone: zero energy, so v² = 2 / (r - 1), and no radial motion.
    public func centreTrack(spacing: Double = 0.05) -> [Centre] {
        let rp = Double(pericentre)
        var position = SIMD3<Double>(rp, 0, 0)
        var velocity = SIMD3<Double>(0, (2 / (rp - 1)).squareRoot(), 0)
        var time = 0.0
        var track = [Centre(time: 0, position: position, velocity: velocity)]
        func pull(_ x: SIMD3<Double>) -> SIMD3<Double> {
            let r = simd_length(x)
            return -x / (r * (r - 1) * (r - 1))
        }
        // Fine steps of a fraction of the orbit's own rate, each spacing cut into as many.
        while simd_length(position) < Double(release) * 1.1 {
            let r = simd_length(position)
            let rate = simd_length(velocity) / r
            let count = max(Int((spacing * rate / 0.002).rounded(.up)), 1)
            let h = -spacing / Double(count)
            for _ in 0..<count {
                velocity += pull(position) * (h / 2)
                position += velocity * h
                velocity += pull(position) * (h / 2)
            }
            time -= spacing
            track.append(Centre(time: time, position: position, velocity: velocity))
        }
        return track.reversed()
    }

    /// When the centre stands at `release` on its way in, before the pericentre.
    public func releaseTime(on track: [Centre]) -> Double {
        let r = Double(release)
        guard let index = track.firstIndex(where: { simd_length($0.position) <= r }) else { return 0 }
        guard index > 0 else { return track[0].time }
        let before = track[index - 1]
        let after = track[index]
        let (r0, r1) = (simd_length(before.position), simd_length(after.position))
        let t = (r0 - r) / max(r0 - r1, 1e-12)
        return before.time + (after.time - before.time) * t
    }

    static func float(_ v: SIMD3<Double>) -> SIMD3<Float> {
        SIMD3<Float>(Float(v.x), Float(v.y), Float(v.z))
    }

    /// The centre at `time`, interpolated on `track`.
    public static func centre(at time: Double, on track: [Centre]) -> Centre {
        guard let first = track.first, let last = track.last else {
            return Centre(time: time, position: .zero, velocity: .zero)
        }
        if time <= first.time { return first }
        if time >= last.time { return last }
        let spacing = (last.time - first.time) / Double(track.count - 1)
        let place = (time - first.time) / spacing
        let index = min(Int(place), track.count - 2)
        let t = place - Double(index)
        let (a, b) = (track[index], track[index + 1])
        return Centre(
            time: time, position: a.position + (b.position - a.position) * t,
            velocity: a.velocity + (b.velocity - a.velocity) * t)
    }

    /// Where each tracer stands in the cloud, from its centre: denser in the middle, as
    /// (1 - r² / R²)² falls, so the stream has a spine rather than a uniform ribbon.
    public func cloudOffsets() -> [SIMD3<Float>] {
        var generator = SeededGenerator(seed: seed)
        var offsets: [SIMD3<Float>] = []
        offsets.reserveCapacity(tracers)
        while offsets.count < tracers {
            let point = SIMD3<Float>(
                generator.uniform(in: -1...1), generator.uniform(in: -1...1),
                generator.uniform(in: -1...1))
            let r2 = simd_length_squared(point)
            guard r2 <= 1 else { continue }
            let density = (1 - r2) * (1 - r2)
            guard generator.uniform() < density else { continue }
            offsets.append(point * cloudRadius)
        }
        return offsets
    }

    /// Every tracer at the release: the centre's position plus its own offset, the centre's
    /// velocity. Also the release time.
    public func released() -> (time: Double, positions: [SIMD3<Float>], velocity: SIMD3<Float>) {
        let track = centreTrack()
        let time = releaseTime(on: track)
        let centre = Self.centre(at: time, on: track)
        let at = Self.float(centre.position)
        return (time, cloudOffsets().map { at + $0 }, Self.float(centre.velocity))
    }
}
