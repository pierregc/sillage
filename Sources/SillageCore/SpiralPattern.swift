import Foundation

/// Where a galaxy's arms are, as one description that both the sampler and the renderer use.
///
/// These two disagreed for as long as they both existed. The sampler laid particles down on a
/// clean logarithmic spiral of perfect m-fold symmetry, and the renderer painted a different,
/// irregular pattern over the top of them — so the light said one thing about where the arms
/// were and the matter said another, and any asymmetry in the picture was paint. Writing it
/// once fixes that, and it is also the only way to put a lopsided galaxy in the *mass*: a
/// disk that is genuinely heavier on one side has to be sampled that way.
///
/// The renderer keeps a copy of this in Metal, because a shader cannot call Swift. They have
/// to stay identical, and the hash below is what makes that possible: it is integer mixing
/// rather than the usual `fract(sin(x) * 43758.5453)`. A sine-based hash is chaotic — the last
/// bits of `sin` differ between a CPU and a GPU, and after multiplying by forty thousand and
/// taking the fraction, two implementations that agree to seven digits produce unrelated
/// numbers. Integer mixing gives the same answer everywhere, exactly.
public enum SpiralPattern {
    /// A unit float from an integral index. Mirrored in `Shaders.swift`; edit both.
    public static func hash(_ index: Float) -> Float {
        let k = Int32(truncatingIfNeeded: Int(index.rounded(.towardZero)))
        var n = UInt32(bitPattern: k &* 374_761_393 &+ 668_265_263)
        n = (n ^ (n >> 13)) &* 1_274_126_177
        n = n ^ (n >> 16)
        return Float(n) * (1.0 / 4_294_967_296.0)
    }

    public static func valueNoise(_ x: Float) -> Float {
        let base = x.rounded(.down)
        let f = x - base
        let u = f * f * (3 - 2 * f)
        let a = hash(base)
        let b = hash(base + 1)
        return a + (b - a) * u
    }

    public static func fractalNoise(_ x: Float) -> Float {
        valueNoise(x) * 0.65 + valueNoise(x * 2.3 + 19.1) * 0.35
    }

    /// Everything about a galaxy's pattern that both sides need to agree on.
    public struct Shape: Sendable {
        public var arms: Float
        public var windRate: Float
        public var irregularity: Float
        public var seed: Float

        public init(arms: Int, windRate: Float, irregularity: Float, index: Int) {
            self.arms = Float(max(arms, 1))
            self.windRate = windRate
            self.irregularity = min(max(irregularity, 0), 1)
            // The same expression `DiskFrame.make` uses to seed the painted pattern, so a
            // galaxy's arms are in the same places in both.
            self.seed = Float(index) * 37.4 + 5.1
        }
    }

    /// How far along an arm a point sits: 0 between arms, 1 on a ridge. `extent` is the radius
    /// in scale lengths and `phi` the azimuth in the disk's own plane.
    ///
    /// Mirrored in `armWave` in `Shaders.swift`; the two must stay the same expression.
    public static func ridge(extent: Float, phi: Float, shape: Shape, phase: Float = 0) -> Float {
        let irregular = shape.irregularity
        let seed = shape.seed
        // An arm that does not hold its pitch. Without this every arm is the same curve at a
        // different angle and the eye reads the construction rather than the galaxy.
        let wander = (fractalNoise(extent * 1.5 + seed) - 0.5) * 2.6 * irregular
        let wound = phi - shape.windRate * log(max(extent, 1e-3)) - phase + wander

        let armPhase = shape.arms * wound
        var ridge = 0.5 + 0.5 * cos(armPhase)

        // Breaks along an arm: it thins, stops, and picks up again further round, which is
        // what every real arm does and what an unbroken curve never does.
        // Divided by its own mean, so that it redistributes the arm's strength along its
        // length instead of quietly taking a third of it away. Unnormalised, the irregular
        // pattern averaged 0.375 against the regular one's 0.500 and its ninetieth percentile
        // 0.744 against 0.976 — every arm weaker, which is not what irregular means.
        let breaks = (0.18 + 1.05 * fractalNoise(wound * 0.62 + extent * 0.9 + seed * 3.1)) / 0.705
        ridge *= 1 + irregular * (breaks - 1)

        // One arm is not the next. The noise turns over about once per arm, so each gets its
        // own strength and the pattern stops being something a rotation can repeat.
        let perArm = (0.35 + 1.25 * fractalNoise(armPhase * 0.159 + seed * 7.7)) / 0.975
        ridge *= 1 + irregular * (perArm - 1)

        // A spur: a short second arm at a different pitch, appearing where its own envelope
        // lets it and dying out again. Cubed, so it is a feature rather than a second full
        // pattern laid over the first.
        let spurPhase =
            (shape.arms + 3) * (phi - 1.7 * shape.windRate * log(max(extent, 1e-3)))
            + 2.1
        let spur = max(cos(spurPhase), 0)
        let spurWhere = fractalNoise(extent * 0.9 + seed * 2.3 + 31)
        ridge += irregular * 0.55 * spur * spur * spur * smoothstep(0.55, 0.85, spurWhere)

        // And the two halves of a disk are never equal. One arm's worth of asymmetry over the
        // whole pattern is the cheapest true thing to say about that, and it is what stops a
        // galaxy looking like a machined part.
        let lopsided = 1 + irregular * 0.30 * cos(phi + seed * 2.1)
        return min(max(ridge * lopsided, 0), 1)
    }

    private static func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
