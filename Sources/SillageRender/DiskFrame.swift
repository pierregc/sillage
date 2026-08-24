import SillageCore
import simd

/// A galaxy's disk plane and spiral pattern, evaluated at render time.
///
/// Arms baked into the initial conditions wind up within about one orbit, because the disk
/// rotates differentially. Real spiral arms are a density wave: the pattern turns at its own
/// slower speed while stars pass through it, which is why a galaxy keeps two clean arms for
/// far longer than a material pattern could. Modulating brightness, colour and extinction by
/// the pattern at the particle's current position reproduces that.
public struct DiskFrame {
    public var center: SIMD4<Float>
    public var axisU: SIMD4<Float>
    public var axisV: SIMD4<Float>
    public var pattern: SIMD4<Float>
    public var tint: SIMD4<Float>

    /// Builds one frame per galaxy from the scene, the current centres and the elapsed time.
    public static func make(
        scene: SceneConfig, centers: [SIMD3<Float>], time: Float, strength: Float
    ) -> [DiskFrame] {
        scene.galaxies.enumerated().map { index, galaxy in
            let orientation = galaxy.orientation
            let center = index < centers.count ? centers[index] : galaxy.position
            let armed = galaxy.kind == .spiral ? min(max(galaxy.armStrength * strength, 0), 1) : 0

            // A pattern speed of roughly half the material rotation at two scale lengths is
            // typical, and is what keeps the arms from either freezing or winding up.
            let reference = max(galaxy.diskScaleLength * 2, 0.5)
            let patternSpeed =
                galaxy.potential.circularSpeed(atRadius: reference) / reference * 0.5
                * galaxy.spin.sign

            return DiskFrame(
                center: SIMD4<Float>(center.x, center.y, center.z, galaxy.diskScaleLength),
                axisU: SIMD4<Float>(
                    orientation.columns.0.x, orientation.columns.0.y, orientation.columns.0.z,
                    Float(max(galaxy.armCount, 1))),
                axisV: SIMD4<Float>(
                    orientation.columns.1.x, orientation.columns.1.y, orientation.columns.1.z,
                    armed),
                pattern: SIMD4<Float>(
                    1 / max(tan(galaxy.armPitch), 1e-3), patternSpeed * time,
                    galaxy.armIrregularity, Float(index) * 37.4 + 5.1),
                tint: SIMD4<Float>(galaxy.color.x, galaxy.color.y, galaxy.color.z, 0))
        }
    }
}
