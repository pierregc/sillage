import Foundation
import SillageCore
import simd

/// Spike #173 only: `SILLAGE_DISRUPTION_CSV` names a `curves-hires.csv` whose disruption columns
/// replace what a take written before the fix stores (nothing), for its encounter sheets.
nonisolated(unsafe) let spikeDisruption: [(Double, [Float])] = {
    guard let path = ProcessInfo.processInfo.environment["SILLAGE_DISRUPTION_CSV"],
        let text = try? String(contentsOfFile: path, encoding: .utf8)
    else { return [] }
    let lines = text.split(separator: "\n")
    guard let header = lines.first?.split(separator: ",").map(String.init) else { return [] }
    let time = header.firstIndex(of: "time_myr") ?? 1
    let columns = header.indices.filter { header[$0].hasPrefix("disruption_") }
    return lines.dropFirst().compactMap { line in
        let fields = line.split(separator: ",").map(String.init)
        guard fields.count == header.count, let t = Double(fields[time]) else { return nil }
        return (t, columns.map { Float(fields[$0]) ?? 0 })
    }
}()

/// Drawing with a look file, in one place, so the command line, the look grid and the app
/// draw the same file the same way.
extension LookFile {
    public func renderSettings(width: Int, height: Int) -> RenderSettings {
        var settings = RenderSettings(
            width: width,
            height: height,
            supersample: supersample,
            brightness: look.brightness,
            dustStrength: look.dustStrength,
            starCount: starCount,
            starSize: look.starSize,
            smoothingScale: look.smoothingScale,
            minimumKernel: look.minimumKernel,
            maximumKernel: look.maximumKernel,
            bloomThreshold: look.bloomThreshold,
            bloomSoftKnee: look.bloomSoftKnee,
            bloomIntensity: look.bloomIntensity,
            bloomLevels: bloomLevels,
            stretch: look.stretch,
            saturation: look.saturation,
            whitePoint: look.whitePoint,
            spikeArms: look.spikeArms,
            spikeLength: look.spikeLength,
            spikeIntensity: look.spikeIntensity,
            spikePattern: look.spikePattern,
            spikeSharpness: look.spikeSharpness,
            skyLevel: look.skyLevel,
            skyColour: look.skyColour,
            noiseLevel: look.noiseLevel,
            galaxyTint: look.galaxyTint,
            plain: plain)
        settings.holeShadow = look.holeShadow
        settings.columnSmoothing = look.columnSmoothing
        settings.glint = look.glint
        settings.dustWeb = look.dustWeb
        return settings
    }

    /// Whether going from `other` to this file changes something a renderer owns buffers for.
    public func rebuildsRenderer(from other: LookFile) -> Bool {
        supersample != other.supersample || starCount != other.starCount
            || bloomLevels != other.bloomLevels || plain != other.plain
    }

    /// Each palette entry recolours the galaxy at its index; a galaxy past the end keeps its
    /// own colour.
    public func paint(_ scene: inout SceneConfig) {
        for (index, entry) in palette.enumerated() where index < scene.galaxies.count {
            scene.galaxies[index].color = entry.colour
        }
    }

    /// The strength handed to `DiskFrame.make`. Both factors count: the file's own and the
    /// look's, which the director modulates and the named looks push past one.
    public static func diskStrength(_ armStrength: Float, _ look: RenderLook) -> Float {
        armStrength * look.armPersistence
    }
}

extension LookFile.CameraPlan {
    /// The radius a fixed plan frames, from the first frame drawn.
    public func framedRadius(positions: [SIMD3<Float>]) -> Float {
        if radius > 0 { return radius }
        return framedRadius(sortedRadii: positions.map { simd_length($0) }.sorted())
    }

    /// The same from the first frame's radii already sorted, which a plan edited again and
    /// again need not sort each time.
    public func framedRadius(sortedRadii radii: [Float]) -> Float {
        if radius > 0 { return radius }
        guard !radii.isEmpty else { return 1 }
        return radii[min(Int(Float(radii.count) * percentile), radii.count - 1)] / zoom
    }

    /// The camera `progress` of the way through the clip, eased so a move starts and stops
    /// gently.
    public func camera(
        progress: Float, radius: Float, center: SIMD3<Float> = .zero, fieldOfView: Float
    ) -> Camera {
        let t = min(max(progress, 0), 1)
        let eased = t * t * (3 - 2 * t)
        let elevationEnd = self.elevationEnd ?? elevation
        let azimuthEnd = self.azimuthEnd ?? azimuth
        return Camera.framing(
            radius: radius, center: center, fieldOfView: fieldOfView,
            elevation: elevation + (elevationEnd - elevation) * eased,
            azimuth: azimuth + (azimuthEnd - azimuth) * eased)
    }
}

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
        // Spike only: the disruption read back from a curves file, for takes written without it.
        var disks = take.recording.disks(at: blend)
        if !spikeDisruption.isEmpty {
            let myr = Double(blend.time) * Physics.megayearsPerTimeUnit
            if let row = spikeDisruption.min(by: { abs($0.0 - myr) < abs($1.0 - myr) }) {
                for index in disks.indices where index < row.1.count {
                    disks[index].disruption = row.1[index]
                }
            }
        }
        setDiskFrames(
            DiskFrame.make(
                scene: scene, centers: take.recording.centers(at: blend), time: blend.time,
                strength: LookFile.diskStrength(file.armStrength, shot.look),
                disks: disks))
    }
}
