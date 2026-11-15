import Foundation

#if canImport(simd)
    import simd
#endif

/// Where a Schwarzschild hole shows a point (#314), for a camera at one distance from it.
///
/// Every image of a point lies in the plane of the hole, the camera and the point, at an angle α
/// from the hole as the camera sees it, and depends only on the point's distance r from the hole
/// and on the angle φ at the hole between the point and the camera. So one table per camera
/// distance serves every particle seen from every direction, and the particle pass draws each
/// particle once per image at the α it looks up: that is the whole of the lensing.
///
/// Image 0 is the direct one. Image 1 goes round the far side of the hole and shows on the other
/// side of it; image 2 goes round once more, in the thin ring that hugs the shadow. Built by
/// tracing light back from the camera: in the coordinates r and φ drawn on a flat plane, a ray of
/// light is the path of a particle pulled by -3/2 h² x / r⁵, h its angular momentum, which is
/// Binet's equation for light, u'' + u = 3u²/2 with r_s = 1. A ray crosses each half-line from
/// the hole at most once, at a radius that grows with α, so for each φ the table inverts r(α) by
/// interpolating between neighbouring rays.
public struct HoleLens: Sendable {
    public let cameraDistance: Float
    public let minimumRadius: Float
    public let maximumRadius: Float
    public let radiusCount: Int
    /// Angles φ at the cells' centres, (j + ½) π / angleCount, so neither axis is ever sampled.
    public let angleCount: Int
    public let images: Int
    /// For each image, row by radius and then by angle: α; the direction light leaves the point
    /// in towards the camera, outward and along the image's sweep, in the frame of an observer
    /// standing still there; and how much brighter the point shows than it would without the
    /// hole. Zero weight where the table has no image.
    public let entries: [SIMD4<Float>]

    /// The angle from the hole within which nothing from behind it can be seen.
    public var shadowAngle: Float {
        let b = 1.5 * 3.0.squareRoot()
        let ro = Double(cameraDistance)
        return Float(asin(b * (1 - 1 / ro).squareRoot() / ro))
    }

    public init(
        cameraDistance: Float, minimumRadius: Float = 1.2, maximumRadius: Float = 5000,
        radiusCount: Int = 512, angleCount: Int = 512, images: Int = 3,
        uniformRays: Int = 8000, criticalRays: Int = 13000, accuracy: Double = 0.003
    ) {
        self.cameraDistance = cameraDistance
        self.minimumRadius = minimumRadius
        self.maximumRadius = maximumRadius
        self.radiusCount = radiusCount
        self.angleCount = angleCount
        self.images = images
        let ro = Double(cameraDistance)
        let rays = Self.rayAngles(cameraDistance: ro, uniform: uniformRays, critical: criticalRays)
        var table = Table(
            cameraDistance: ro, minimumRadius: Double(minimumRadius),
            maximumRadius: Double(maximumRadius), radiusCount: radiusCount, angleCount: angleCount,
            images: images)
        // In batches of rays in order of α, so that only the crossings of one batch are ever
        // held: each column keeps the last ray it took and fills the rows between it and the next.
        let batch = 1024
        for start in Swift.stride(from: 0, to: rays.count, by: batch) {
            let part = Array(rays[start..<min(start + batch, rays.count)])
            let crossings = Self.trace(
                part, cameraDistance: ro, stop: Double(minimumRadius) * 0.98,
                escape: Double(maximumRadius) * 1.02, sweeps: table.sweeps, angleCount: angleCount,
                accuracy: accuracy)
            table.take(crossings, rays: part)
        }
        entries = table.entries
    }

    /// The angle a point at `angle` from the camera's direction, `radius` from the hole, would
    /// show at without the hole.
    public func straightAngle(radius: Float, angle: Float) -> Float {
        atan2(radius * sin(angle), cameraDistance - radius * cos(angle))
    }

    /// The entry for `image` at `radius` and `angle`, read as the shader reads it: bilinear
    /// between the four cells around it, clamped at the table's edges, and no image at all
    /// where one of the four has none, rather than an α half way to zero.
    public func lookup(image: Int, radius: Float, angle: Float) -> SIMD4<Float> {
        let (column, row) = cell(radius: radius, angle: angle)
        let j0 = Int(column.rounded(.down))
        let i0 = Int(row.rounded(.down))
        let (tj, ti) = (column - Float(j0), row - Float(i0))
        let base = image * radiusCount * angleCount
        func entry(_ i: Int, _ j: Int) -> SIMD4<Float> {
            entries[base + min(max(i, 0), radiusCount - 1) * angleCount + min(max(j, 0), angleCount - 1)]
        }
        let corners = [entry(i0, j0), entry(i0, j0 + 1), entry(i0 + 1, j0), entry(i0 + 1, j0 + 1)]
        guard corners.allSatisfy({ $0.w > 0 }) else { return .zero }
        let low = corners[0] * (1 - tj) + corners[1] * tj
        let high = corners[2] * (1 - tj) + corners[3] * tj
        return low * (1 - ti) + high * ti
    }

