import SillageCore
#if canImport(simd)
    import simd
#else
    import Foundation
#endif

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
            radius: radius / keyedZoom(at: t), center: center, fieldOfView: fieldOfView,
            elevation: elevation + (elevationEnd - elevation) * eased,
            azimuth: azimuth + (azimuthEnd - azimuth) * eased)
    }
}

extension LookFile.CameraPlan {
    /// The factor `zoomKeys` give at `progress`, eased in log zoom so a push in and a pull back
    /// of the same ratio take the same course.
    public func keyedZoom(at progress: Float) -> Float {
        guard let keys = zoomKeys?.sorted(by: { $0.x < $1.x }), let first = keys.first,
            let last = keys.last
        else { return 1 }
        if progress <= first.x { return max(first.y, 1e-3) }
        if progress >= last.x { return max(last.y, 1e-3) }
        let after = keys.firstIndex { $0.x > progress } ?? keys.count - 1
        let (a, b) = (keys[after - 1], keys[after])
        let u = (progress - a.x) / max(b.x - a.x, 1e-6)
        let eased = u * u * (3 - 2 * u)
        let low = log(max(a.y, 1e-3))
        return exp(low + (log(max(b.y, 1e-3)) - low) * eased)
    }
}
