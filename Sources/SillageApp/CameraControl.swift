import AppKit
import Metal
import MetalKit
import SillageCore
import SillageRender
import simd

/// How the camera is driven: the orbit rig, free flight, and the handover between them and
/// the director in contemplation.
extension SimulationModel {
    /// Whichever rig is driving. In contemplation that is the director, unless somebody has
    /// touched the camera recently — then it is theirs, and the director takes it back once
    /// they have stopped.
    var activeCamera: Camera {
        if contemplating, !cameraIsManual { return director.camera }
        if followsPlan, !isFlying, let planned = planCamera { return planned }
        return isFlying ? flight.camera : camera.camera
    }

    /// Whether the mouse moves the plan rather than the orbit rig: the canvas shows what the
    /// export frames, so a framing made there is the one saved and exported (#177).
    var steersPlan: Bool { followsPlan && mode == .playback && !isFlying && !contemplating }

    /// A drag on the canvas: the flight's aim, the plan's angles, or the orbit rig. The
    /// director chooses its own angles, so a drag leaves its plan alone.
    func drag(_ dx: CGFloat, _ dy: CGFloat) {
        takeCamera()
        if isFlying {
            flight.look(deltaYaw: Float(dx) * 0.005, deltaPitch: Float(-dy) * 0.005)
        } else if steersPlan {
            guard lookFile.camera.placesCamera else { return }
            lookFile.camera = lookFile.camera.turned(
                azimuth: Float(-dx) * 0.008, elevation: Float(dy) * 0.008)
        } else {
            camera.orbit(deltaAzimuth: Float(-dx) * 0.008, deltaElevation: Float(dy) * 0.008)
        }
    }

    /// The wheel: the flight's throttle, the plan's zoom, the director's shots included, or the
    /// rig's distance.
    func scroll(_ dy: CGFloat) {
        takeCamera()
        // In flight the wheel is the throttle: there is no distance to a target to change.
        if isFlying {
            flight.changeSpeed(factor: Float(1 - dy * 0.02))
        } else if steersPlan {
            lookFile.camera = lookFile.camera.zoomed(by: exp(Float(dy) * 0.01))
        } else {
            camera.zoom(factor: Float(1 - dy * 0.01))
        }
    }

    /// True while a hand is on the camera. Contemplation hands control over on any input and
    /// takes it back after a pause, so touching the view never means losing the film.
    var cameraIsManual: Bool {
        guard let until = manualCameraUntil else { return false }
        return Date() < until
    }

    /// Called by every camera input. In contemplation it also picks the rig up where the
    /// director left it, so taking hold never jumps the view.
    func takeCamera() {
        if contemplating, !cameraIsManual {
            let handed = director.camera
            flight.position = handed.eye
            let aim = simd_normalize(handed.target - handed.eye)
            flight.pitch = asin(min(max(aim.z, -1), 1))
            flight.yaw = atan2(aim.x, aim.y)
            flight.fieldOfView = handed.fieldOfView
            camera.target = handed.target
            camera.distance = simd_length(handed.target - handed.eye)
            camera.azimuth = atan2(-aim.x, aim.y)
            camera.elevation = min(
                max(-flight.pitch, -OrbitCamera.elevationLimit), OrbitCamera.elevationLimit)
        }
        manualCameraUntil = Date().addingTimeInterval(Self.manualCameraHold)
    }

    /// How long the camera stays in a viewer's hands after their last input.
    static let manualCameraHold: TimeInterval = 25

    /// Swaps rigs without the view jumping: each takes up where the other left off.
    func toggleFlight() {
        if isFlying {
            flight.handBack(&camera)
        } else {
            flight.adopt(camera)
        }
        isFlying.toggle()
        lastDrawTime = nil
    }

    /// One frame of held-key flight. Reads the keys the canvas is holding rather than acting
    /// on key events, so the speed follows the frame time instead of the key repeat rate.
    func flyOneFrame(_ view: MTKView, seconds: Float) {
        guard let canvas = view as? CanvasView else { return }
        let held = canvas.held
        // In contemplation the movement keys are the way in: pressing one takes the camera
        // from the director rather than needing a mode to be turned on first.
        if contemplating, !held.isEmpty, !isFlying,
            held.contains(where: CanvasView.Key.movement.contains)
        {
            takeCamera()
            flight.adopt(camera)
            isFlying = true
        }
        guard isFlying else { return }
        if !held.isEmpty { takeCamera() }
        func axis(_ positive: UInt16, _ negative: UInt16) -> Float {
            (held.contains(positive) ? 1 : 0) - (held.contains(negative) ? 1 : 0)
        }
        var demand = FlyCamera.Demand()
        demand.move = SIMD3<Float>(
            axis(CanvasView.Key.w, CanvasView.Key.s),
            axis(CanvasView.Key.d, CanvasView.Key.a),
            axis(CanvasView.Key.space, CanvasView.Key.c)
                + axis(CanvasView.Key.e, CanvasView.Key.q))
        demand.turn = SIMD2<Float>(
            axis(CanvasView.Key.left, CanvasView.Key.right) * 1.4,
            axis(CanvasView.Key.up, CanvasView.Key.down) * 1.4)
        let modifiers = canvas.modifiers
        if modifiers.contains(.shift) { demand.boost = 5 }
        if modifiers.contains(.control) { demand.boost = 0.2 }
        flight.advance(demand, seconds: seconds)
    }

    func frameCamera() {
        guard let radius = Self.framingRadius(seeded) else { return }
        camera.frame(radius: radius * 1.3)
    }

    /// Radius holding 96 % of the light, from a subsample.
    ///
    /// Counting particles instead framed on the wrong thing: a run throws a faint halo of
    /// tracers well outside the galaxies, and nothing of it reaches a pixel, so the camera
    /// pulled back to hold material nobody can see and left the galaxies filling a third of
    /// the frame. Weighting by emission keeps a bright tidal tail and ignores the debris.
    ///
    /// Subsampled because sorting every radius cost four hundred milliseconds of frozen
    /// window at five million particles, to place a camera.
    static func framingRadius(_ system: ParticleSystem, fraction: Float = 0.96) -> Float? {
        system.framingRadius(fraction: fraction)
    }
}
