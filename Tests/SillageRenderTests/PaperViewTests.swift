import Foundation
import Testing

@testable import SillageCore
@testable import SillageRender

#if canImport(simd)
    import simd
#endif

/// A paper's viewing rotation against `match`'s camera (#523). Karl et al. 2010 and Privon et al.
/// 2013 turn the simulation about x, then y, then z, and project on (x', y'). Both draw their sky
/// panels with x' to the right (west on a north-up picture) and y' up, so z' is towards the
/// viewer: the `sky` reading. The `mirror` reading takes x' as east, to the left, and z' away.
/// `view.json` lists the elevation, azimuth and roll each reading gives, which must draw a lopsided
/// set of points as that projection does, and not its mirror.
@Suite("A paper's view as the match's camera")
struct PaperViewTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Rz Ry Rx, by hand.
    static func rotation(_ x: Double, _ y: Double, _ z: Double) -> [[Double]] {
        let (a, b, c) = (x * .pi / 180, y * .pi / 180, z * .pi / 180)
        let rx = [[1, 0, 0], [0, cos(a), -sin(a)], [0, sin(a), cos(a)]]
        let ry = [[cos(b), 0, sin(b)], [0, 1, 0], [-sin(b), 0, cos(b)]]
        let rz = [[cos(c), -sin(c), 0], [sin(c), cos(c), 0], [0, 0, 1]]
        return times(rz, times(ry, rx))
    }

    static func times(_ p: [[Double]], _ q: [[Double]]) -> [[Double]] {
        (0..<3).map { r in
            (0..<3).map { k in (0..<3).reduce(0.0) { (sum: Double, j: Int) in sum + p[r][j] * q[j][k] } }
        }
    }

    /// An L on the orbit plane with a mast off it: no rotation or mirror maps it onto itself.
    static let points: [SIMD3<Float>] = [
        SIMD3(0, 0, 0), SIMD3(3, 0, 0), SIMD3(0, 1.5, 0), SIMD3(0.4, 0.2, 2.2), SIMD3(-1, -0.7, 0.3),
    ]

    /// Where the paper draws a point, in the match's picture frame: x right, y down.
    static func paper(_ point: SIMD3<Float>, _ m: [[Double]], sky: String) -> SIMD2<Double> {
        let p = SIMD3<Double>(point)
        let x = m[0][0] * p.x + m[0][1] * p.y + m[0][2] * p.z
        let y = m[1][0] * p.x + m[1][1] * p.y + m[1][2] * p.z
        return sky == "mirror" ? SIMD2(-x, -y) : SIMD2(x, -y)
    }

    static func spread(_ a: [SIMD2<Double>], _ b: [SIMD2<Double>]) -> Double {
        zip(a, b).map { simd_length($0 - $1) }.max() ?? .infinity
    }

    @Test func theViewsOnFileDrawThePapersPicture() throws {
        for model in ["karl", "privon"] {
            let url = Self.root.appendingPathComponent("references/antennae/\(model)/view.json")
            let file = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
            let angles = file["paperAngles"] as? [Double] ?? []
            #expect(angles.count == 3)
            guard angles.count == 3 else { continue }
            // The paper's x is Sillage's pericentre line turned by `turn` about z.
            let turn = file["turn"] as? Double ?? .nan
            let m = Self.times(Self.rotation(angles[0], angles[1], angles[2]), Self.rotation(0, 0, -turn))
            var drawn: [String: [SIMD2<Double>]] = [:]
            for sky in ["sky", "mirror"] {
                let v = file[sky] as? [String: Double] ?? [:]
                let view = PhotoMatch.View(
                    elevation: v["elevation"] ?? .nan, azimuth: v["azimuth"] ?? .nan, roll: v["roll"] ?? .nan,
                    kpcPerWidth: 1, origin: .zero)
                let camera = Self.points.map(view.place)
                drawn[sky] = camera
                let expected = Self.points.map { Self.paper($0, m, sky: sky) }
                #expect(
                    Self.spread(camera, expected) < 1e-3,
                    "\(model), \(sky): the camera draws the paper's picture")
            }
            // The two readings are mirrors, so they must not agree.
            let sky = Self.points.map { Self.paper($0, m, sky: "sky") }
            #expect(
                Self.spread(drawn["mirror"] ?? [], sky) > 0.5, "\(model): the mirror is not the sky's picture"
            )
        }
    }

    /// The rotation's order and sense on a case worked by hand: 90 degrees about x takes y to z,
    /// then 90 about z takes x to y. A point on +y ends on +z, one on +x on +y.
    @Test func rotationOrder() {
        let m = Self.rotation(90, 0, 90)
        let y = (0..<3).map { m[$0][1] }
        let x = (0..<3).map { m[$0][0] }
        #expect(abs(y[2] - 1) < 1e-12)
        #expect(abs(x[1] - 1) < 1e-12)
    }
}
