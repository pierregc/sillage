import Foundation
import simd

/// The colours measured on one set of Hubble or Webb pictures (#125), read from
/// `references/telescope/<set>.json`. Region medians are nearly grey; the colour is in the most
/// saturated sixth of the pixels, so the tones kept are those `vivid` medians, in OKLab.
public struct TelescopeReference: Sendable, Equatable {
    public struct Tone: Sendable, Equatable {
        public var region: String
        /// `warm` or `cool`, as #125 splits them.
        public var side: String
        /// OKLab `(L, a, b)`.
        public var lab: SIMD3<Float>
        /// Share of the region's vivid pixels this side holds.
        public var share: Float
    }

    public var name: String
    public var tones: [Tone]
    /// The colours a galaxy's ramp is drawn from in the telescope world (#119), in OKLab.
    public var ramp: GalaxyColours.Regions?

    /// Tones that fewer than this share of a region's vivid pixels hold are noise.
    static let minimumShare: Float = 0.1
    /// Arc of hues a tone stands for in a family, either side of its own.
    static let hueWidth: Float = 20

    /// Reads one of #125's files. The sky and the tails are left out, being nothing a galaxy is
    /// tinted with.
    public init(data: Data, name: String) throws {
        struct Vivid: Decodable {
            var share: Float
            var median: SIMD3<Float>
        }
        struct Region: Decodable {
            var median: SIMD3<Float>?
            var vivid: [String: Vivid]?
        }
        struct File: Decodable { var regions: [String: Region] }
        let regions = try JSONDecoder().decode(File.self, from: data).regions
        func vivid(_ region: String, _ side: String) -> SIMD3<Float>? {
            regions[region]?.vivid?[side]?.median ?? regions[region]?.median
        }
        if let core = vivid("core", "warm"), let disk = regions["disk"]?.median,
            let young = vivid("knots", "cool"), let knot = vivid("knots", "warm")
        {
            ramp = GalaxyColours.Regions(
                core: core, disk: disk, outskirts: vivid("tails", "cool") ?? disk, young: young,
                knot: knot)
        }
        var tones: [Tone] = []
        for region in regions.keys.sorted() where region != "sky" && region != "tails" {
            for side in (regions[region]?.vivid ?? [:]).keys.sorted() {
                guard let vivid = regions[region]?.vivid?[side], vivid.share >= Self.minimumShare
                else { continue }
                tones.append(
                    Tone(region: region, side: side, lab: vivid.median, share: vivid.share))
            }
        }
        guard !tones.isEmpty else { throw PaletteGenerator.Failure.noFamily(.telescope, name) }
        self.name = name
        self.tones = tones
    }

    /// Hue and saturation without lightness, as the shader keeps them: the chromatic plane of
    /// `lab` scaled to the common lightness.
    static func plane(_ lab: SIMD3<Float>) -> SIMD2<Float> {
        SIMD2(lab.y, lab.z) * (PaletteGenerator.commonLightness / max(lab.x, 1e-4))
    }

    /// Distance from a linear sRGB colour to the nearest tone, at the common lightness.
    public func distance(to colour: SIMD3<Float>) -> Float {
        let point = Self.plane(OKLab.lab(colour))
        return tones.map { simd_distance(point, Self.plane($0.lab)) }.min() ?? .infinity
    }

    /// The set as a family to draw from: a hue arc around each tone, chroma over the range the
    /// tones span.
    public var family: PaletteFamily {
        var hues: [HueArc] = []
        var chroma: [Float] = []
        for tone in tones {
            let plane = Self.plane(tone.lab)
            var hue = atan2(plane.y, plane.x) * 180 / .pi
            if hue < 0 { hue += 360 }
            let from = wrapped(hue - Self.hueWidth)
            hues.append(HueArc(from, from + 2 * Self.hueWidth))
            chroma.append(simd_length(plane))
        }
        let low = max(chroma.min()! * 0.85, 0.05)
        let high = min(max(chroma.max()! * 1.1, low + 0.02), PaletteGenerator.maximumChroma)
        return PaletteFamily(
            name: name, world: .telescope, hues: hues, chroma: low...high, lightness: 0.8...0.95)
    }

    /// The sets in this repository's `references/telescope`.
    public static let repository = load(
        from: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("references/telescope"))

    /// Every `*.json` in `directory` that is a colour set, by file name; `marks.json` and
    /// anything else that is not one is skipped.
    public static func load(from directory: URL) -> [TelescopeReference] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.sorted()
            .compactMap { file in
                (try? Data(contentsOf: directory.appendingPathComponent(file))).flatMap {
                    try? TelescopeReference(data: $0, name: String(file.dropLast(5)))
                }
            }
    }
}
