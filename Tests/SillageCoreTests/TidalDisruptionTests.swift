import Foundation
import Testing

@testable import SillageCore

#if canImport(simd)
    import simd
#endif

@Suite("Tidal disruption")
struct TidalDisruptionTests {
    @Test func aCircularOrbitPastTheLastStableOneStaysCircular() {
        let radius: Float = 4
        var position = SIMD3<Float>(radius, 0, 0)
        var velocity = SIMD3<Float>(0, TidalDisruption.circularSpeed(radius: radius), 0)
        let steps = Int(10 * TidalDisruption.orbitalPeriod(radius: radius) / 0.25)
        for _ in 0..<steps {
            #expect(TidalDisruption.advance(&position, &velocity, by: 0.25, swallow: 1.5))
        }
        #expect(abs(simd_length(position) / radius - 1) < 0.005)
    }

    /// The precession that makes the stream cross itself, against the same orbit's by quadrature:
    /// 2 ∫ ℓ / (r² √(2(E - Φ) - ℓ²/r²)) dr from pericentre to apocentre, less a turn.
    @Test func anEccentricOrbitPrecessesAsThePotentialHasIt() {
        let (rp, ra): (Double, Double) = (8, 30)
        func phi(_ r: Double) -> Double { -1 / (r - 1) }
        let l2 = 2 * (phi(ra) - phi(rp)) / (1 / (rp * rp) - 1 / (ra * ra))
        let energy = l2 / (2 * ra * ra) + phi(ra)
        // r = c - d cos θ takes the square root's zeros at the ends out of the integrand.
        let (c, d) = ((ra + rp) / 2, (ra - rp) / 2)
        var sweep = 0.0
        let n = 200_000
        for k in 0..<n {
            let theta = (Double(k) + 0.5) * .pi / Double(n)
            let r = c - d * cos(theta)
            let radial = 2 * (energy - phi(r)) - l2 / (r * r)
            sweep += l2.squareRoot() / (r * r) / radial.squareRoot() * d * sin(theta) * .pi / Double(n)
        }
        let expected = 2 * sweep - 2 * .pi

        // Measured between pericentres, where the radius turns sharply: at apocentre it changes
        // too slowly for a float to tell one step from the next.
        var position = SIMD3<Float>(Float(ra), 0, 0)
        var velocity = SIMD3<Float>(0, Float(l2.squareRoot() / ra), 0)
        var pericentres: [Double] = []
        var (before, now) = (Float(ra), Float(ra))
        var turned = 0.0
        var last = 0.0
        for _ in 0..<40_000 {
            _ = TidalDisruption.advance(&position, &velocity, by: 0.05, swallow: 1.5)
            let angle = atan2(Double(position.y), Double(position.x))
            var turn = angle - last
            if turn < -.pi { turn += 2 * .pi }
            turned += turn
            last = angle
            let next = simd_length(position)
            if now < before, now < next { pericentres.append(turned) }
            (before, now) = (now, next)
        }
        #expect(pericentres.count >= 3)
        let measured = (pericentres[2] - pericentres[1]) - 2 * .pi
        #expect(expected > 0.6, "about 36° a turn at a pericentre of 8")
        #expect(abs(measured - expected) < 0.01 * expected, "\(measured) against \(expected)")
    }

    @Test func theCentreFallsInOnAParabolaToItsPericentre() {
        var scene = TidalDisruption()
        scene.pericentre = 7
        scene.release = 12
        let track = scene.centreTrack()
        let closest = track.map { simd_length($0.position) }.min() ?? 0
        #expect(abs(closest - 7) < 1e-9)
        #expect(track.last?.time == 0)
        for centre in track {
            let r = simd_length(centre.position)
            let energy = simd_length_squared(centre.velocity) / 2 - 1 / (r - 1)
            #expect(abs(energy) < 1e-6)
        }
        let release = scene.releaseTime(on: track)
        #expect(release < 0)
        let there = TidalDisruption.centre(at: release, on: track)
        #expect(abs(simd_length(there.position) - 12) < 0.01)
    }

    @Test func theCloudIsTheSameForASeedAndStaysInsideItsRadius() {
        var scene = TidalDisruption()
        scene.tracers = 5000
        scene.cloudRadius = 2
        let offsets = scene.cloudOffsets()
        #expect(offsets.count == 5000)
        #expect(offsets.allSatisfy { simd_length($0) <= 2 })
        #expect(offsets == scene.cloudOffsets())
        scene.seed = 2
        #expect(offsets != scene.cloudOffsets())
        // Denser in the middle: half the tracers within a radius well under the uniform 0.79.
        let median = offsets.map { simd_length($0) / 2 }.sorted()[2500]
        #expect(median < 0.6)
    }

