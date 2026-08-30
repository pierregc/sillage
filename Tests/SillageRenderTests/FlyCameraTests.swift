import Testing
import simd

@testable import SillageRender

@Suite("Free flight")
struct FlyCameraTests {
    private func holding(_ move: SIMD3<Float>, turn: SIMD2<Float> = .zero) -> FlyCamera.Demand {
        var demand = FlyCamera.Demand()
        demand.move = move
        demand.turn = turn
        return demand
    }

    @Test func forwardGoesWhereTheCameraLooks() {
        var camera = FlyCamera(position: .zero, yaw: 0, pitch: 0)
        let direction = camera.forward
        for _ in 0..<120 { camera.advance(holding(SIMD3(1, 0, 0)), seconds: 1.0 / 60) }
        let travelled = camera.position
        #expect(simd_length(travelled) > 1)
        // Along the view direction and nowhere else.
        #expect(simd_length(simd_normalize(travelled) - direction) < 1e-3)
    }

    /// The whole point of easing on a velocity rather than nudging a position: the distance
    /// covered in a second must not depend on how fast the machine happened to be drawing.
    @Test func speedDoesNotFollowTheFrameRate() {
        func travelled(hertz: Float) -> Float {
            var camera = FlyCamera(position: .zero)
            let steps = Int(hertz)
            for _ in 0..<steps { camera.advance(holding(SIMD3(1, 0, 0)), seconds: 1 / hertz) }
            return simd_length(camera.position)
        }
        let slow = travelled(hertz: 30)
        let fast = travelled(hertz: 120)
        #expect(abs(fast - slow) / slow < 0.02)
    }

    @Test func lettingGoComesToRestRatherThanStopping() {
        var camera = FlyCamera(position: .zero)
        for _ in 0..<60 { camera.advance(holding(SIMD3(1, 0, 0)), seconds: 1.0 / 60) }
        let moving = camera.position
        // One frame of no input still carries some way: that coast is the point.
        camera.advance(holding(.zero), seconds: 1.0 / 60)
        let coasted = simd_length(camera.position - moving)
        #expect(coasted > 0.01)
        for _ in 0..<180 { camera.advance(holding(.zero), seconds: 1.0 / 60) }
        let settled = camera.position
        camera.advance(holding(.zero), seconds: 1.0 / 60)
        #expect(simd_length(camera.position - settled) < 0.01)
    }

    @Test func strafingStaysLevelHoweverSteepTheLook() {
        var camera = FlyCamera(position: .zero, yaw: 0.7, pitch: 1.3)
        for _ in 0..<120 { camera.advance(holding(SIMD3(0, 1, 0)), seconds: 1.0 / 60) }
        #expect(abs(camera.position.z) < 1e-4)
    }

    @Test func lookingUpStopsShortOfStraightUp() {
        var camera = FlyCamera()
        for _ in 0..<600 { camera.advance(holding(.zero, turn: SIMD2(0, 4)), seconds: 1.0 / 60) }
        #expect(camera.pitch <= FlyCamera.pitchLimit)
        #expect(camera.pitch > FlyCamera.pitchLimit - 0.01)
    }

    /// Swapping rigs must not move the picture, in either direction.
    @Test func theTwoRigsHandOverWithoutJumping() {
        var orbit = OrbitCamera(target: SIMD3(12, -4, 3), distance: 310, azimuth: 0.8, elevation: 0.5)
        var fly = FlyCamera()
        fly.adopt(orbit)
        #expect(simd_length(fly.camera.eye - orbit.camera.eye) < 1e-3)
        let before = simd_normalize(orbit.camera.target - orbit.camera.eye)
        #expect(simd_length(fly.forward - before) < 1e-3)

        fly.look(deltaYaw: 0.3, deltaPitch: -0.2)
        let aimed = fly.forward
        fly.handBack(&orbit)
        let after = simd_normalize(orbit.camera.target - orbit.camera.eye)
        #expect(simd_length(after - aimed) < 1e-3)
    }

    @Test func theThrottleStaysWithinItsRange() {
        var camera = FlyCamera()
        for _ in 0..<200 { camera.changeSpeed(factor: 2) }
        #expect(camera.speed == FlyCamera.fastest)
        for _ in 0..<400 { camera.changeSpeed(factor: 0.5) }
        #expect(camera.speed == FlyCamera.slowest)
    }
}
