import simd

/// Linear sRGB of a Planckian radiator, at unit luminance.
///
/// Kang et al. (2002) for the chromaticity, then CIE xy through the sRGB primaries. Y is held
/// at one so the conversion lands on unit luminance before the negative lobe of a saturated
/// hue is clipped away, which is what lets brightness stay the single control over exposure.
///
/// The renderer has the same function in Metal, because a shader cannot call this one. They
/// are the same coefficients and the same clamp; if one is edited the other has to be.
public enum Blackbody {
    public static func linearSRGB(kelvin: Float) -> SIMD3<Float> {
        let t = min(max(kelvin, 2222), 25000)
        let inverse = 1 / t
        let x =
            t < 4000
            ? ((-0.266_123_9e9 * inverse - 0.234_358_9e6) * inverse + 0.877_695_6e3) * inverse
                + 0.179_910
            : ((-3.025_846_9e9 * inverse + 2.107_037_9e6) * inverse + 0.222_634_7e3) * inverse
                + 0.240_390
        let y =
            t < 4000
            ? ((-0.954_947_6 * x - 1.374_185_93) * x + 2.091_370_15) * x - 0.167_488_67
            : ((3.081_758_0 * x - 5.873_386_70) * x + 3.751_129_97) * x - 0.370_014_83
        let scale = 1 / max(y, 1e-4)
        let xyz = SIMD3<Float>(x * scale, 1, (1 - x - y) * scale)
        let rgb = SIMD3<Float>(
            simd_dot(xyz, SIMD3<Float>(3.2406, -1.5372, -0.4986)),
            simd_dot(xyz, SIMD3<Float>(-0.9689, 1.8758, 0.0415)),
            simd_dot(xyz, SIMD3<Float>(0.0557, -0.2040, 1.0570)))
        let clipped = simd_max(rgb, .zero)
        let luminance = max(simd_dot(clipped, SIMD3<Float>(0.2126, 0.7152, 0.0722)), 1e-4)
        return clipped / luminance
    }
}
