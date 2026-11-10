import SillageCore
#if canImport(simd)
    import simd
#endif

public struct RenderSettings: Sendable {
    public var width: Int
    public var height: Int
    /// Renders at this multiple of the output resolution, then box-filters down.
    public var supersample: Int
    /// Emission per particle, expressed per million particles. Normalising by count keeps a
    /// scene looking the same whether it runs at 500 000 particles or at 20 million.
    public var brightness: Float
    /// Optical depth per dust particle, expressed per million particles so a scene keeps the
    /// same column density whichever count it runs at.
    public var dustStrength: Float
    /// Number of foreground field stars.
    public var starCount: Int
    /// Point size of the field stars before their magnitude scaling.
    public var starSize: Float
    /// How many local interparticle spacings a particle's kernel spans. This is the whole of
    /// the softness control: it scales the stored length in the shader, so it costs nothing to
    /// change and never rebuilds the tree.
    public var smoothingScale: Float
    /// Smallest and largest kernel a particle may cover, in output pixels.
    public var minimumKernel: Float
    public var maximumKernel: Float
    public var bloomThreshold: Float
    public var bloomSoftKnee: Float
    public var bloomIntensity: Float
    public var bloomLevels: Int
    /// Strength of the logarithmic stretch applied before tone mapping. 0 disables it.
    public var stretch: Float
    /// 1 leaves colour untouched, above 1 pushes the two disks further apart in hue.
    public var saturation: Float
    /// How far above the disk's own level a core has to be before it reads as white. Raise it
    /// and a bright nucleus keeps falling off instead of flattening into a disc.
    public var whitePoint: Float
    /// Diffraction arms: 6 for a segmented mirror, 4 for a Cassegrain spider, 0 for none.
    public var spikeArms: Int
    public var spikeLength: Float
    public var spikeIntensity: Float
    public var spikePattern: RenderLook.SpikePattern
    public var spikeSharpness: Float
    /// Sky background and detector noise, both in linear signal units before tone mapping.
    public var skyLevel: Float
    /// Colour of the sky background, scaled by `skyLevel`.
    public var skyColour: SIMD3<Float>
    public var noiseLevel: Float
    /// How far the per-galaxy tint pulls the stars away from the colour their population
    /// implies. Zero is the physical answer; a little of it is what keeps stars torn out of
    /// one disk recognisable inside the other.
    public var galaxyTint: Float
    /// Radius in kpc of a black hole's dark dot, zero for none.
    public var holeShadow: Float = 0
    /// Stars a kernel covers in projection, 0 to size kernels from the 3D spacing alone.
    public var columnSmoothing: Float = 0
    /// Light kept by the compact bright minority, 1 as sampled.
    public var glint: Float = 1
    /// Share of the dust drawn as a web of filaments.
    public var dustWeb: Float = 0
    /// Draws the raw look: plain points and one pass, instead of the splat, dust and post
    /// stages. Fixed for the renderer's life, since it decides which pipelines get built.
    public var plain: Bool

    public init(
        width: Int = 1920,
        height: Int = 1080,
        supersample: Int = 2,
        brightness: Float = 0.15,
        dustStrength: Float = 0.055,
        starCount: Int = 46000,
        starSize: Float = 1.15,
        smoothingScale: Float = 1.9,
        minimumKernel: Float = 1.1,
        maximumKernel: Float = 64,
        bloomThreshold: Float = 0.55,
        bloomSoftKnee: Float = 0.6,
        bloomIntensity: Float = 0.22,
        bloomLevels: Int = 6,
        stretch: Float = 18,
        saturation: Float = 2.8,
        whitePoint: Float = 4.5,
        spikeArms: Int = 6,
        spikeLength: Float = 72,
        spikeIntensity: Float = 0.38,
        spikePattern: RenderLook.SpikePattern = .even,
        spikeSharpness: Float = 0,
        skyLevel: Float = 0.0018,
        skyColour: SIMD3<Float> = RenderLook.blueSky,
        noiseLevel: Float = 0.0016,
        galaxyTint: Float = 0.35,
        plain: Bool = false
    ) {
        self.width = width
        self.height = height
        self.supersample = max(1, min(supersample, 4))
        self.brightness = brightness
        self.dustStrength = dustStrength
        self.starCount = starCount
        self.starSize = starSize
        self.smoothingScale = smoothingScale
        self.minimumKernel = minimumKernel
        self.maximumKernel = maximumKernel
        self.bloomThreshold = bloomThreshold
        self.bloomSoftKnee = bloomSoftKnee
        self.bloomIntensity = bloomIntensity
        self.bloomLevels = bloomLevels
        self.stretch = stretch
        self.saturation = saturation
        self.whitePoint = whitePoint
        self.spikeArms = spikeArms
        self.spikeLength = spikeLength
        self.spikeIntensity = spikeIntensity
        self.spikePattern = spikePattern
        self.spikeSharpness = spikeSharpness
        self.skyLevel = skyLevel
        self.skyColour = skyColour
        self.noiseLevel = noiseLevel
        self.galaxyTint = galaxyTint
        self.plain = plain
    }
}
