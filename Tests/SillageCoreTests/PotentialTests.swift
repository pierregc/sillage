import Testing
import simd

@testable import SillageCore

@Suite("Potentials")
struct PotentialTests {
    @Test(arguments: PotentialProfile.allCases)
    func circularSpeedMatchesRadialAcceleration(profile: PotentialProfile) {
        let potential = GalaxyPotential(profile: profile, mass: 50, scaleRadius: 5)
        for radius in [Float(1), 4, 8, 20] {
            let speed = potential.circularSpeed(atRadius: radius)
            let pull = simd_length(potential.acceleration(at: SIMD3<Float>(radius, 0, 0)))
            #expect(abs(speed - (pull * radius).squareRoot()) < 1e-4 * max(speed, 1))
        }
    }

    @Test(arguments: PotentialProfile.allCases)
    func accelerationPointsInward(profile: PotentialProfile) {
        let potential = GalaxyPotential(profile: profile, mass: 10, scaleRadius: 2)
        let offset = SIMD3<Float>(3, -4, 12)
        let acceleration = potential.acceleration(at: offset)
        #expect(simd_dot(acceleration, offset) < 0)
        #expect(abs(simd_length(simd_cross(acceleration, offset))) < 1e-3)
    }

    @Test func potentialIsMonotonic() {
        let potential = GalaxyPotential(profile: .hernquist, mass: 50, scaleRadius: 5)
        var previous = -Float.infinity
        for radius in stride(from: Float(0), through: 100, by: 2) {
            let value = potential.potential(at: SIMD3<Float>(radius, 0, 0))
            #expect(value > previous)
            previous = value
        }
        #expect(previous < 0)
    }

    @Test func accelerationIsFiniteAtCentre() {
        for profile in PotentialProfile.allCases {
            let acceleration = GalaxyPotential(profile: profile, mass: 50, scaleRadius: 5)
                .acceleration(at: .zero)
            #expect(acceleration.x.isFinite && acceleration.y.isFinite && acceleration.z.isFinite)
        }
    }
}
