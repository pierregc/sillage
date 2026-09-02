import SillageCore
import simd

/// The part of the render settings a frame can change on its own, without rebuilding
/// anything. Every field here is already read per frame by `present`; the ones left out —
/// resolution, supersampling, the number of bloom levels, the size of the starfield — own
/// textures and buffers, and changing those means building a new renderer.
///
/// Gathered into one value so a look can be crossfaded rather than nudged one setter at a
/// time.
public struct RenderLook: Sendable, Equatable {
    public var brightness: Float
    public var dustStrength: Float
    public var smoothingScale: Float
    public var minimumKernel: Float
    public var maximumKernel: Float
    public var bloomThreshold: Float
    public var bloomSoftKnee: Float
    public var bloomIntensity: Float
    public var stretch: Float
    public var saturation: Float
    /// How far above the disk a core has to be before it reads as white. The tone curve maps
    /// this value to one and everything under it keeps a hue, so raising it is what stops a
    /// bulge flattening into a featureless white disc.
    public var whitePoint: Float
    public var spikeArms: Int
    public var spikeLength: Float
    public var spikeIntensity: Float
    public var skyLevel: Float
    public var noiseLevel: Float
    public var galaxyTint: Float
    public var starSize: Float
    /// Strength of the painted density wave. Above one the arms are frank invention, which is
    /// the whole point of the dreamier looks.
    public var armPersistence: Float
    public var fieldOfView: Float

    public init(
        brightness: Float = 0.15,
        dustStrength: Float = 0.12,
        smoothingScale: Float = 1.5,
        minimumKernel: Float = 1.1,
        maximumKernel: Float = 64,
        bloomThreshold: Float = 0.55,
        bloomSoftKnee: Float = 0.6,
        bloomIntensity: Float = 0.22,
        stretch: Float = 14,
        saturation: Float = 2.2,
        whitePoint: Float = 4.5,
        spikeArms: Int = 6,
        spikeLength: Float = 72,
        spikeIntensity: Float = 0.38,
        skyLevel: Float = 0.0032,
        noiseLevel: Float = 0.0016,
        galaxyTint: Float = 0.5,
        starSize: Float = 1.15,
        armPersistence: Float = 1,
        fieldOfView: Float = 0.6
    ) {
        self.brightness = brightness
        self.dustStrength = dustStrength
        self.smoothingScale = smoothingScale
        self.minimumKernel = minimumKernel
        self.maximumKernel = maximumKernel
        self.bloomThreshold = bloomThreshold
        self.bloomSoftKnee = bloomSoftKnee
        self.bloomIntensity = bloomIntensity
        self.stretch = stretch
        self.saturation = saturation
        self.whitePoint = whitePoint
        self.spikeArms = spikeArms
        self.spikeLength = spikeLength
        self.spikeIntensity = spikeIntensity
        self.skyLevel = skyLevel
        self.noiseLevel = noiseLevel
        self.galaxyTint = galaxyTint
        self.starSize = starSize
        self.armPersistence = armPersistence
        self.fieldOfView = fieldOfView
    }

    public static func mix(_ a: RenderLook, _ b: RenderLook, _ t: Float) -> RenderLook {
        let u = min(max(t, 0), 1)
        func f(_ x: Float, _ y: Float) -> Float { x + (y - x) * u }
        var out = RenderLook()
        out.brightness = f(a.brightness, b.brightness)
        out.dustStrength = f(a.dustStrength, b.dustStrength)
        out.smoothingScale = f(a.smoothingScale, b.smoothingScale)
        out.minimumKernel = f(a.minimumKernel, b.minimumKernel)
        out.maximumKernel = f(a.maximumKernel, b.maximumKernel)
        out.bloomThreshold = f(a.bloomThreshold, b.bloomThreshold)
        out.bloomSoftKnee = f(a.bloomSoftKnee, b.bloomSoftKnee)
        out.bloomIntensity = f(a.bloomIntensity, b.bloomIntensity)
        out.stretch = f(a.stretch, b.stretch)
        out.saturation = f(a.saturation, b.saturation)
        out.whitePoint = f(a.whitePoint, b.whitePoint)
        // Arms are a count, and crossfading their intensity through zero is what keeps the
        // change of one from showing as a flicker.
        out.spikeArms = u < 0.5 ? a.spikeArms : b.spikeArms
        out.spikeLength = f(a.spikeLength, b.spikeLength)
        out.spikeIntensity =
            a.spikeArms == b.spikeArms
            ? f(a.spikeIntensity, b.spikeIntensity)
            : (u < 0.5 ? f(a.spikeIntensity, 0) * (1 - 2 * u) : f(0, b.spikeIntensity))
        out.skyLevel = f(a.skyLevel, b.skyLevel)
        out.noiseLevel = f(a.noiseLevel, b.noiseLevel)
        out.galaxyTint = f(a.galaxyTint, b.galaxyTint)
        out.starSize = f(a.starSize, b.starSize)
        out.armPersistence = f(a.armPersistence, b.armPersistence)
        out.fieldOfView = f(a.fieldOfView, b.fieldOfView)
        return out
    }