    /// Where `radius` and `angle` fall in the table, in cells, clamped to its range.
    public func cell(radius: Float, angle: Float) -> (column: Float, row: Float) {
        let column = min(max(angle / .pi * Float(angleCount) - 0.5, 0), Float(angleCount - 1))
        let span = log(maximumRadius / minimumRadius)
        let row = log(max(radius, minimumRadius) / minimumRadius) / span * Float(radiusCount - 1)
        return (column, min(max(row, 0), Float(radiusCount - 1)))
    }

    /// The rays traced back from the camera, by their angle from the hole at the camera: evenly
    /// over the half turn, and gathered either side of the shadow's edge, where images 1 and 2
    /// lie within a hair of each other.
    static func rayAngles(cameraDistance ro: Double, uniform: Int, critical: Int) -> [Double] {
        let bc = 1.5 * 3.0.squareRoot()
        let scale = (1 - 1 / ro).squareRoot() / ro
        var angles = (0..<uniform).map { (Double($0) + 0.5) * .pi / Double(uniform) }
        for side in [-1.0, 1.0] {
            for k in 0..<critical {
                let s = 0.1 + 11.9 * Double(k) / Double(max(critical - 1, 1))
                let b = bc * (1 + side * exp(-s))
                angles.append(asin(min(b * scale, 1)))
            }
        }
        angles.sort()
        var kept: [Double] = []
        for angle in angles where kept.last.map({ angle - $0 > 1e-14 }) ?? true { kept.append(angle) }
        return kept
    }

    /// Where a ray crosses one sweep angle: the radius, and the direction light leaves in
    /// towards the camera there, outward and along the sweep, as an observer standing still sees it.
    struct Crossing {
        var radius: Double
        var direction: SIMD2<Float>
        static let none = Crossing(radius: .nan, direction: .zero)
    }

    /// For each ray and each sweep angle (m + ½) π / angleCount, where the ray crosses it, or
    /// `none` where it never does.
    static func trace(
        _ rays: [Double], cameraDistance ro: Double, stop: Double, escape: Double, sweeps: Int,
        angleCount: Int, accuracy: Double
    ) -> [Crossing] {
        var crossings = [Crossing](repeating: .none, count: rays.count * sweeps)
        let redshift = (1 - 1 / ro).squareRoot()
        let step = Double.pi / Double(angleCount)
        crossings.withUnsafeMutableBufferPointer { out in
            concurrentPerform(iterations: rays.count) { k in
                // The ray leaves at α from the inward radial as the camera measures it; on the
                // flat plane of r and φ the radial length is stretched by 1 / √(1 - 1/r).
                let alpha = rays[k]
                let zeta = atan2(sin(alpha), cos(alpha) * redshift)
                var x = SIMD2<Double>(ro, 0)
                var v = SIMD2<Double>(-cos(zeta), sin(zeta))
                let h = x.x * v.y - x.y * v.x
                let pull = -1.5 * h * h
                func acceleration(_ p: SIMD2<Double>) -> SIMD2<Double> {
                    let r2 = simd_length_squared(p)
                    return p * (pull / (r2 * r2 * r2.squareRoot()))
                }
                var azimuth = 0.0
                var next = 0
                let limit = (Double(sweeps) + 0.5) * step
                for _ in 0..<1_000_000 {
                    let r = simd_length(x)
                    let dl = accuracy * r / max(simd_length(v), 1e-9)
                    let a1 = acceleration(x)
                    let (x2, v2) = (x + v * (dl / 2), v + a1 * (dl / 2))
                    let a2 = acceleration(x2)
                    let (x3, v3) = (x + v2 * (dl / 2), v + a2 * (dl / 2))
                    let a3 = acceleration(x3)
                    let (x4, v4) = (x + v3 * dl, v + a3 * dl)
                    let a4 = acceleration(x4)
                    let drift: SIMD2<Double> = v + v4 + (v2 + v3) * 2
                    let kick: SIMD2<Double> = a1 + a4 + (a2 + a3) * 2
                    let xn = x + drift * (dl / 6)
                    let vn = v + kick * (dl / 6)
                    var turn = atan2(xn.y, xn.x) - atan2(x.y, x.x)
                    if turn > .pi { turn -= 2 * .pi }
                    if turn < -.pi { turn += 2 * .pi }
                    let reached = azimuth + turn
                    while next < sweeps, (Double(next) + 0.5) * step <= reached {
                        let t = ((Double(next) + 0.5) * step - azimuth) / max(turn, 1e-300)
                        let at = x + (xn - x) * t
                        let radius = simd_length(at)
                        let tangent = simd_normalize(v + (vn - v) * t)
                        let outward = at / radius
                        let along = SIMD2<Double>(-outward.y, outward.x)
                        let lr = -simd_dot(tangent, outward) / (1 - 1 / max(radius, 1.0001)).squareRoot()
                        let lphi = -simd_dot(tangent, along)
                        let norm = (lr * lr + lphi * lphi).squareRoot()
                        out[k * sweeps + next] = Crossing(
                            radius: radius, direction: SIMD2<Float>(Float(lr / norm), Float(lphi / norm)))
                        next += 1
                    }
                    x = xn
                    v = vn
                    azimuth = reached
                    let rn = simd_length(x)
                    if rn < stop || azimuth > limit || (rn > escape && simd_dot(x, v) > 0) { break }
                }
            }
        }
        return crossings
    }