    @Test func aTracerFallingStraightInIsSwallowed() {
        var position = SIMD3<Float>(5, 0, 0)
        var velocity = SIMD3<Float>.zero
        var swallowed = false
        for _ in 0..<1000 where !swallowed {
            swallowed = !TidalDisruption.advance(&position, &velocity, by: 0.25, swallow: 1.5)
        }
        #expect(swallowed)
        #expect(simd_length(position) < 1.5)
    }
}

@Suite("Hole lens")
struct HoleLensTests {
    static let lens = HoleLens(
        cameraDistance: 50, radiusCount: 128, angleCount: 128, uniformRays: 3000, criticalRays: 3000)

    @Test func theShadowsEdgeIsTheCriticalRay() {
        let b = 1.5 * Float(3).squareRoot()
        let edge = asin(b * (1 - Float(1) / 50).squareRoot() / 50)
        #expect(abs(Self.lens.shadowAngle - edge) < 1e-6)
        // Nothing from behind the hole shows inside it, and the further images hug it.
        for angle in stride(from: Float(1.8), through: 3.1, by: 0.2) {
            for radius: Float in [2.5, 4, 8, 16, 40] {
                let direct = Self.lens.lookup(image: 0, radius: radius, angle: angle)
                let behind = Self.lens.lookup(image: 1, radius: radius, angle: angle)
                let ring = Self.lens.lookup(image: 2, radius: radius, angle: angle)
                #expect(direct.w > 0 && behind.w > 0 && ring.w > 0, "\(radius) \(angle)")
                #expect(direct.x > Self.lens.shadowAngle)
                #expect(behind.x > Self.lens.shadowAngle)
                #expect(ring.x > Self.lens.shadowAngle)
                #expect(ring.x - Self.lens.shadowAngle < behind.x - Self.lens.shadowAngle)
                #expect(ring.w < behind.w)
            }
        }
    }

    @Test func farFromTheHoleAPointShowsWhereItIs() {
        // Off to the side and well out, the bend is Einstein's 2 r_s / b, small, and nothing
        // is magnified.
        for radius: Float in [30, 45] {
            let angle: Float = 1.2
            let direct = Self.lens.lookup(image: 0, radius: radius, angle: angle)
            let straight = Self.lens.straightAngle(radius: radius, angle: angle)
            #expect(direct.x > straight)
            #expect(direct.x - straight < 0.05 * straight)
            #expect(abs(direct.w - 1) < 0.05)
        }
    }

    @Test func aPointFarBehindTheHoleMakesAnEinsteinRing() {
        let lens = HoleLens(
            cameraDistance: 400, maximumRadius: 1200, radiusCount: 128, angleCount: 256, images: 2,
            uniformRays: 4000, criticalRays: 1000)
        // Weak field: θ_E² = 2 r_s D_ls / (D_l D_s), here 2 × 800 / (400 × 1200), and a source β
        // off the axis shows at (β ± √(β² + 4θ_E²)) / 2, magnified by ½ ± (u² + 2) / (2u √(u² + 4)),
        // u = β / θ_E.
        let einstein = (Float(2 * 800) / Float(400 * 1200)).squareRoot()
        let angle = Float.pi * (1 - 0.5 / 256)
        let beta = lens.straightAngle(radius: 800, angle: angle)
        let root = (beta * beta + 4 * einstein * einstein).squareRoot()
        let u = beta / einstein
        let magnified = (u * u + 2) / (2 * u * (u * u + 4).squareRoot())
        let direct = lens.lookup(image: 0, radius: 800, angle: angle)
        let behind = lens.lookup(image: 1, radius: 800, angle: angle)
        #expect(abs(direct.x / ((beta + root) / 2) - 1) < 0.04, "\(direct.x)")
        #expect(abs(behind.x / ((root - beta) / 2) - 1) < 0.04, "\(behind.x)")
        #expect(abs(direct.w / (magnified + 0.5) - 1) < 0.05, "\(direct.w)")
        #expect(abs(behind.w / (magnified - 0.5) - 1) < 0.05, "\(behind.w)")
    }
}
