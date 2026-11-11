/// What the dust web's passes read of the frame; mirrors `WebUniforms` in `Shaders`.
public struct WebUniforms: Sendable {
    /// The eye, and how much of the web is drawn.
    public var eye: SIMD4<Float>
    /// The camera's right, and how much wider a grain is drawn under the web.
    public var right: SIMD4<Float>
    /// The camera's up, and the simulated time.
    public var up: SIMD4<Float>
    /// Rest phase, cell in scale lengths, smallest and largest cell in kpc.
    public var params: SIMD4<Float>
    /// The camera's forward, and the tangent of half the vertical field of view.
    public var forward: SIMD4<Float>
    /// The accumulation's width and height in pixels, its aspect, and one over the baked
    /// lace's mean.
    public var target: SIMD4<Float>
    /// How many times coarser the carrier is drawn, and the smallest grain it takes, in its
    /// own pixels.
    public var carrier: SIMD4<Float>
}

/// The dust web's tuning (#173, docs/notes/dust-web.md); what Metal draws it with (#200) is in
/// `DustWebMetal.swift`.
public enum DustWeb {
    /// Where in its life a copy of the web rests unsheared: at a quarter, the two copies of a
    /// cross-fade lean the same way and never cross-hatch.
    static let rest: Float = 0.25
    /// A cell of the web in scale lengths, and the smallest and largest it may be in kpc.
    static let cellShare: Float = 0.18
    static let smallestCell: Float = 0.4
    static let largestCell: Float = 1.6
    /// How much wider a grain is drawn under the web: wide enough for the grains to merge into
    /// one even layer, so the web and not the grains says where the dust is thin.
    static let carrier: Float = 2
    /// Texels on a side of the baked lace, which tiles every 64 cells (`laceTile` in the
    /// shader): about an accumulation pixel a texel on a disk filling a 2560 x 1440 canvas.
    public static let laceTexels = 4096
    /// How many times coarser than the frame the carrier is drawn, per axis, and the smallest
    /// grain it takes in its own pixels, under which a grain would fall between them.
    static let carrierCoarse = 2
    static let carrierSmallest: Float = 3
}
