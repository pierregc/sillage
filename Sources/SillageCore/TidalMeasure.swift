import Foundation

#if canImport(simd)
    import simd
#endif

/// What a run of `TidalDisruption` is read for against published disruptions (#334): how much of
/// it is bound, how far the debris have circularised, how eccentric and how thick the disk is,
/// and where it sits, at one moment, in the units the papers use: the pericentre `R_p` and the
/// Kepler period `P*` of the most bound debris.
public struct TidalMeasure: Sendable {
    public let scene: TidalDisruption
    /// The Kepler period of the most bound tracer, 2π a^3/2 with a = 1 / 2|ε|: the papers' P*,
    /// when the first debris come back.
    public let period: Double
    /// Where a circular orbit has the angular momentum of the cloud's centre, and where the
    /// bound half of the cloud would settle if each kept its own: the mean of theirs.
    public let circularRadius: Float
    public let boundRing: Float
    private var initiallyBound: [Bool] = []
    private var count = 0

    public struct Row: Sendable, Equatable {
        public var time: Double
        /// The time in periods of the most bound debris.
        public var periods: Double
        /// Tracers swallowed, as a share of all.
        public var swallowed: Double
        /// Tracers still out there with a negative energy, as a share of those that are.
        public var bound: Double
        /// The mean over the bound tracers within 6 R_p, the flow, of their energy in that of the
        /// circular orbit with their angular momentum: below 1 on an eccentric orbit, 1 once
        /// they have lost all they could, keeping the angular momentum. Papers' ε / ε_circ.
        public var circularised: Double
        /// The mean eccentricity of the orbits the bound tracers within 6 R_p would have alone.
        public var eccentricity: Double
        /// Within 6 R_p: those on orbits that plunge, as a share.
        public var plunging: Double
        /// The vertical spread over the radius of the bound tracers between 3 and 36 r_s, from the
        /// median of |z| as a Gaussian's.
        public var thickness: Double
        /// The light the tracers give, summed and divided by their number: the gas's heating
        /// rate, as far as the light of a heating lasts, in the scene's units.
        public var heating: Double
        /// The share of the tracers bound at the release that are within 2, 6 and 16 R_p.
        public var within: [Double]
        /// The radius, in r_s, of the first quartile, the median and the last quartile of the
        /// bound tracers within 6 R_p.
        public var radii: [Double]

        public static let header =
            "time,periods,swallowed,bound,circularised,eccentricity,plunging,thickness,heating,in2,in6,in16,r25,r50,r75"

        public var line: String {
            func f(_ x: Double) -> String { String(Float(x)) }
            return
                ([time, periods, swallowed, bound, circularised, eccentricity, plunging, thickness, heating]
                + within + radii).map(f).joined(separator: ",")
        }
    }

    /// Reads the cloud as it stands at the release: its energies set the period.
    public init(
        scene: TidalDisruption, positions: UnsafeBufferPointer<SIMD4<Float>>,
        velocities: UnsafeBufferPointer<SIMD4<Float>>
    ) {
        self.scene = scene
        count = positions.count
        var energies: [Float] = []
        energies.reserveCapacity(count)
        initiallyBound.reserveCapacity(count)
        for index in 0..<count {
            let e = Self.energy(positions[index], velocities[index])
            initiallyBound.append(e < 0)
            if e < 0 { energies.append(e) }
        }
        energies.sort()
        let mostBound = energies.isEmpty ? -0.02 : energies[0]
        period = 2 * .pi * pow(Double(1 / (2 * abs(mostBound))), 1.5)
        let rp = scene.pericentre
        circularRadius = Self.circularRadius(momentum2: rp * rp * 2 / (rp - 1))
        var total: Float = 0
        var boundCount: Float = 0
        for index in 0..<count where initiallyBound[index] {
            let p = positions[index]
            let v = velocities[index]
            let cross = SIMD3<Float>(
                p.y * v.z - p.z * v.y, p.z * v.x - p.x * v.z, p.x * v.y - p.y * v.x)
            total += (cross.x * cross.x + cross.y * cross.y + cross.z * cross.z).squareRoot()
            boundCount += 1
        }
        let mean = boundCount > 0 ? total / boundCount : rp * (2 / (rp - 1)).squareRoot()
        boundRing = Self.circularRadius(momentum2: mean * mean)
    }

