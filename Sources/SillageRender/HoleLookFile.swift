import Foundation
import SillageCore

#if canImport(simd)
    import simd
#endif

/// How a black hole close up is drawn, as its scene folder keeps it in `look.json` (#332):
/// strict, as `LookFile` is, so a field this build does not know is an error rather than a
/// setting silently lost. Two ship in `looks/`: `physics`, the default (Pierre, 15 November),
/// and `film`, Interstellar's choices (docs/notes/black-hole-close-up.md).
public struct HoleLookFile: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public static let fileExtension = "hole.json"

    public enum Temperature: String, Codable, Sendable, CaseIterable {
        /// A thin disk's: T falls as r^-3/4 past the last stable orbit, whatever the gas does.
        case radius
        /// The run's: the heat the stream's crossings and the viscosity give each tracer.
        case crossing
    }

    /// Where the camera stands, in the hole's units and in degrees. It looks at the hole.
    public struct CameraPlan: Codable, Sendable, Equatable {
        /// Above the plane the cloud falls in.
        public var elevation: Double = 25
        /// Round the hole, from below the plane's y axis, anticlockwise seen from above.
        public var azimuth: Double = 0
        /// From the hole, in Schwarzschild radii.
        public var distance: Double = 75
        /// Vertical, in degrees.
        public var fieldOfView: Double = 40
        /// Turns round the hole over the video, 0 for a camera that stays.
        public var turns: Double = 0

        public init() {}

        public init(from decoder: any Decoder) throws {
            try rejectUnknownFields(decoder, CodingKeys.self)
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Self()
            elevation = try c.decodeIfPresent(Double.self, forKey: .elevation) ?? d.elevation
            azimuth = try c.decodeIfPresent(Double.self, forKey: .azimuth) ?? d.azimuth
            distance = try c.decodeIfPresent(Double.self, forKey: .distance) ?? d.distance
            fieldOfView = try c.decodeIfPresent(Double.self, forKey: .fieldOfView) ?? d.fieldOfView
            turns = try c.decodeIfPresent(Double.self, forKey: .turns) ?? d.turns
        }

        /// The camera `progress` of the way through the video, from 0 to 1.
        public func camera(progress: Double) -> Camera {
            let elevation = Float(self.elevation * .pi / 180)
            let azimuth = Float((self.azimuth + 360 * turns * progress) * .pi / 180)
            let eye =
                SIMD3<Float>(cos(elevation) * sin(azimuth), -cos(elevation) * cos(azimuth), sin(elevation))
                * Float(distance)
            return Camera(
                eye: eye, target: .zero, up: SIMD3<Float>(0, 0, 1),
                fieldOfView: Float(fieldOfView * .pi / 180), near: 0.1, far: 100_000)
        }
    }

    public var version = Self.currentVersion
    public var name: String
    /// Bent by the hole, or drawn straight with the shadow hiding what is behind it.
    public var lensed = true
    /// Images drawn: 1 the direct one, 2 with the one round the far side of the hole, 3 with
    /// the photon ring.
    public var images = 2
    public var temperature = Temperature.crossing
    /// Kelvin at the hottest: the thin disk's peak, or the run's brightest few per thousand.
    public var hottest: Double = 6500
    /// 1 for the Doppler shift and the redshift of climbing out as they are, 0 for none.
    public var beaming: Double = 1
    public var exposure: Double = 1
    /// The run's moment whose light sets the exposure and the temperatures for the whole video,
    /// in the hole's time units, so the light rises and falls with the run's. Absent, each
    /// frame is normalised on its own, eased from the one before.
    public var exposureAt: Double? = 3000
    /// Light every tracer gives whatever its heat, so that a cold stream still shows, dim and red.
    public var ambient: Double = 0.02
    /// A tracer's kernel, in Schwarzschild radii.
    public var particleSize: Double = 0.05
    /// Field stars far behind the hole, bent by it as the disk is.
    public var stars = 8000
    public var starBrightness: Double = 1
    /// The post stages' tone, Sillage's own when absent (`HoleLook.settings`).
    public var stretch: Double?
    public var bloom: Double?
    public var whitePoint: Double?
    public var saturation: Double?
    public var camera = CameraPlan()

    public init(name: String) { self.name = name }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownFields(decoder, CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var file = Self(name: try c.decode(String.self, forKey: .name))
        file.version = try c.decode(Int.self, forKey: .version)
        file.lensed = try c.decodeIfPresent(Bool.self, forKey: .lensed) ?? file.lensed
        file.images = try c.decodeIfPresent(Int.self, forKey: .images) ?? file.images
        file.temperature = try c.decodeIfPresent(Temperature.self, forKey: .temperature) ?? file.temperature
        file.hottest = try c.decodeIfPresent(Double.self, forKey: .hottest) ?? file.hottest
        file.beaming = try c.decodeIfPresent(Double.self, forKey: .beaming) ?? file.beaming
        file.exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? file.exposure
        file.exposureAt =
            c.contains(.exposureAt)
            ? try c.decodeIfPresent(Double.self, forKey: .exposureAt) : file.exposureAt
        file.ambient = try c.decodeIfPresent(Double.self, forKey: .ambient) ?? file.ambient
        file.particleSize = try c.decodeIfPresent(Double.self, forKey: .particleSize) ?? file.particleSize
        file.stars = try c.decodeIfPresent(Int.self, forKey: .stars) ?? file.stars
        file.starBrightness =
            try c.decodeIfPresent(Double.self, forKey: .starBrightness) ?? file.starBrightness
        file.stretch = try c.decodeIfPresent(Double.self, forKey: .stretch)
        file.bloom = try c.decodeIfPresent(Double.self, forKey: .bloom)
        file.whitePoint = try c.decodeIfPresent(Double.self, forKey: .whitePoint)
        file.saturation = try c.decodeIfPresent(Double.self, forKey: .saturation)
        file.camera = try c.decodeIfPresent(CameraPlan.self, forKey: .camera) ?? file.camera
        self = file
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(name, forKey: .name)
        try c.encode(lensed, forKey: .lensed)
        try c.encode(images, forKey: .images)
        try c.encode(temperature, forKey: .temperature)
        try c.encode(hottest, forKey: .hottest)
        try c.encode(beaming, forKey: .beaming)
        try c.encode(exposure, forKey: .exposure)
        // Written null when absent, so that a file says it normalises each frame on its own.
        try c.encode(exposureAt, forKey: .exposureAt)
        try c.encode(ambient, forKey: .ambient)
        try c.encode(particleSize, forKey: .particleSize)
        try c.encode(stars, forKey: .stars)
        try c.encode(starBrightness, forKey: .starBrightness)
        try c.encodeIfPresent(stretch, forKey: .stretch)
        try c.encodeIfPresent(bloom, forKey: .bloom)
        try c.encodeIfPresent(whitePoint, forKey: .whitePoint)
        try c.encodeIfPresent(saturation, forKey: .saturation)
        try c.encode(camera, forKey: .camera)
    }

    enum CodingKeys: String, CodingKey {
        case version, name, lensed, images, temperature, hottest, beaming, exposure, exposureAt,
            ambient, particleSize, stars, starBrightness, stretch, bloom, whitePoint, saturation,
            camera
    }

    public enum ReadError: Error, CustomStringConvertible, Equatable {
        case unsupportedVersion(Int)
        case badValue(String)

        public var description: String {
            switch self {
            case .unsupportedVersion(let version):
                "black hole look version \(version), this build reads \(HoleLookFile.currentVersion)"
            case .badValue(let detail): "black hole look: \(detail)"
            }
        }
    }

    public func validate() throws {
        guard (1...3).contains(images) else { throw ReadError.badValue("images is 1, 2 or 3") }
        guard hottest > 0, exposure > 0, particleSize > 0 else {
            throw ReadError.badValue("hottest, exposure and particleSize are above 0")
        }
        guard (0...1).contains(beaming) else { throw ReadError.badValue("beaming is from 0 to 1") }
        guard camera.distance > 1.5, camera.fieldOfView > 0, camera.fieldOfView < 180 else {
            throw ReadError.badValue("the camera stands outside the hole and sees less than 180°")
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self) + Data("\n".utf8)
    }

    public static func decoded(from data: Data) throws -> HoleLookFile {
        let file = try JSONDecoder().decode(HoleLookFile.self, from: data)
        guard file.version == currentVersion else { throw ReadError.unsupportedVersion(file.version) }
        try file.validate()
        return file
    }

    /// The default: the stream's own heat at its crossings, the Doppler shift and the redshift
    /// as they are, and the photon ring.
    public static let physics: HoleLookFile = {
        var look = HoleLookFile(name: "physics")
        look.images = 3
        return look
    }()

    /// Interstellar's: the thin disk's temperature from the radius, gold at 6500 K, and no
    /// Doppler beaming, as the film took it out.
    public static let film: HoleLookFile = {
        var look = HoleLookFile(name: "film")
        look.temperature = .radius
        look.beaming = 0
        return look
    }()

    public static let catalogue = [physics, film]
    public static let defaultName = physics.name
}
