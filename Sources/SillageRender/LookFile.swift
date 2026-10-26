import Foundation
import simd

/// Everything that decides the image and nothing that decides the physics, as it is kept on
/// disk: the look a frame is drawn with, the render settings that own buffers, the colour of
/// each galaxy and the camera.
///
/// Every field may be left out and takes its value from `standard`, which is what
/// `sillage-render` draws with when given no flags, so a file names only what it changes. A
/// field this build does not know is an error rather than silently ignored.
public struct LookFile: Codable, Sendable, Equatable {
    public static let currentVersion = 1

    public var version: Int
    public var name: String
    public var look: RenderLook
    public var starCount: Int
    public var supersample: Int
    public var bloomLevels: Int
    /// One fixed-size point per particle in its galaxy's tint through a single pass, and none
    /// of the stages the other fields tune.
    public var plain: Bool
    /// Strength of the density wave painted over each disk; zero leaves the particles as the
    /// solver put them.
    public var armStrength: Float
    /// One emission colour per galaxy, in scene order. A galaxy past its end keeps the colour
    /// its scene gives it.
    public var palette: [SIMD3<Float>]
    /// Where `palette` came from when a generator drew it. Left out by files written before,
    /// and never read to draw: the colours above are what the frame uses.
    public var paletteRecipe: Palette?
    public var camera: CameraPlan

    public struct CameraPlan: Codable, Sendable, Equatable {
        public enum Mode: String, Codable, Sendable {
            /// Framed on the whole scene, easing from the start angles to the end ones.
            case fixed
            /// Framed on every galaxy, following them as they move apart and together.
            case auto
            /// The `Cinematographer` places the camera and modulates the look.
            case director
            /// The director, from inside a disk.
            case immersed
        }

        public var mode: Mode
        public var elevation: Float
        /// Absent, the camera holds its start angle.
        public var elevationEnd: Float?
        public var azimuth: Float
        public var azimuthEnd: Float?
        public var zoom: Float
        /// Fraction of the particles the frame is sized to hold, so a few escapers do not
        /// shrink it.
        public var percentile: Float
        /// Radius framed, in kiloparsecs. Zero measures it on the first frame.
        public var radius: Float

        public init(
            mode: Mode = .fixed, elevation: Float = 1.15, elevationEnd: Float? = nil,
            azimuth: Float = 0, azimuthEnd: Float? = nil, zoom: Float = 1,
            percentile: Float = 0.98, radius: Float = 0
        ) {
            self.mode = mode
            self.elevation = elevation
            self.elevationEnd = elevationEnd
            self.azimuth = azimuth
            self.azimuthEnd = azimuthEnd
            self.zoom = zoom
            self.percentile = percentile
            self.radius = radius
        }

        public init(from decoder: any Decoder) throws {
            try rejectUnknownFields(decoder, CodingKeys.self)
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = CameraPlan()
            self.init(
                mode: try c.value(.mode, or: d.mode),
                elevation: try c.value(.elevation, or: d.elevation),
                elevationEnd: try c.decodeIfPresent(Float.self, forKey: .elevationEnd),
                azimuth: try c.value(.azimuth, or: d.azimuth),
                azimuthEnd: try c.decodeIfPresent(Float.self, forKey: .azimuthEnd),
                zoom: try c.value(.zoom, or: d.zoom),
                percentile: try c.value(.percentile, or: d.percentile),
                radius: try c.value(.radius, or: d.radius))
        }
    }

