import Foundation
import Testing

@testable import SillageCore

#if canImport(simd)
    import simd
#endif

@Suite("Tidal measure")
struct TidalMeasureTests {
    /// A tracer on a circular orbit at `radius`, at `angle`, `height` over the plane.
    static func circular(radius: Float, angle: Float, height: Float = 0) -> (SIMD4<Float>, SIMD4<Float>) {
        let speed = TidalDisruption.circularSpeed(radius: radius)
        return (
            SIMD4(radius * cos(angle), radius * sin(angle), height, 0),
            SIMD4(-speed * sin(angle), speed * cos(angle), 0, 1)
        )
    }

    static func measure(_ tracers: [(SIMD4<Float>, SIMD4<Float>)], scene: TidalDisruption = TidalDisruption())
        -> (TidalMeasure, [SIMD4<Float>], [SIMD4<Float>])
    {
        let positions = tracers.map(\.0)
        let velocities = tracers.map(\.1)
        let measure = positions.withUnsafeBufferPointer { p in
            velocities.withUnsafeBufferPointer { TidalMeasure(scene: scene, positions: p, velocities: $0) }
        }
        return (measure, positions, velocities)
    }

    @Test func theCircularOrbitOfTheCloudsMomentumIsAtTwicePericentre() {
        let (measure, _, _) = Self.measure([Self.circular(radius: 12, angle: 0)])
        // A parabola of pericentre 6 has l² = 2 r² / (r - 1); r³ / (r - 1)² is that at 12.1.
        #expect(abs(measure.circularRadius - 12.12) < 0.05)
        #expect(abs(TidalMeasure.circularEnergy(radius: measure.circularRadius) - (-0.0409)) < 0.0005)
        // Its own momentum puts a circular tracer at its own radius.
        #expect(abs(measure.boundRing - 12) < 0.05)
    }

    @Test func aCircularOrbitHasNoEccentricityAndTheCircularEnergy() {
        let radius: Float = 12.12
        let tracers = (0..<50).map { Self.circular(radius: radius, angle: Float($0) * 0.1) }
        let (measure, positions, velocities) = Self.measure(tracers)
        let row = positions.withUnsafeBufferPointer { p in
            velocities.withUnsafeBufferPointer { measure.row(time: 0, positions: p, velocities: $0) }
        }
        #expect(row.bound == 1)
        #expect(abs(row.circularised - 1) < 0.01)
        #expect(row.eccentricity < 0.01)
        #expect(row.thickness == 0)
        // The ring sits just outside 2 R_p, and well inside 6 R_p.
        #expect(row.within[0] == 0 && row.within[1] == 1 && row.within[2] == 1)
    }

    @Test func theTurningPointsAreTheOrbitsOwn() throws {
        let (rp, ra): (Float, Float) = (8, 30)
        func phi(_ r: Float) -> Float { -1 / (r - 1) }
        let l2 = 2 * (phi(ra) - phi(rp)) / (1 / (rp * rp) - 1 / (ra * ra))
        let energy = l2 / (2 * ra * ra) + phi(ra)
        for radius: Float in [8.5, 15, 29] {
            let turns = try #require(
                TidalMeasure.turningPoints(energy: energy, momentum2: l2, radius: radius))
            #expect(abs(turns.pericentre - rp) < 0.01 && abs(turns.apocentre - ra) < 0.01)
        }
        #expect(TidalMeasure.turningPoints(energy: 0.01, momentum2: l2, radius: 10) == nil)
    }

    @Test func anOrbitWithTooLittleMomentumPlunges() {
        // Radial infall from 20: nothing turns it before the hole.
        let energy: Float = -1 / 19
        #expect(TidalMeasure.turningPoints(energy: energy, momentum2: 0.5, radius: 15) == nil)
    }

    @Test func swallowedTracersCountAndStopBeingBound() {
        var tracers = (0..<10).map { Self.circular(radius: 10, angle: Float($0)) }
        tracers[0].1.w = -1
        tracers[1].1.w = -1
        let (measure, positions, velocities) = Self.measure(tracers)
        var swallowed = velocities
        swallowed[2].w = -1
        let row = positions.withUnsafeBufferPointer { p in
            swallowed.withUnsafeBufferPointer { measure.row(time: 5, positions: p, velocities: $0) }
        }
        #expect(abs(row.swallowed - 0.3) < 1e-9)
    }

    @Test func aRowIsOneLineOfTheHeader() {
        let (measure, positions, velocities) = Self.measure([Self.circular(radius: 10, angle: 0)])
        let row = positions.withUnsafeBufferPointer { p in
            velocities.withUnsafeBufferPointer { measure.row(time: 1, positions: p, velocities: $0) }
        }
        #expect(row.line.split(separator: ",").count == TidalMeasure.Row.header.split(separator: ",").count)
    }
}
