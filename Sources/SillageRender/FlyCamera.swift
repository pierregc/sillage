import Foundation

#if canImport(simd)
    import simd
#else
    import SillageCore
#endif

/// A free camera: a position and a direction to look in, driven by held keys.
///
/// The orbit rig answers "look at this galaxy from there"; this one answers "go inside it".
/// Both are kept because they are good at different things, and neither replaces the other.
///
/// Motion is a velocity that chases what the keys ask for, rather than a position nudged once
/// per event. Key repeat arrives in irregular bursts and would show as judder however smooth
/// the rendering is; a velocity integrated against the real frame time does not, and the
/// easing at each end of a press is what makes a slow drift through a disk watchable.
public struct FlyCamera: Sendable {
    /// What the keys are asking for, in camera-relative axes: forward, right, up.
    public struct Demand: Sendable, Equatable {
        public var move = SIMD3<Float>.zero
        public var turn = SIMD2<Float>.zero
        public var boost: Float = 1
        public init() {}
    }

    public var position: SIMD3<Float>
    /// Zero looks along +y, the direction the orbit rig starts from.
    public var yaw: Float
    /// Kept clear of straight up and straight down, where the up vector degenerates.
    public var pitch: Float
    public var fieldOfView: Float
    /// Kiloparsecs a second at full tilt, before the boost. Scroll and the throttle steps change it.
    public var speed: Float = 90
    /// Radians about the line of sight, as a flight key's (#298): positive turns the camera
    /// anticlockwise. Banking moves it; nothing else does.
    public private(set) var roll: Float = 0
    /// Radians of bank for each radian a second the view turns about the vertical, 0 for none.
    /// The bank follows the turn eased, and levels again once the turn stops.
    public var banking: Float = 0
    /// How far ahead the aim point is, in kiloparsecs. The dust's depth slabs are centred on it,
    /// so the model sets it to the distance of the matter being looked at.
    public var aimDistance: Float = 1
    /// The camera's near distance in kiloparsecs; a camera flown through a take's inside takes a
    /// parsec (`FlightFile.near`).
    public var near: Float = 1

    private var velocity = SIMD3<Float>.zero
    private var turnRate = SIMD2<Float>.zero
    private var turning: Float = 0

    public static let pitchLimit: Float = 1.52
    /// Five parsecs a second: 0.17 pc a frame at 30 fps, finer than the spacing of an arm's
    /// particles at 8 M.
    public static let slowest: Float = 0.005
    public static let fastest: Float = 4000
    /// The most a bank turns the camera, in radians.
    public static let bankLimit: Float = 0.6

    /// The throttle's steps, kiloparsecs a second: a 1-2-5 ladder from a drift among an arm's
    /// stars to the length of a collision in a second.
    public static let throttle: [Float] = [
        0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 4000,
    ]

    public init(
        position: SIMD3<Float> = SIMD3<Float>(0, -260, 0),
        yaw: Float = 0,
        pitch: Float = 0,
        fieldOfView: Float = 0.6
    ) {
        self.position = position
        self.yaw = yaw
        self.pitch = min(max(pitch, -Self.pitchLimit), Self.pitchLimit)
        self.fieldOfView = fieldOfView
        bankedYaw = yaw
    }

    public var forward: SIMD3<Float> {
        SIMD3<Float>(cos(pitch) * sin(yaw), cos(pitch) * cos(yaw), sin(pitch))
    }

    /// Level with the horizon whatever the pitch, so strafing never rolls the view.
    public var right: SIMD3<Float> { SIMD3<Float>(cos(yaw), -sin(yaw), 0) }

    public var camera: Camera {
        Camera(
            eye: position, target: position + forward * aimDistance, up: up,
            fieldOfView: fieldOfView, near: near)
    }

    /// The world's z turned by the roll about the line of sight, as `Flight` draws a roll.
    public var up: SIMD3<Float> {
        guard roll != 0 else { return SIMD3<Float>(0, 0, 1) }
        let right = self.right
        let level = simd_cross(right, forward)
        // `right` is level and `forward` and it are orthogonal, so this is the world's z
        // rejected from the line of sight.
        return level * cos(roll) - right * sin(roll)
    }

