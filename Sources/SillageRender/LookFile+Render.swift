import SillageCore
import simd

/// Drawing with a look file, in one place, so the command line, the look grid and the app
/// draw the same file the same way.
extension LookFile {
    public func renderSettings(width: Int, height: Int) -> RenderSettings {
        RenderSettings(
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
            skyLevel: look.skyLevel,
            noiseLevel: look.noiseLevel,
            galaxyTint: look.galaxyTint,
            plain: plain)
    }

    /// Whether going from `other` to this file changes something a renderer owns buffers for.
    public func rebuildsRenderer(from other: LookFile) -> Bool {
        supersample != other.supersample || starCount != other.starCount
            || bloomLevels != other.bloomLevels || plain != other.plain
    }

    /// Each palette entry recolours the galaxy at its index; a galaxy past the end keeps its
    /// own colour.
    public func paint(_ scene: inout SceneConfig) {
        for (index, colour) in palette.enumerated() where index < scene.galaxies.count {
            scene.galaxies[index].color = colour
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
        guard !positions.isEmpty else { return 1 }
        var radii = positions.map { simd_length($0) }
        radii.sort()
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
    public func apply(_ file: LookFile) { apply(file.look) }
}
