import Foundation
import SillageCore
import simd

/// Spike for #118: several colours per galaxy, on only when `SILLAGE_COLOURS` names a mapping.
///
/// Each particle gets a static key from what it carries (birth radius, component or age), and
/// each galaxy a ramp of colours from its world; the shader looks the key up in the ramp and
/// blends the result with the population colour.
public struct GalaxyColourSpike: Sendable {
    public enum Mapping: String, Sendable, CaseIterable {
        /// Today's shader, with the take's birth radius measured from each galaxy's centre.
        case fixed
        case radius, component, population, mix
    }

    public var mapping: Mapping
    public var world: Palette.World
    /// 0 keeps the population colour, 1 draws the mapped colour alone.
    public var blend: Float
    /// Free world: the family whose other arc colours the outskirts.
    public var family: String?
    /// Telescope world: the colours measured on this reference set.
    public var reference: TelescopeSet?
    /// Telescope world: how far each galaxy's own palette colour tints its ramp.
    public var identity: Float

    public var paints: Bool { mapping != .fixed }

    public static func fromEnvironment() -> GalaxyColourSpike? {
        let env = ProcessInfo.processInfo.environment
        guard let name = env["SILLAGE_COLOURS"], let mapping = Mapping(rawValue: name) else {
            return nil
        }
        let world = env["SILLAGE_COLOUR_WORLD"].flatMap(Palette.World.init) ?? .free
        let set = env["SILLAGE_COLOUR_SET"] ?? "hubble-visible"
        return GalaxyColourSpike(
            mapping: mapping, world: world,
            blend: env["SILLAGE_COLOUR_BLEND"].flatMap(Float.init) ?? 0.75,
            family: env["SILLAGE_COLOUR_FAMILY"],
            reference: world == .telescope ? TelescopeSet.load(set) : nil,
            identity: env["SILLAGE_COLOUR_IDENTITY"].flatMap(Float.init) ?? 0.3)
    }

    /// Ramp stops along the key, in scale lengths for the radius.
    static let outerScaleLengths: Float = 4.5
    static let youngMyr: Float = 30
    static let oldMyr: Float = 10_000

    /// One key per particle: below zero asks for the galaxy's young colour.
    public func keys(of particles: ParticleSystem) -> [Float] {
        let count = particles.count
        let radii = particles.birthRadius.count == count ? particles.birthRadius : []
        var scale: [UInt32: Float] = [:]
        if !radii.isEmpty {
            var byGalaxy: [UInt32: [Float]] = [:]
            for index in 0..<count where particles.component[index] == 0 {
                byGalaxy[particles.galaxyIndex[index], default: []].append(radii[index])
            }
            for (galaxy, values) in byGalaxy {
                let sorted = values.sorted()
                scale[galaxy] = max(sorted[sorted.count / 2] / 1.678, 1e-3)
            }
        }
        let mpu = Float(Physics.megayearsPerTimeUnit)
        let span = log(Self.oldMyr / Self.youngMyr)
        return (0..<count).map { index in
            let kind = ParticleComponent(rawValue: particles.component[index]) ?? .star
            let born = index < particles.formation.count ? particles.formation[index] : -1e9
            let formedInRun = born >= 0 && born < 1e8
            let radial: Float = {
                guard !radii.isEmpty, let s = scale[particles.galaxyIndex[index]] else { return 0.5 }
                return min(radii[index] / s / Self.outerScaleLengths, 1)
            }()
            switch mapping {
            case .fixed, .radius:
                return radial
            case .component:
                if formedInRun { return -1 }
                switch kind {
                case .bulge: return 0
                case .outskirt: return 1
                case .hiiRegion, .dust: return -1
                default: return 0.5
                }
            case .population:
                if formedInRun || born > 1e8 { return 0 }
                let age = born < -1e8 ? Self.oldMyr : -born * mpu
                return min(max(log(max(age, 1) / Self.youngMyr) / span, 0), 1)
            case .mix:
                if formedInRun { return -1 }
                switch kind {
                case .bulge: return 0
                case .outskirt: return 1
                case .hiiRegion, .dust: return -1
                default: return radial
                }
            }
        }
    }

    /// One ramp per galaxy from its palette colour.
    func ramps(tints: [SIMD3<Float>]) -> [GalaxyRamp] {
        tints.map { tint in
            let set = colours(for: tint)
            let discrete: Float = mapping == .component ? 1 : 0
            var stops: [SIMD4<Float>]
            switch mapping {
            case .population:
                stops = [
                    stop(set.young, 0), stop(set.body, 0.55), stop(set.body, 0.8),
                    stop(set.core, 1),
                ]
            case .component:
                stops = [stop(set.core, 0), stop(set.body, 0.5), stop(set.body, 0.5), stop(set.outer, 1)]
            default:
                let o = Self.outerScaleLengths
                stops = [
                    stop(set.core, 0), stop(set.body, 1.0 / o), stop(set.body, 2.4 / o),
                    stop(set.outer, 1),
                ]
            }
            return GalaxyRamp(
                stop0: stops[0], stop1: stops[1], stop2: stops[2], stop3: stops[3],
                young: SIMD4(set.young, 0), knot: SIMD4(set.knot, 0),
                params: SIMD4(blend, discrete, 0, 0))
        }
    }

    private func stop(_ colour: SIMD3<Float>, _ at: Float) -> SIMD4<Float> { SIMD4(colour, at) }

