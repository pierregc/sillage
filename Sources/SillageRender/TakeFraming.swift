import SillageCore

/// What an engine takes of a frame besides its positions: the look, the palette, the time and
/// the painted arms at one moment of a take. The Metal renderer does it with `prepare`, and so
/// does any other engine that draws a take.
public protocol FramePreparing: AnyObject {
    func prepare(
        _ file: LookFile, shot: ShotReplay.Shot, take: RecordingFile.Loaded,
        at blend: Recording.Blend)
}

/// The cameras and the per-shot look of a take, worked out apart from the engine that draws
/// it, so an export, a look grid and the full pass of a hires frame it the same way.
public enum TakeFraming {
    /// What `FramePreparing.prepare` gives a renderer, whichever engine it draws with.
    public struct Moment {
        public var look: RenderLook
        public var palette: [GalaxyColours]
        public var time: Float
        public var diskFrames: [DiskFrame]
    }

    /// The look, the palette, the time and the painted arms for drawing `file` on a moment of
    /// a take.
    public static func moment(
        _ file: LookFile, shot: ShotReplay.Shot, take: RecordingFile.Loaded,
        at blend: Recording.Blend
    ) -> Moment {
        var scene = take.scene
        file.paint(&scene)
        return Moment(
            look: shot.look, palette: file.palette, time: blend.time,
            diskFrames: DiskFrame.make(
                scene: scene, centers: take.recording.centers(at: blend), time: blend.time,
                strength: LookFile.diskStrength(file.armStrength, shot.look),
                disks: take.recording.disks(at: blend)))
    }

    /// The camera an export of `framing` follows at `width` by `height`. `plan`, the director's
    /// for that take and look, is made once for every format when given.
    public static func replay(
        look: LookFile, framing: RecordingFile.Loaded, capturedRate: Int, width: Int, height: Int,
        plan: ShotPlan? = nil
    ) -> ShotReplay {
        ShotReplay(
            file: look, take: framing, capturedFrames: framing.recording.capturedFrames,
            framesPerSecond: max(capturedRate, 1), aspect: Float(width) / Float(max(height, 1)),
            plan: plan)
    }

    /// Everything of a frame but the positions and the smoothing: the shot at a captured
    /// position, and the look, the time and the painted arms `framing` holds there. Exports and
    /// the full pass of a hires (#239) both draw through this. Nil past the take's end.
    public static func prepare(
        _ renderer: some FramePreparing, look: LookFile, replay: ShotReplay,
        framing: RecordingFile.Loaded, at position: Double
    ) -> ShotReplay.Shot? {
        guard let blend = framing.recording.blend(atCaptured: position) else { return nil }
        let shot = replay.shot(atCaptured: position)
        renderer.prepare(look, shot: shot, take: framing, at: blend)
        return shot
    }
}