    public init(
        name: String = "standard", look: RenderLook = LookFile.standardLook,
        starCount: Int = 2500, supersample: Int = 2, bloomLevels: Int = 6, plain: Bool = false,
        armStrength: Float = 1, palette: [SIMD3<Float>] = [], paletteRecipe: Palette? = nil,
        camera: CameraPlan = CameraPlan()
    ) {
        version = Self.currentVersion
        self.name = name
        self.look = look
        self.starCount = starCount
        self.supersample = supersample
        self.bloomLevels = bloomLevels
        self.plain = plain
        self.armStrength = armStrength
        self.palette = palette
        self.paletteRecipe = paletteRecipe
        self.camera = camera
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownFields(decoder, CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = LookFile.standard
        self.init(
            name: try c.value(.name, or: d.name),
            look: try c.value(.look, or: d.look),
            starCount: try c.value(.starCount, or: d.starCount),
            supersample: try c.value(.supersample, or: d.supersample),
            bloomLevels: try c.value(.bloomLevels, or: d.bloomLevels),
            plain: try c.value(.plain, or: d.plain),
            armStrength: try c.value(.armStrength, or: d.armStrength),
            palette: try c.value(.palette, or: d.palette),
            paletteRecipe: try c.decodeIfPresent(Palette.self, forKey: .paletteRecipe),
            camera: try c.value(.camera, or: d.camera))
        version = try c.decode(Int.self, forKey: .version)
    }

    /// The look `sillage-render` has always drawn with when given no flags. Not
    /// `RenderLook.observatory`: the command line settled on more dust, a longer stretch and
    /// larger field stars than the app did.
    public static let standardLook = RenderLook(
        brightness: 0.15, dustStrength: 0.35, smoothingScale: 1.9, minimumKernel: 1.1,
        maximumKernel: 64, bloomThreshold: 0.55, bloomSoftKnee: 0.6, bloomIntensity: 0.22,
        stretch: 18, saturation: 2.8, whitePoint: 4.5, spikeArms: 6, spikeLength: 40,
        spikeIntensity: 0.14, skyLevel: 0.0008, noiseLevel: 0.0016, galaxyTint: 0.35,
        starSize: 1.6, armPersistence: 1, fieldOfView: 0.6)

    public static let standard = LookFile()

    /// Plain points and nothing else: no bloom, spikes, dust, sky, noise, field stars or
    /// painted arms, each galaxy in its own flat colour. For judging the dynamics alone.
    public static let raw = LookFile(
        name: "raw",
        look: RenderLook(
            brightness: 0.12, dustStrength: 0, smoothingScale: 0, minimumKernel: 1.5,
            maximumKernel: 1.5, bloomThreshold: 1, bloomSoftKnee: 0, bloomIntensity: 0,
            stretch: 0, saturation: 1, whitePoint: 4.5, spikeArms: 0, spikeLength: 0,
            spikeIntensity: 0, skyLevel: 0, noiseLevel: 0, galaxyTint: 1, starSize: 0,
            armPersistence: 0, fieldOfView: 0.6),
        starCount: 0, supersample: 1, bloomLevels: 1, plain: true, armStrength: 0,
        palette: [
            SIMD3(1.00, 0.62, 0.25), SIMD3(0.30, 0.70, 1.00), SIMD3(0.45, 1.00, 0.45),
            SIMD3(1.00, 0.40, 0.80), SIMD3(1.00, 0.95, 0.35), SIMD3(0.70, 0.50, 1.00),
        ],
        camera: CameraPlan(mode: .auto))

    public enum ReadError: Error, CustomStringConvertible {
        case unsupportedVersion(Int)

        public var description: String {
            switch self {
            case .unsupportedVersion(let version):
                "look file version \(version), this build reads \(LookFile.currentVersion)"
            }
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    public static func decoded(from data: Data) throws -> LookFile {
        let file = try JSONDecoder().decode(LookFile.self, from: data)
        guard file.version == currentVersion else {
            throw ReadError.unsupportedVersion(file.version)
        }
        return file
    }
}

extension KeyedDecodingContainer {
    func value<T: Decodable>(_ key: Key, or fallback: T) throws -> T {
        try decodeIfPresent(T.self, forKey: key) ?? fallback
    }
}

private struct AnyKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// A misspelt field would otherwise fall back to its default without a word.
func rejectUnknownFields<Keys: CodingKey>(_ decoder: any Decoder, _: Keys.Type) throws {
    let container = try decoder.container(keyedBy: AnyKey.self)
    if let stray = container.allKeys.first(where: { Keys(stringValue: $0.stringValue) == nil }) {
        throw DecodingError.dataCorruptedError(
            forKey: stray, in: container,
            debugDescription: "unknown field \"\(stray.stringValue)\"")
    }
}