    /// The tables being filled, one batch of rays at a time.
    struct Table {
        let cameraDistance: Double
        let minimumRadius: Double
        let span: Double
        let radiusCount: Int
        let angleCount: Int
        let images: Int
        var sweeps: Int { images * angleCount }
        var entries: [SIMD4<Float>]
        /// The last ray each sweep took, its α and where it crossed.
        var last: [(alpha: Double, crossing: Crossing)?]
        static let maximumWeight: Double = 50

        init(
            cameraDistance: Double, minimumRadius: Double, maximumRadius: Double, radiusCount: Int,
            angleCount: Int, images: Int
        ) {
            self.cameraDistance = cameraDistance
            self.minimumRadius = minimumRadius
            self.span = log(maximumRadius / minimumRadius)
            self.radiusCount = radiusCount
            self.angleCount = angleCount
            self.images = images
            entries = [SIMD4<Float>](repeating: .zero, count: images * radiusCount * angleCount)
            last = Array(repeating: nil, count: images * angleCount)
        }

        /// For each column, the rays of a batch that cross its sweep, in order of α: each one
        /// whose radius rises past the last one taken fills the rows between the two. A ray
        /// whose radius does not rise is a fold, or a neighbour too close to tell apart, and is
        /// passed over.
        mutating func take(_ crossings: [Crossing], rays: [Double]) {
            let sweeps = self.sweeps
            let table = self
            entries.withUnsafeMutableBufferPointer { out in
                last.withUnsafeMutableBufferPointer { last in
                    concurrentPerform(iterations: table.images * table.angleCount) { task in
                        let image = task / table.angleCount
                        let j = task % table.angleCount
                        // Image 1 sweeps the other way round: its φ is 2π less its sweep.
                        let sweep =
                            image.isMultiple(of: 2)
                            ? image * table.angleCount + j : (image + 1) * table.angleCount - 1 - j
                        for k in rays.indices {
                            let c = crossings[k * sweeps + sweep]
                            guard !c.radius.isNaN else { continue }
                            if let previous = last[sweep] {
                                guard c.radius > previous.crossing.radius else { continue }
                                table.fill(
                                    &out, image: image, column: j, from: previous,
                                    to: (rays[k], c))
                            }
                            last[sweep] = (rays[k], c)
                        }
                    }
                }
            }
        }

        /// The rows whose radius lies between two neighbouring rays' crossings: α and the light's
        /// direction interpolated in log r, and the weight from how fast the radius runs with α.
        func fill(
            _ out: inout UnsafeMutableBufferPointer<SIMD4<Float>>, image: Int, column j: Int,
            from a: (alpha: Double, crossing: Crossing), to b: (alpha: Double, crossing: Crossing)
        ) {
            let (ra, rb) = (a.crossing.radius, b.crossing.radius)
            let scale = Double(radiusCount - 1) / span
            let first = max(Int((log(ra / minimumRadius) * scale).rounded(.down)) + 1, 0)
            let final = min(Int((log(rb / minimumRadius) * scale).rounded(.down)), radiusCount - 1)
            guard first <= final else { return }
            let phi = (Double(j) + 0.5) * .pi / Double(angleCount)
            let ro = cameraDistance
            let slope = (rb - ra) / max(b.alpha - a.alpha, 1e-300)
            let da = SIMD2<Double>(Double(a.crossing.direction.x), Double(a.crossing.direction.y))
            let db = SIMD2<Double>(Double(b.crossing.direction.x), Double(b.crossing.direction.y))
            for i in first...final {
                let r = minimumRadius * exp(Double(i) / scale)
                let t = log(r / ra) / log(rb / ra)
                let alpha = a.alpha + (b.alpha - a.alpha) * t
                let direction = simd_normalize(da + (db - da) * t)
                // The rays the camera sees in a small solid angle reach the point as a bundle
                // dr/dα times the ray's slant across the half-line wide, and r sin φ round the
                // axis. Against the same bundle without the hole, that is how magnified the
                // point is, and by surface brightness how much brighter.
                let stretch2 = 1 - 1 / r
                let slant =
                    abs(direction.y)
                    / (direction.x * direction.x * stretch2 + direction.y * direction.y).squareRoot()
                let straight2 = ro * ro + r * r - 2 * ro * r * cos(phi)
                let weight = straight2 * sin(alpha) / max(slope * slant * r * sin(phi), 1e-300)
                out[(image * radiusCount + i) * angleCount + j] = SIMD4<Float>(
                    Float(alpha), Float(direction.x), Float(direction.y),
                    Float(min(weight, Self.maximumWeight)))
            }
        }
    }
}
