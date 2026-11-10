import SillageCore
import simd

extension Renderer {
    public func apply(_ file: LookFile) {
        apply(file.look)
        setGalaxyColours(file.palette)
    }

    /// Everything but the positions, for drawing `file` on a moment of a take.
    public func prepare(
        _ file: LookFile, shot: ShotReplay.Shot, take: RecordingFile.Loaded,
        at blend: Recording.Blend
    ) {
        apply(shot.look)
        setGalaxyColours(file.palette)
        time = blend.time
        var scene = take.scene
        file.paint(&scene)
        setDiskFrames(
            DiskFrame.make(
                scene: scene, centers: take.recording.centers(at: blend), time: blend.time,
                strength: LookFile.diskStrength(file.armStrength, shot.look),
                disks: take.recording.disks(at: blend)))
    }
}
