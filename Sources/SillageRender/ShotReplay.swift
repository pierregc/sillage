import SillageCore
import simd

/// The camera and the look a look file gives each captured frame of a take, the camera moved
/// through every frame before it: the auto camera eases and the director moves on, so neither
/// can be placed on a frame without the ones that led there. The look grid and the export both
/// draw through this, so a still of the grid and the same frame of a video are framed alike.
public final class ShotReplay {
    public typealias Shot = (camera: Camera, look: RenderLook)

    private let file: LookFile
    private let recording: Recording
    private let span: Float
    private let radius: Float
    private let reach: [Float]
    private let scene: SceneConfig
    private let director: Cinematographer?
    private let secondsPerFrame: Double
    private var auto = AutoCamera()
    private var next = 0
    /// The last two frames replayed, enough to draw anywhere between them.
    private var recent: [(frame: Int, shot: Shot)] = []

    public init(
        file: LookFile, take: RecordingFile.Loaded, capturedFrames: Int, framesPerSecond: Int
    ) {
        self.file = file
        recording = take.recording
        let scene = take.scene
        self.scene = scene
        span = Float(max(capturedFrames - 1, 1))
        radius = file.camera.framedRadius(positions: take.particles.positions)
        reach = scene.galaxies.map { max($0.diskScaleLength * $0.diskTruncation, 0.1) }
        let mode = file.camera.mode
        director = mode == .director || mode == .immersed ? Cinematographer(seed: scene.seed) : nil
        director?.beginScene(seed: scene.seed, base: file.look, immersed: mode == .immersed)
        secondsPerFrame = 1 / Double(max(framesPerSecond, 1))
    }

    /// Frames are asked for in order; one already left behind is replayed no more.
    public func shot(atCaptured frame: Int) -> Shot {
        while next <= frame {
            recent = Array((recent + [(next, advance(to: next))]).suffix(2))
            next += 1
        }
        return recent.last { $0.frame <= frame }?.shot ?? recent[0].shot
    }

    /// Between two captured frames the camera and the look are mixed, so a frame rate above the
    /// take's glides rather than holding each shot twice.
    public func shot(atCaptured position: Double) -> Shot {
        let lower = Int(max(position, 0).rounded(.down))
        let t = Float(max(position, 0) - Double(lower))
        guard t > 0 else { return shot(atCaptured: lower) }
        let after = shot(atCaptured: lower + 1)
        let before = shot(atCaptured: lower)
        var camera = before.camera
        camera.eye += (after.camera.eye - camera.eye) * t
        camera.target += (after.camera.target - camera.target) * t
        camera.up += (after.camera.up - camera.up) * t
        camera.fieldOfView += (after.camera.fieldOfView - camera.fieldOfView) * t
        return (camera, RenderLook.mix(before.look, after.look, t))
    }

    private func advance(to frame: Int) -> Shot {
        let around = scene.framedCentres(
            recording.blend(atCaptured: frame).map { recording.centers(at: $0) } ?? [])
        if let director {
            director.advance(seconds: secondsPerFrame, of: Subject(centres: around, radius: radius))
            return (director.camera, director.look)
        }
        let plan = file.camera
        var framed = (center: SIMD3<Float>.zero, radius: radius)
        if plan.mode == .auto {
            framed = auto.frame(centres: around, margins: reach)
            framed.radius /= plan.zoom
        }
        return (
            plan.camera(
                progress: Float(frame) / span, radius: framed.radius, center: framed.center,
                fieldOfView: file.look.fieldOfView),
            file.look
        )
    }
}