    /// One frame of flight. `seconds` is the real frame time, so the speed does not depend on
    /// how fast the machine happens to be drawing.
    public mutating func advance(_ demand: Demand, seconds: Float) {
        let step = min(max(seconds, 1.0 / 240), 0.1)
        // Time constants rather than per-frame factors, so the feel survives a frame rate
        // that moves: about an eighth of a second to reach speed, and the same to stop.
        let ease = 1 - exp(-step / 0.12)
        let turnEase = 1 - exp(-step / 0.08)

        let wanted =
            (forward * demand.move.x + right * demand.move.y
                + SIMD3<Float>(0, 0, 1) * demand.move.z)
        let length = simd_length(wanted)
        let target = length > 1 ? wanted / length : wanted
        velocity += (target * speed * demand.boost - velocity) * ease
        position += velocity * step

        turnRate += (demand.turn - turnRate) * turnEase
        yaw += turnRate.x * step
        pitch = min(max(pitch + turnRate.y * step, -Self.pitchLimit), Self.pitchLimit)
        bank(step: step)
    }

    /// The roll that follows the turn: into a turn to the right the camera leans right, which a
    /// flight key writes as a negative roll. The turn is the view's own, so a drag of the mouse
    /// banks as the arrow keys do.
    private mutating func bank(step: Float) {
        // Wrapped, and held to a rate no hand makes: a yaw set from outside is not a turn.
        var turned = yaw - bankedYaw
        turned -= 2 * .pi * (turned / (2 * .pi)).rounded()
        turning += (min(max(turned / step, -4), 4) - turning) * (1 - exp(-step / 0.15))
        bankedYaw = yaw
        let wanted =
            banking > 0 ? -min(max(banking * turning, -Self.bankLimit), Self.bankLimit) : 0
        roll += (wanted - roll) * (1 - exp(-step / 0.3))
        if abs(roll) < 1e-5, abs(wanted) < 1e-5 { roll = 0 }
    }

    private var bankedYaw: Float = 0

    /// Turned by the mouse, which needs no easing: the hand already provides it.
    public mutating func look(deltaYaw: Float, deltaPitch: Float) {
        yaw += deltaYaw
        pitch = min(max(pitch + deltaPitch, -Self.pitchLimit), Self.pitchLimit)
    }

    public mutating func changeSpeed(factor: Float) {
        speed = min(max(speed * factor, Self.slowest), Self.fastest)
    }

    /// One step up or down the throttle's ladder from wherever the speed is.
    public mutating func stepThrottle(_ direction: Int) {
        let ladder = Self.throttle
        let next =
            direction > 0
            ? ladder.first { $0 > speed * 1.0001 } ?? ladder[ladder.count - 1]
            : ladder.last { $0 < speed / 1.0001 } ?? ladder[0]
        speed = next
    }

    /// A speed as the panel reads it: "90 kpc/s", "0.5 kpc/s", "50 pc/s".
    public static func describe(speed: Float) -> String {
        if speed >= 10 { return String(format: "%.0f kpc/s", speed) }
        if speed >= 1 { return String(format: "%.1f kpc/s", speed) }
        if speed >= 0.1 { return String(format: "%.2g kpc/s", speed) }
        return String(format: "%.2g pc/s", speed * 1000)
    }

    /// Takes over from the orbit rig without the view jumping.
    public mutating func adopt(_ orbit: OrbitCamera) {
        let view = orbit.camera
        position = view.eye
        let direction = simd_normalize(view.target - view.eye)
        pitch = min(max(asin(direction.z), -Self.pitchLimit), Self.pitchLimit)
        yaw = atan2(direction.x, direction.y)
        fieldOfView = orbit.fieldOfView
        velocity = .zero
        turnRate = .zero
        turning = 0
        roll = 0
        bankedYaw = yaw
    }

    /// Takes over from a camera already placed, as a flight's: the eye, the line of sight and
    /// the field of view; the roll is taken from the camera's up vector.
    public mutating func adopt(_ view: Camera) {
        position = view.eye
        let direction = simd_normalize(view.target - view.eye)
        pitch = min(max(asin(direction.z), -Self.pitchLimit), Self.pitchLimit)
        yaw = atan2(direction.x, direction.y)
        fieldOfView = view.fieldOfView
        velocity = .zero
        turnRate = .zero
        turning = 0
        bankedYaw = yaw
        // The roll against the world's z, as a flight key counts it.
        let level = simd_cross(right, forward)
        let side = simd_dot(simd_normalize(view.up), right)
        roll = -atan2(side, simd_dot(simd_normalize(view.up), level))
    }

    /// Hands back to the orbit rig, pointing it at whatever is being looked at.
    public func handBack(_ orbit: inout OrbitCamera) {
        orbit.target = position + forward * orbit.distance
        orbit.azimuth = atan2(-forward.x, forward.y)
        orbit.elevation = min(
            max(-pitch, -OrbitCamera.elevationLimit), OrbitCamera.elevationLimit)
        orbit.fieldOfView = fieldOfView
    }
}
