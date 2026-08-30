import simd

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
    /// Kiloparsecs a second at full tilt, before the boost. Scroll changes it.
    public var speed: Float = 90

    private var velocity = SIMD3<Float>.zero
    private var turnRate = SIMD2<Float>.zero

    public static let pitchLimit: Float = 1.52
    public static let slowest: Float = 2
    public static let fastest: Float = 4000

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
    }

    public var forward: SIMD3<Float> {
        SIMD3<Float>(cos(pitch) * sin(yaw), cos(pitch) * cos(yaw), sin(pitch))
    }

    /// Level with the horizon whatever the pitch, so strafing never rolls the view.
    public var right: SIMD3<Float> { SIMD3<Float>(cos(yaw), -sin(yaw), 0) }

    public var camera: Camera {
        Camera(eye: position, target: position + forward, fieldOfView: fieldOfView)
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
    }

    /// Turned by the mouse, which needs no easing: the hand already provides it.
    public mutating func look(deltaYaw: Float, deltaPitch: Float) {
        yaw += deltaYaw
        pitch = min(max(pitch + deltaPitch, -Self.pitchLimit), Self.pitchLimit)
    }

    public mutating func changeSpeed(factor: Float) {
        speed = min(max(speed * factor, Self.slowest), Self.fastest)
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