    /// What the telescope would actually record: modest bloom, honest colour, the diffraction
    /// pattern of a segmented mirror.
    public static let observatory = RenderLook()

    /// Everything soft and enormous. Kernels wide enough that the particles stop being
    /// particles and the disk reads as luminous cloud.
    public static let dream = RenderLook(
        brightness: 0.22, dustStrength: 0.06, smoothingScale: 3.0, minimumKernel: 1.9,
        maximumKernel: 96, bloomThreshold: 0.28, bloomSoftKnee: 0.9, bloomIntensity: 0.62,
        stretch: 26, saturation: 3.0, spikeArms: 0, spikeLength: 40, spikeIntensity: 0,
        skyLevel: 0.004, noiseLevel: 0.0008, galaxyTint: 0.85, starSize: 1.5,
        armPersistence: 1.6, fieldOfView: 0.75)

    /// Hard and bright: small kernels, a long stretch and a wide diffraction pattern, so the
    /// disk reads as a field of individual glints.
    public static let gloss = RenderLook(
        brightness: 0.13, dustStrength: 0.16, smoothingScale: 0.85, minimumKernel: 0.8,
        maximumKernel: 24, bloomThreshold: 0.72, bloomSoftKnee: 0.25, bloomIntensity: 0.5,
        stretch: 8, saturation: 2.0, spikeArms: 4, spikeLength: 130, spikeIntensity: 0.72,
        skyLevel: 0.0016, noiseLevel: 0.0022, galaxyTint: 0.42, starSize: 1.5,
        armPersistence: 0.7, fieldOfView: 0.5)

    /// Deep and nearly monochrome, the sky pulled almost to black. For the wide shots, where
    /// what is being looked at is mostly the emptiness around the thing.
    public static let ink = RenderLook(
        brightness: 0.17, dustStrength: 0.24, smoothingScale: 1.9, minimumKernel: 0.95,
        maximumKernel: 58, bloomThreshold: 0.6, bloomSoftKnee: 0.4, bloomIntensity: 0.3,
        stretch: 20, saturation: 1.15, spikeArms: 6, spikeLength: 90, spikeIntensity: 0.3,
        skyLevel: 0.0009, noiseLevel: 0.0011, galaxyTint: 0.3, starSize: 1.0,
        armPersistence: 1.0, fieldOfView: 0.62)

    /// Warm and heavy, dust doing most of the drawing.
    public static let ember = RenderLook(
        brightness: 0.2, dustStrength: 0.35, smoothingScale: 2.3, minimumKernel: 1.3,
        maximumKernel: 80, bloomThreshold: 0.4, bloomSoftKnee: 0.75, bloomIntensity: 0.46,
        stretch: 23, saturation: 2.6, spikeArms: 0, spikeLength: 60, spikeIntensity: 0,
        skyLevel: 0.0026, noiseLevel: 0.0014, galaxyTint: 0.7, starSize: 1.25,
        armPersistence: 1.3, fieldOfView: 0.68)

    /// Toned down for an unattended full screen. Long spikes are gathered from the already
    /// blurred bloom source, so at a hundred and thirty pixels they stop being spikes and
    /// become soft cones fixed to the screen while the stars slide underneath them — which is
    /// what they look like: a defect, not an instrument. Field stars come down with them.
    public func calm() -> RenderLook {
        var out = self
        out.spikeLength = min(spikeLength, 34)
        out.spikeIntensity = min(spikeIntensity, 0.2)
        out.starSize = min(starSize, 1.0)
        return out
    }

    public static let all: [RenderLook] = [observatory, dream, gloss, ink, ember]

    /// The same five with names, for anything that has to offer them.
    public struct Named: Sendable, Identifiable {
        public let id: String
        public let name: String
        public let look: RenderLook
    }

    public static let catalogue: [Named] = [
        Named(id: "observatory", name: "Observatoire", look: .observatory),
        Named(id: "dream", name: "Onirique", look: .dream),
        Named(id: "gloss", name: "Éclat", look: .gloss),
        Named(id: "ink", name: "Encre", look: .ink),
        Named(id: "ember", name: "Braise", look: .ember),
    ]
}
