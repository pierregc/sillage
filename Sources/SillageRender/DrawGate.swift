/// Decides, on each tick of the canvas's display link, whether a frame is worth drawing (#229).
///
/// A paused run, a finished one or a still frame of a take draws the same picture sixty times a
/// second, and a frame is as much of the GPU as the gap between two refreshes. The gate lets a
/// frame through while anything moves, for a short while after the last change so that
/// whatever lags the picture can catch up, and then only as often as the sensor grain needs to
/// stay alive, or never when the look has none.
public struct DrawGate: Sendable {
    /// What a frame is drawn from. Two ticks with the same key and nothing moving draw the same
    /// picture, grain aside.
    public struct Key: Equatable, Sendable {
        public var eye: SIMD3<Float>
        public var target: SIMD3<Float>
        public var up: SIMD3<Float>
        public var fieldOfView: Float
        public var time: Float
        public var playhead: Double
        public var width: Int
        public var height: Int
        /// Bumped by everything else that changes the picture: a look, a palette, a renderer
        /// rebuilt, a mode.
        public var epoch: Int

        public init(
            camera: Camera, time: Float, playhead: Double, width: Int, height: Int, epoch: Int
        ) {
            eye = camera.eye
            target = camera.target
            up = camera.up
            fieldOfView = camera.fieldOfView
            self.time = time
            self.playhead = playhead
            self.width = width
            self.height = height
            self.epoch = epoch
        }
    }

    public enum Decision: Equatable, Sendable {
        /// Nothing to show that is not on the screen already.
        case skip
        /// Something changed or moved: a whole frame, with the upkeep a frame brings.
        case active
        /// A frame drawn only to renew the grain, or to show what a background job finished.
        case refresh
    }

    /// Seconds between two frames of a still picture whose look has grain; zero or less means
    /// the grain is left frozen.
    public var idleInterval: Double
    /// How long after the last change frames keep coming at the display's rate.
    public var settle: Double

    private var last: Key?
    private var activeUntil = -Double.infinity
    private var lastDrawn = -Double.infinity
    private var forced = false
    private var pending = false

    public init(idleInterval: Double = 1.0 / 12, settle: Double = 0.5) {
        self.idleInterval = idleInterval
        self.settle = settle
    }

    /// The next tick draws in full, whatever the key says: the check modes that drive the view
    /// themselves.
    public mutating func force() { forced = true }

    /// The next tick draws, without the settling that follows a change: a smoothing refresh that
    /// finished, which only wants to be seen once.
    public mutating func wake() { pending = true }

    public mutating func decide(_ key: Key, moving: Bool, grain: Bool, now: Double) -> Decision {
        if moving || forced || key != last {
            forced = false
            pending = false
            last = key
            activeUntil = now + settle
            lastDrawn = now
            return .active
        }
        if now < activeUntil {
            lastDrawn = now
            return .active
        }
        if pending || (grain && idleInterval > 0 && now - lastDrawn >= idleInterval) {
            pending = false
            lastDrawn = now
            return .refresh
        }
        return .skip
    }
}