    /// The radius of the circular orbit with this squared angular momentum, r³ / (r - 1)²,
    /// in Paczyński and Wiita's potential; its energy is `circularEnergy(radius:)`.
    public static func circularRadius(momentum2: Float) -> Float {
        var low: Float = 3
        var high: Float = 1e6
        for _ in 0..<80 {
            let mid = (low + high) / 2
            if mid * mid * mid / ((mid - 1) * (mid - 1)) < momentum2 { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }

    public static func circularEnergy(radius: Float) -> Float {
        (2 - radius) / (2 * (radius - 1) * (radius - 1))
    }

    /// The tracer's energy in Paczyński and Wiita's potential, per unit mass.
    public static func energy(_ position: SIMD4<Float>, _ velocity: SIMD4<Float>) -> Float {
        let r = (position.x * position.x + position.y * position.y + position.z * position.z).squareRoot()
        let v2 = velocity.x * velocity.x + velocity.y * velocity.y + velocity.z * velocity.z
        return v2 / 2 - 1 / (r - 1)
    }

    /// The radii where a bound orbit of this energy and squared angular momentum turns, from
    /// the tracer's own radius, which lies between them; nil for an orbit that plunges (no inner
    /// turning point above the horizon) or is not bound.
    public static func turningPoints(energy: Float, momentum2: Float, radius: Float) -> (
        pericentre: Float, apocentre: Float
    )? {
        guard energy < 0 else { return nil }
        // Zero where the radial speed is: negative between the turning points.
        func g(_ r: Float) -> Float { momentum2 / (2 * r * r) - 1 / (r - 1) - energy }
        var outer = radius
        var far = false
        while outer < 1e6 {
            if g(outer) > 0 {
                far = true
                break
            }
            outer *= 1.04
        }
        guard far else { return nil }
        var low = outer / 1.04
        var high = outer
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if g(mid) > 0 { high = mid } else { low = mid }
        }
        let apocentre = (low + high) / 2
        var inner = radius
        var barrier = false
        while inner > 1.02 {
            if g(inner) > 0 {
                barrier = true
                break
            }
            inner /= 1.02
        }
        guard barrier else { return nil }
        low = inner
        high = inner * 1.02
        for _ in 0..<40 {
            let mid = (low + high) / 2
            if g(mid) > 0 { low = mid } else { high = mid }
        }
        return ((low + high) / 2, apocentre)
    }

    /// One moment. `stride` reads only every stride-th tracer for what needs a search.
    public func row(
        time: Double, positions: UnsafeBufferPointer<SIMD4<Float>>,
        velocities: UnsafeBufferPointer<SIMD4<Float>>, stride: Int = 1
    ) -> Row {
        precondition(positions.count == count, "a frame of another scene")
        let rp = Double(scene.pericentre)
        let edges = [2 * rp, 6 * rp, 16 * rp]
        var alive = 0
        var bound = 0
        var circularSum = 0.0
        var flow = 0
        var inside = [Int](repeating: 0, count: 3)
        var initialCount = 0
        var eccentricity = 0.0
        var counted = 0
        var plunging = 0
        var heights: [Float] = []
        var flowRadii: [Float] = []
        var light = 0.0
        for index in 0..<count {
            let v = velocities[index]
            let wasBound = initiallyBound[index]
            if wasBound { initialCount += 1 }
            if v.w < 0 { continue }
            alive += 1
            let p = positions[index]
            light += Double(p.w)
            let e = Self.energy(p, v)
            guard e < 0 else { continue }
            bound += 1
            let r = Double((p.x * p.x + p.y * p.y + p.z * p.z).squareRoot())
            if wasBound {
                for k in 0..<3 where r < edges[k] { inside[k] += 1 }
            }
            guard index % stride == 0 else { continue }
            let rho = (p.x * p.x + p.y * p.y).squareRoot()
            if rho > 3, rho < 36 { heights.append(abs(p.z) / rho) }
            guard r < 6 * rp else { continue }
            counted += 1
            flow += 1
            flowRadii.append(Float(r))
            let l = SIMD3<Float>(p.x, p.y, p.z)
            let u = SIMD3<Float>(v.x, v.y, v.z)
            let cross = SIMD3<Float>(
                l.y * u.z - l.z * u.y, l.z * u.x - l.x * u.z, l.x * u.y - l.y * u.x)
            let j2 = cross.x * cross.x + cross.y * cross.y + cross.z * cross.z
            let circle = Self.circularEnergy(radius: Self.circularRadius(momentum2: j2))
            circularSum += Double(min(e / circle, 1.5))
            if let turns = Self.turningPoints(energy: e, momentum2: j2, radius: Float(r)) {
                eccentricity += Double(
                    (turns.apocentre - turns.pericentre) / (turns.apocentre + turns.pericentre))
            } else {
                plunging += 1
            }
        }
        heights.sort()
        flowRadii.sort()
        let radii = [0.25, 0.5, 0.75].map { share in
            flowRadii.isEmpty
                ? 0 : Double(flowRadii[min(Int(share * Double(flowRadii.count)), flowRadii.count - 1)])
        }
        let thickness = heights.isEmpty ? 0 : Double(heights[heights.count / 2]) / 0.6745
        let regular = counted - plunging
        return Row(
            time: time, periods: time / period,
            swallowed: Double(count - alive) / Double(max(count, 1)),
            bound: alive > 0 ? Double(bound) / Double(alive) : 0,
            circularised: flow > 0 ? circularSum / Double(flow) : 0,
            eccentricity: regular > 0 ? eccentricity / Double(regular) : 0,
            plunging: counted > 0 ? Double(plunging) / Double(counted) : 0,
            thickness: thickness, heating: light / Double(max(count, 1)),
            within: inside.map { Double($0) / Double(max(initialCount, 1)) }, radii: radii)
    }
}
