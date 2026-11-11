import SillageCore
import simd

extension Renderer: FramePreparing {
    public func apply(_ file: LookFile) {
        apply(file.look)
        setGalaxyColours(file.palette)
    }

    /// Everything but the positions, for drawing `file` on a moment of a take.
    public func prepare(
        _ file: LookFile, shot: ShotReplay.Shot, take: RecordingFile.Loaded,
        at blend: Recording.Blend
    ) {
        let moment = TakeFraming.moment(file, shot: shot, take: take, at: blend)
        apply(moment.look)
        setGalaxyColours(moment.palette)
        time = moment.time
        setDiskFrames(moment.diskFrames)
    }
}
