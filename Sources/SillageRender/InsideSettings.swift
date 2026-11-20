import SillageCore
import simd

/// Spike #296: what drawing from inside a galaxy changes, all neutral by default.
public struct InsideSettings: Sendable, Codable, Equatable {
    /// Kernel lengths over which a particle fades before the near plane; 0 for none.
    public var nearFadeLengths: Float = 0
    /// 0 keeps all of a capped kernel's light, 1 the surface brightness of its own size.
    public var capLaw: UInt32 = 0
    /// Point stars cross-fade in between these shares of the kernel's cap; 0 for none.
    public var starStart: Float = 0
    public var starEnd: Float = 0
    public var starCount: Int = 0
    /// Scatter radius in kernel lengths.
    public var starSpread: Float = 1
    /// Output pixels.
    public var starPointSize: Float = 1.5
    /// 0 shares the light equally, otherwise rank^-exponent.
    public var starShareExponent: Float = 0
    public var starColours: Float = 0
    /// Distance in kpc under which a point star stops brightening.
    public var starNearest: Float = 0.001
    public var starCap: Float = 30_000
    /// Scatter radius in kpc for every particle, 0 to follow its kernel.
    public var starRadius: Float = 0
    /// Dust slab boundaries from the eye, log-spaced from `slabFirst` by `slabRatio`; 0 keeps
    /// them around the aim point.
    public var slabFirst: Float = 0
    public var slabRatio: Float = 3.33
    public var slabSoft: UInt32 = 0
    /// Point stars only nearer than `starFarKpc`, all of them nearer than `starNearKpc`; 0 for
    /// no distance window.
    public var starNearKpc: Float = 0
    public var starFarKpc: Float = 0

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func read<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try c.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        let d = InsideSettings()
        nearFadeLengths = try read(.nearFadeLengths, d.nearFadeLengths)
        capLaw = try read(.capLaw, d.capLaw)
        starStart = try read(.starStart, d.starStart)
        starEnd = try read(.starEnd, d.starEnd)
        starCount = try read(.starCount, d.starCount)
        starSpread = try read(.starSpread, d.starSpread)
        starPointSize = try read(.starPointSize, d.starPointSize)
        starShareExponent = try read(.starShareExponent, d.starShareExponent)
        starColours = try read(.starColours, d.starColours)
        starNearest = try read(.starNearest, d.starNearest)
        starCap = try read(.starCap, d.starCap)
        starRadius = try read(.starRadius, d.starRadius)
        slabFirst = try read(.slabFirst, d.slabFirst)
        slabRatio = try read(.slabRatio, d.slabRatio)
        slabSoft = try read(.slabSoft, d.slabSoft)
        starNearKpc = try read(.starNearKpc, d.starNearKpc)
        starFarKpc = try read(.starFarKpc, d.starFarKpc)
    }

    func apply(to uniforms: inout SplatUniforms, camera: Camera, supersample: Int) {
        uniforms.nearPlane = camera.near
        uniforms.nearFadeLengths = nearFadeLengths
        uniforms.capLaw = capLaw
        uniforms.starStart = starStart
        uniforms.starEnd = starEnd
        uniforms.starCount = UInt32(max(starCount, 0))
        uniforms.starSpread = starSpread
        uniforms.starPointSize = max(starPointSize * Float(supersample), 1)
        uniforms.starShareExponent = starShareExponent
        if starShareExponent > 0, starCount > 0 {
            let total = (1...starCount).reduce(Float(0)) { $0 + pow(Float($1), -starShareExponent) }
            uniforms.starShareNorm = 1 / total
        }
        uniforms.starColours = starColours
        uniforms.starNearest = starNearest
        uniforms.starCap = starCap
        uniforms.starRadius = starRadius
        uniforms.slabSoft = slabSoft
        uniforms.starNearKpc = starNearKpc
        uniforms.starFarKpc = starFarKpc
        if slabFirst > 0 {
            uniforms.slabLog = 1
            uniforms.slabNear = slabFirst
            uniforms.slabScale = 1 / log(max(slabRatio, 1.01))
        }
    }
}
