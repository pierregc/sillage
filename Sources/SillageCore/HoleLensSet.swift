import Foundation

#if canImport(simd)
    import simd
#endif

/// Lens tables over camera distances (#333), so that a camera can come in and go away: the
/// distances lie a fixed ratio apart, each table is built the first time a camera comes near
/// it, and a camera between two reads both and blends them.
///
/// The blend is not of α itself. The direct image interpolates its bend, α less the angle the
/// point would show at without the hole, and adds back the straight angle at the camera's own
/// distance, so a point that the camera passes by moves exactly as it should and only the
/// small bend is interpolated. The images that go round the hole interpolate the light's
/// impact parameter, b = r_o sin α / √(1 - 1/r_o), which hardly changes with the camera's
/// distance and is 3√3/2 at the shadow's edge whatever it is: the photon ring stays on the edge.
public final class HoleLensSet: @unchecked Sendable {
    /// Between neighbouring distances.
    public let ratio: Float
    /// The camera comes no nearer than this: inside the photon sphere, at 1.5, the tables'
    /// geometry no longer holds.
    public let nearest: Float
    /// Tables kept built, the least recently used dropped first.
    public let capacity: Int
    let make: @Sendable (Float) -> HoleLens
    private var tables: [Int: HoleLens] = [:]
    private var used: [Int] = []
    private let lock = NSLock()

    public init(
        ratio: Float = 1.1, nearest: Float = 2, capacity: Int = 12,
        make: @escaping @Sendable (Float) -> HoleLens = { HoleLens(cameraDistance: $0) }
    ) {
        self.ratio = ratio
        self.nearest = nearest
        self.capacity = max(capacity, 2)
        self.make = make
    }

    /// The distance of table `level`: ratio^level, so every set with the same ratio shares them.
    public func distance(ofLevel level: Int) -> Float { pow(ratio, Float(level)) }

    /// The two tables round `distance`, the share of the far one, and the distance as used.
    public func pair(at distance: Float) -> (near: HoleLens, far: HoleLens, blend: Float, distance: Float) {
        let ro = max(distance, nearest)
        let position = log(ro) / log(ratio)
        let level = Int(position.rounded(.down))
        let blend = position - Float(level)
        let near = table(level)
        // On a table's own distance the other is not needed, and not built.
        guard blend >= 1e-4 else { return (near, near, 0, ro) }
        return (near, table(level + 1), blend, ro)
    }

    /// The tables built, by distance.
    public var built: [Float] {
        lock.lock()
        defer { lock.unlock() }
        return tables.keys.sorted().map(distance(ofLevel:))
    }

    func table(_ level: Int) -> HoleLens {
        lock.lock()
        if let table = tables[level] {
            used.removeAll { $0 == level }
            used.append(level)
            lock.unlock()
            return table
        }
        lock.unlock()
        let table = make(distance(ofLevel: level))
        lock.lock()
        defer { lock.unlock() }
        tables[level] = table
        used.removeAll { $0 == level }
        used.append(level)
        while used.count > capacity { tables[used.removeFirst()] = nil }
        return table
    }

    /// The entry for `image` of a point at `radius` and `angle`, seen from `distance`, as the
    /// shader blends it.
    public func lookup(image: Int, radius: Float, angle: Float, distance: Float) -> SIMD4<Float> {
        let (near, far, blend, ro) = pair(at: distance)
        return Self.blend(
            near.lookup(image: image, radius: radius, angle: angle),
            far.lookup(image: image, radius: radius, angle: angle),
            distances: SIMD2(near.cameraDistance, far.cameraDistance), blend: blend, distance: ro,
            image: image, radius: radius, angle: angle)
    }

    /// Two tables' entries for a point blended for a camera at `distance` between theirs. An
    /// image only one of them has fades in with that table's share, so that it appears and
    /// leaves smoothly as the camera moves.
    public static func blend(
        _ a: SIMD4<Float>, _ b: SIMD4<Float>, distances: SIMD2<Float>, blend t: Float, distance ro: Float,
        image: Int, radius r: Float, angle phi: Float
    ) -> SIMD4<Float> {
        let (hasA, hasB) = (a.w > 0 && t < 1, b.w > 0 && t > 0)
        guard hasA || hasB else { return .zero }
        func along(_ entry: SIMD4<Float>, _ distance: Float) -> Float {
            image == 0
                ? entry.x - HoleLens.straightAngle(radius: r, angle: phi, cameraDistance: distance)
                : sin(entry.x) * distance / (1 - 1 / distance).squareRoot()
        }
        let (q, direction, weight): (Float, SIMD2<Float>, Float)
        if hasA && hasB {
            q = along(a, distances.x) * (1 - t) + along(b, distances.y) * t
            let mixed = SIMD2(a.y, a.z) * (1 - t) + SIMD2(b.y, b.z) * t
            direction = mixed / max(simd_length(mixed), 1e-12)
            weight = a.w * (1 - t) + b.w * t
        } else if hasA {
            (q, direction, weight) = (along(a, distances.x), SIMD2(a.y, a.z), a.w * (1 - t))
        } else {
            (q, direction, weight) = (along(b, distances.y), SIMD2(b.y, b.z), b.w * t)
        }
        let alpha =
            image == 0
            ? q + HoleLens.straightAngle(radius: r, angle: phi, cameraDistance: ro)
            : asin(min(max(q * (1 - 1 / ro).squareRoot() / ro, 0), 1))
        return SIMD4(alpha, direction.x, direction.y, weight)
    }
}
