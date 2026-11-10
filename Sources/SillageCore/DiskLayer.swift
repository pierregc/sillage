#if canImport(simd)
    import simd
#else
    import Foundation
#endif

/// How far a disk's material stands from its layer: a plane fitted to each ring of the disk,
/// half a scale length wide, out to the disk's edge.
///
/// One plane for the whole disk reads a bent disk as a torn one. A large disk's outskirts warp
/// out of its plane tens of megayears before the pericentre, and its centre is pulled off the
/// plane its rim keeps, while the disk is still thin everywhere and still holds its arms
/// (#210). A plane per ring follows the bend; what stands off it has left the disk, thrown
/// into a tail or stirred into a spheroid.
///
/// Fed twice: every particle once to fit the planes, then each one asked how high it stands.
public struct DiskLayer: Sendable {
    /// Ring width in scale lengths.
    public static let ringWidth: Float = 0.5
    /// A ring with fewer particles than this gets no plane, and its material counts as out.
    static let fewest: Double = 16

    let axis: SIMD3<Float>
    let u: SIMD3<Float>
    let v: SIMD3<Float>
    let width: Float
    let edge: Float
    /// n, x, y, z, xx, xy, yy, xz, yz, zz per ring.
    private var sums: [Double]

    /// `axis` is the plane the rings are laid out in; each ring's own plane is fitted within it.
    public init(axis: SIMD3<Float>, scaleLength: Float, edge: Float) {
        let normal =
            simd_length_squared(axis) > 1e-12 ? simd_normalize(axis) : SIMD3<Float>(0, 0, 1)
        let reference = abs(normal.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
        self.axis = normal
        self.u = simd_normalize(simd_cross(normal, reference))
        self.v = simd_cross(normal, u)
        self.width = max(Self.ringWidth * scaleLength, 1e-3)
        self.edge = max(edge, width)
        self.sums = [Double](repeating: 0, count: Int((self.edge / width).rounded(.up)) * 10)
    }

    var rings: Int { sums.count / 10 }

    /// Where an offset from the galaxy's centre lies in the rings' frame, and in which ring;
    /// nil past the edge.
    func place(_ offset: SIMD3<Float>) -> (x: Double, y: Double, z: Double, ring: Int)? {
        let x = simd_dot(offset, u)
        let y = simd_dot(offset, v)
        let radius = (x * x + y * y).squareRoot()
        guard radius.isFinite, radius < edge else { return nil }
        let ring = min(Int(radius / width), rings - 1)
        return (Double(x), Double(y), Double(simd_dot(offset, axis)), ring)
    }

    public mutating func add(_ offset: SIMD3<Float>) {
        guard let placed = place(offset), placed.z.isFinite else { return }
        let (x, y, z) = (placed.x, placed.y, placed.z)
        let base = placed.ring * 10
        sums[base] += 1
        sums[base + 1] += x
        sums[base + 2] += y
        sums[base + 3] += z
        sums[base + 4] += x * x
        sums[base + 5] += x * y
        sums[base + 6] += y * y
        sums[base + 7] += x * z
        sums[base + 8] += y * z
        sums[base + 9] += z * z
    }

    /// The plane of each ring, z = a x + b y + c by least squares, and the root mean square
    /// height of the material about them.
    public func fitted() -> Fit {
        var planes = [SIMD3<Double>?](repeating: nil, count: rings)
        var residual = 0.0
        var counted = 0.0
        for ring in 0..<rings {
            let s = Array(sums[(ring * 10)..<(ring * 10 + 10)])
            guard s[0] >= Self.fewest else { continue }
            let normal = simd_double3x3(
                rows: [
                    SIMD3(s[4], s[5], s[1]), SIMD3(s[5], s[6], s[2]), SIMD3(s[1], s[2], s[0]),
                ])
            let moments = SIMD3(s[7], s[8], s[3])
            let determinant = normal.determinant
            guard determinant.isFinite, abs(determinant) > 1e-12 else { continue }
            let plane = normal.inverse * moments
            guard plane.x.isFinite, plane.y.isFinite, plane.z.isFinite else { continue }
            planes[ring] = plane
            residual += max(s[9] - simd_dot(plane, moments), 0)
            counted += s[0]
        }
        return Fit(
            layer: self, planes: planes,
            spread: counted > 0 ? Float((residual / counted).squareRoot()) : 0)
    }

    public struct Fit: Sendable {
        let layer: DiskLayer
        let planes: [SIMD3<Double>?]
        /// Root mean square height of the material about its ring's plane, in kpc.
        public let spread: Float

        /// How far an offset from the centre stands from its ring's plane; nil past the edge
        /// or in a ring too sparse to have one.
        public func height(of offset: SIMD3<Float>) -> Float? {
            guard let placed = layer.place(offset), let plane = planes[placed.ring] else {
                return nil
            }
            return Float(placed.z - (plane.x * placed.x + plane.y * placed.y + plane.z))
        }
    }
}
