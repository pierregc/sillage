import simd

/// Deterministic value noise, mirrored by an identical routine in the shaders so the sampler
/// and the renderer agree on where an arm wanders.
public enum Noise {
    public static func hash(_ i: Float) -> Float {
        let x = sin(i * 127.1 + 311.7) * 43758.5453
        return x - floor(x)
    }

    /// Smooth 1D value noise in [0, 1].
    public static func value(_ x: Float) -> Float {
        let i = floor(x)
        let f = x - i
        let u = f * f * (3 - 2 * f)
        return hash(i) * (1 - u) + hash(i + 1) * u
    }

    /// Two octaves, which is enough to break a curve without turning it to mush.
    public static func fractal(_ x: Float) -> Float {
        value(x) * 0.65 + value(x * 2.3 + 19.1) * 0.35
    }
}
