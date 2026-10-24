import simd

/// The simplest camera that never loses a galaxy: centred between them, backed off just far
/// enough to hold every one with its disk, and eased so a pair drawing apart does not make
/// the frame lurch.
public struct AutoCamera: Sendable {
    private var center: SIMD3<Float>?
    private var radius: Float = 0

    /// How much of the way to the target the centre covers each frame, and how fast the frame
    /// closes in when the galaxies draw together. Opening up is immediate.
    static let follow: Float = 0.1
    static let settle: Float = 0.04

    public init() {}

    /// `margins` is how far each galaxy reaches from its centre.
    public mutating func frame(
        centres: [SIMD3<Float>], margins: [Float]
    ) -> (center: SIMD3<Float>, radius: Float) {
        guard let first = centres.first else { return (center ?? .zero, max(radius, 1)) }
        var low = first
        var high = first
        for position in centres {
            low = simd_min(low, position)
            high = simd_max(high, position)
        }
        let middle = (low + high) / 2
        let current = center.map { $0 + (middle - $0) * Self.follow } ?? middle
        var needed: Float = 0
        for (index, position) in centres.enumerated() {
            let margin = index < margins.count ? margins[index] : margins.last ?? 0
            needed = max(needed, simd_distance(position, current) + margin)
        }
        radius = center == nil || needed > radius ? needed : radius + (needed - radius) * Self.settle
        center = current
        return (current, max(radius, 1))
    }
}
