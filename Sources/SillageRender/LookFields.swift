import Foundation

/// What each field of a `look.json` does (#464), printed by `sillage-render fields` with the
/// value a file that leaves the field out gets and the range the repository's looks use. A test
/// holds the lists to `LookFile`, `RenderLook` and the camera plan.
public enum LookFields {
    public static let file: [(String, String)] = [
        ("version", "the file format's version, 1"),
        ("name", "the look's name"),
        ("look", "the rendering, the fields below"),
        (
            "palette",
            "one entry per galaxy in scene order: a colour [r, g, b] in linear sRGB, or a ramp of them"
        ),
        ("paletteRecipe", "where a generated palette came from; never read to draw"),
        ("world", "the colour world: telescope or free"),
        ("camera", "the camera plan, below"),
        ("starCount", "field stars behind the scene"),
        ("galaxyCount", "small faint galaxies far behind the field stars; Metal only"),
        ("supersample", "renders at N times the size and reduces"),
        ("bloomLevels", "bloom mip levels"),
        ("plain", "one fixed-size point per particle in its galaxy's tint, a single pass"),
        (
            "armStrength",
            "strength of the density wave painted over each disk; 0 leaves the particles as the solver put them"
        ),
        ("overlay", "words over every video drawn with this look (title, clock, scale, captions)"),
        ("exposure", "brightness and stretch measured on the frames drawn; absent, the look's own"),
        (
            "sky",
            "a deep sky behind the dust, fixed in direction: {brightness, density, fieldOfView, height, depth, spikes, spikeAngle, galaxies, starWidth, seed}; Metal only"
        ),
        ("dither", "triangular noise of this many 8-bit steps on the frame, against banding; Metal only"),
    ]

    public static let look: [(String, String)] = [
        ("brightness", "overall exposure before the stretch"),
        ("stretch", "strength of the logarithmic stretch: higher lifts the faint tails"),
        ("whitePoint", "how bright a core must be to read white; higher keeps a hue in the bulge"),
        ("saturation", "colour saturation"),
        ("galaxyTint", "how much of each galaxy's palette colour is laid over its particles, 0 to 1"),
        ("dustStrength", "how much the dust absorbs"),
        ("dustWeb", "share of the dust drawn as filaments in each disk's plane, 0 to 1"),
        ("dustGlow", "how brightly the dust glows, as in a mid-infrared picture; 0 none (Metal only)"),
        ("dustGlowColour", "the glow's colour, linear sRGB"),
        (
            "dustReddening",
            "how much more the dust takes from blue and green than from red; 0 grey, 1 as drawn before, above browner (Metal only)"
        ),
        ("smoothingScale", "kernel width over the spacing between particles: higher is softer"),
        ("minimumKernel", "smallest kernel, in pixels"),
        ("maximumKernel", "largest kernel, in pixels"),
        ("columnSmoothing", "stars a kernel covers in projection; 0 sizes kernels from the 3D spacing alone"),
        ("oldWidth", "widens the old disk's kernels"),
        ("bulgeWidth", "widens the bulge's kernels"),
        ("youngWidth", "widens the kernels of stars under 300 Myr"),
        ("knotWidth", "widens the kernels of knots under 50 Myr"),
        ("dustWidth", "widens the dust grains' kernels, so a thin sheet of grains reads as a veil"),
        ("glint", "light kept by the compact bright minority: 1 as sampled, 0 ordinary stars"),
        ("starSize", "size of the field and point stars"),
        ("bloomIntensity", "bloom strength"),
        ("bloomThreshold", "brightness the bloom starts at"),
        ("bloomSoftKnee", "softness of the bloom's threshold"),
        ("spikeArms", "number of diffraction spike arms: 4 for Hubble, 6 for Webb"),
        ("spikePattern", "even (equal arms) or webb (one pair upright and two short horizontal ones)"),
        ("spikeLength", "spike length, in pixels"),
        ("spikeIntensity", "spike brightness"),
        ("spikeSharpness", "0 lets a whole bright core throw spikes, 1 only stars and point-like cores"),
        ("skyLevel", "brightness of the sky"),
        ("skyColour", "the sky's colour, linear sRGB, scaled by skyLevel"),
        ("noiseLevel", "film grain"),
        ("armPersistence", "strength of the painted density wave; above 1 the arms are invention"),
        ("fieldOfView", "vertical field of view, in radians"),
        ("holeShadow", "radius in kpc of the dark dot a black hole is drawn as; 0 none"),
    ]