    /// Each galaxy's colours as hex, scaled so the brightest channel is one.
    public func describe(tints: [SIMD3<Float>]) -> [String] {
        func hex(_ c: SIMD3<Float>) -> String {
            let v = c / max(c.max(), 1e-6)
            func g(_ x: Float) -> Int {
                let s = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
                return Int((min(max(s, 0), 1) * 255).rounded())
            }
            return String(format: "#%02x%02x%02x", g(v.x), g(v.y), g(v.z))
        }
        return tints.map { tint in
            let c = colours(for: tint)
            return "tint \(hex(tint)) core \(hex(c.core)) body \(hex(c.body)) outer \(hex(c.outer))"
                + " young \(hex(c.young)) knot \(hex(c.knot))"
        }
    }

    struct Colours {
        var core, body, outer, young, knot: SIMD3<Float>
    }

    /// Unit luminance, as every emitter in the shader.
    static func normalised(_ rgb: SIMD3<Float>) -> SIMD3<Float> {
        let c = simd_max(rgb, SIMD3(repeating: 0))
        return c / max(simd_dot(c, SIMD3(0.2126, 0.7152, 0.0722)), 1e-4)
    }

    func colours(for tint: SIMD3<Float>) -> Colours {
        switch world {
        case .telescope:
            let set = reference ?? TelescopeSet.fallback
            let own = Self.normalised(tint)
            func tinted(_ lab: SIMD3<Float>) -> SIMD3<Float> {
                let base = Self.normalised(OKLab.rgb(lab: lab))
                return Self.normalised(base * (SIMD3(repeating: 1) + (own - 1) * identity))
            }
            return Colours(
                core: tinted(set.core), body: tinted(set.disk), outer: tinted(set.tails),
                young: tinted(set.young), knot: tinted(set.knot))
        case .free:
            let lch = OKLab.lch(tint)
            let (L, C, h) = (lch.x, lch.y, lch.z)
            let toGold = Self.toward(h, 75, by: 40)
            let core = OKLab.rgb(lch: SIMD3(min(L + 0.08, 0.95), C * 0.45, toGold))
            let named = PaletteFamily.free.first { $0.name == self.family }
            let outerHue: Float
            if let named, named.hues.count > 1 {
                let other = named.hues.first { $0.distance(to: h) > 1 } ?? named.hues[1]
                outerHue = other.nearest(to: h + 180)
            } else if let named {
                outerHue = named.nearest(to: h + 50)
            } else {
                outerHue = h + 50
            }
            let outer = OKLab.rgb(lch: SIMD3(L, C, outerHue))
            let knot = Self.normalised(
                simd_mix(SIMD3<Float>(1.00, 0.34, 0.30), Self.normalised(tint), SIMD3(repeating: 0.4)))
            return Colours(
                core: Self.normalised(core), body: Self.normalised(tint),
                outer: Self.normalised(outer), young: Self.normalised(outer), knot: knot)
        }
    }

    /// `hue` moved `by` degrees at most toward `target`, the short way round.
    static func toward(_ hue: Float, _ target: Float, by limit: Float) -> Float {
        var d = (target - hue).truncatingRemainder(dividingBy: 360)
        if d > 180 { d -= 360 }
        if d < -180 { d += 360 }
        return hue + max(min(d, limit), -limit)
    }
}

/// Mirrors `GalaxyRamp` in the shader.
struct GalaxyRamp {
    var stop0: SIMD4<Float>
    var stop1: SIMD4<Float>
    var stop2: SIMD4<Float>
    var stop3: SIMD4<Float>
    var young: SIMD4<Float>
    var knot: SIMD4<Float>
    var params: SIMD4<Float>
}

/// Region colours of one of #125's reference sets, in OKLab: the vivid pixels where the median
/// is grey.
public struct TelescopeSet: Sendable {
    public var core: SIMD3<Float>
    public var disk: SIMD3<Float>
    public var tails: SIMD3<Float>
    public var young: SIMD3<Float>
    public var knot: SIMD3<Float>

    static let fallback = TelescopeSet(
        core: SIMD3(0.75, 0.045, 0.086), disk: SIMD3(0.49, 0.006, 0.002),
        tails: SIMD3(0.27, -0.017, -0.015), young: SIMD3(0.68, -0.022, -0.073),
        knot: SIMD3(0.66, 0.085, 0.035))

    public static func load(_ name: String) -> TelescopeSet? {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("references/telescope/\(name).json")
        struct Vivid: Decodable { var median: SIMD3<Float> }
        struct Region: Decodable {
            var median: SIMD3<Float>
            var vivid: [String: Vivid]?
        }
        struct File: Decodable { var regions: [String: Region] }
        guard let data = try? Data(contentsOf: url),
            let regions = try? JSONDecoder().decode(File.self, from: data).regions,
            let core = regions["core"], let disk = regions["disk"], let knots = regions["knots"]
        else { return nil }
        let tails = regions["tails"] ?? disk
        return TelescopeSet(
            core: core.vivid?["warm"]?.median ?? core.median,
            disk: disk.median,
            tails: tails.vivid?["cool"]?.median ?? tails.median,
            young: knots.vivid?["cool"]?.median ?? knots.median,
            knot: knots.vivid?["warm"]?.median ?? knots.median)
    }
}

extension RecordingFile {
    /// Each particle's distance to its own galaxy's centre on the first frame, which is what a
    /// take can say of the birth radius it does not store.
    public static func galacticRadii(_ loaded: Loaded) -> [Float] {
        let centres = loaded.recording.centers(at: 0)
        let positions = loaded.particles.positions
        return positions.indices.map { index in
            let galaxy = Int(loaded.particles.galaxyIndex[index])
            let centre = galaxy < centres.count ? centres[galaxy] : .zero
            return simd_distance(positions[index], centre)
        }
    }
}
