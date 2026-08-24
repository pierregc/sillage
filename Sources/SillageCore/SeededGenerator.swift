import Foundation

/// SplitMix64. Reproducible across platforms so a seed fully determines a scene.
public struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    public mutating func uniform() -> Float {
        Float(next() >> 40) * 0x1p-24
    }

    public mutating func uniform(in range: ClosedRange<Float>) -> Float {
        range.lowerBound + uniform() * (range.upperBound - range.lowerBound)
    }

    /// Standard normal via Box-Muller.
    public mutating func normal() -> Float {
        let u1 = max(uniform(), .leastNormalMagnitude)
        let u2 = uniform()
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }
}