    public static let camera: [(String, String)] = [
        (
            "mode",
            "fixed (framed on the whole scene), auto (every galaxy kept in frame), director (shots and cuts) or immersed (the director from inside a disk)"
        ),
        ("elevation", "start elevation above the orbital plane, in radians"),
        ("elevationEnd", "the elevation eased to by the end; absent, held"),
        ("azimuth", "start azimuth, in radians"),
        ("azimuthEnd", "the azimuth eased to by the end; absent, held"),
        ("zoom", "multiplies the framed size; above 1 closer"),
        ("percentile", "share of the particles the frame is sized to hold"),
        ("radius", "radius framed in kpc; 0 measures it on the first frame"),
        ("center", "where a fixed camera looks, [x, y, z] in kpc; absent, the centre of mass"),
        ("zoomKeys", "[[progress 0 to 1, factor], ...]: the zoom eased along the take, multiplying zoom"),
    ]

    /// The value a field takes when a file leaves it out, as it would be written.
    static func defaults(of value: Any) -> [String: String] {
        var out: [String: String] = [:]
        for child in Mirror(reflecting: value).children {
            guard let label = child.label else { continue }
            out[label] = describe(child.value)
        }
        return out
    }

    static func describe(_ value: Any) -> String {
        switch value {
        case let v as Float: return String(format: "%g", v)
        case let v as Double: return String(format: "%g", v)
        case let v as SIMD3<Float>: return String(format: "[%g, %g, %g]", v.x, v.y, v.z)
        case let v as Bool: return v ? "true" : "false"
        case let v as Int: return "\(v)"
        default:
            let text = "\(value)"
            if text == "nil" || text.hasPrefix("Optional") { return "absent" }
            if text.contains("(") || text.contains("[") { return "" }
            return text
        }
    }

    /// The smallest and largest value of each number of `look` in the given look files.
    static func ranges(of files: [URL]) -> [String: (Double, Double)] {
        var out: [String: (Double, Double)] = [:]
        for url in files {
            guard let data = try? Data(contentsOf: url),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let look = json["look"] as? [String: Any]
            else { continue }
            for (key, value) in look {
                guard let number = (value as? NSNumber)?.doubleValue, !(value is Bool) else { continue }
                let (low, high) = out[key] ?? (number, number)
                out[key] = (min(low, number), max(high, number))
            }
        }
        return out
    }

    /// The text `sillage-render fields` prints; `catalogue` is the repository's looks/.
    public static func text(catalogue: URL?) -> String {
        let files =
            catalogue.flatMap {
                try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)
            }?.filter { $0.lastPathComponent.hasSuffix(".look.json") } ?? []
        let seen = ranges(of: files)
        func section(
            _ title: String, _ fields: [(String, String)], _ defaults: [String: String], ranged: Bool
        )
            -> [String]
        {
            var lines = ["", title]
            for (key, about) in fields {
                var line = "  " + key.padding(toLength: 17, withPad: " ", startingAt: 0) + about
                var notes: [String] = []
                if let value = defaults[key], !value.isEmpty { notes.append("default \(value)") }
                if ranged, let (low, high) = seen[key], low != high {
                    notes.append(String(format: "looks/ use %g to %g", low, high))
                }
                if !notes.isEmpty { line += " (" + notes.joined(separator: ", ") + ")" }
                lines.append(line)
            }
            return lines
        }
        var lines = [
            "A look file, <name>.look.json: everything that decides the image. A field left out takes",
            "the default below, so a file names only what it changes; a field this build does not know",
            "is refused.",
        ]
        lines += section("Top level", file, defaults(of: LookFile()), ranged: false)
        lines += section(
            "\"look\": the rendering"
                + (files.isEmpty ? "" : ", with the range of the \(files.count) looks of looks/"),
            look, defaults(of: LookFile.omittedLook), ranged: true)
        lines += section(
            "\"camera\": the camera plan", camera, defaults(of: LookFile.CameraPlan()), ranged: false)
        return lines.joined(separator: "\n")
    }
}
