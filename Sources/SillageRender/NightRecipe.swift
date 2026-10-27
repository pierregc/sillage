import Foundation
import SillageCore

/// A whole night in one JSON file: when it must be done, how much to explore, how many scenes
/// to take on, at what size, in what style and to which formats. Each setting is `"auto"` or a
/// value; a setting left out is Auto.
public struct NightRecipe: Codable, Sendable, Equatable {
    public static let version = 1

    /// A value, or `"auto"` for the night to choose.
    public enum Setting<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
        case auto
        case value(Value)

        public var value: Value? {
            if case .value(let value) = self { return value }
            return nil
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let word = try? container.decode(String.self), word == "auto" {
                self = .auto
            } else {
                self = .value(try container.decode(Value.self))
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .auto: try container.encode("auto")
            case .value(let value): try container.encode(value)
            }
        }
    }

    /// How many explored scenes go on to high resolution: Auto picks 2 to 4 by score, as many
    /// as fit; `none` stops after exploring.
    public enum Selection: Codable, Sendable, Equatable {
        case auto
        case count(Int)
        case none

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let count = try? container.decode(Int.self) {
                self = .count(count)
                return
            }
            switch try container.decode(String.self) {
            case "auto": self = .auto
            case "none": self = .none
            case let word: throw Failure.badValue("pick", "\(word) is not auto, none or 2 to 4")
            }
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .auto: try container.encode("auto")
            case .none: try container.encode("none")
            case .count(let count): try container.encode(count)
            }
        }
    }

    public struct Explore: Codable, Sendable, Equatable {
        public var scenes: Setting<Int> = .auto
        public var particlesPerGalaxy: Setting<Int> = .auto
        /// The share of scenes drawn from an archetype rather than freely.
        public var archetypeShare: Setting<Double> = .auto
        /// The archetypes allowed; a place drawn for another one is skipped.
        public var archetypes: Setting<[String]> = .auto
        /// `[least, most]` galaxies a scene may have.
        public var galaxies: Setting<[Int]> = .auto
        public var seed: Setting<UInt64> = .auto

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            scenes = try c.decodeIfPresent(Setting<Int>.self, forKey: .scenes) ?? .auto
            particlesPerGalaxy =
                try c.decodeIfPresent(Setting<Int>.self, forKey: .particlesPerGalaxy) ?? .auto
            archetypeShare =
                try c.decodeIfPresent(Setting<Double>.self, forKey: .archetypeShare) ?? .auto
            archetypes = try c.decodeIfPresent(Setting<[String]>.self, forKey: .archetypes) ?? .auto
            galaxies = try c.decodeIfPresent(Setting<[Int]>.self, forKey: .galaxies) ?? .auto
            seed = try c.decodeIfPresent(Setting<UInt64>.self, forKey: .seed) ?? .auto
        }
    }

    public struct Hires: Codable, Sendable, Equatable {
        public var particles: Setting<Int> = .auto
        /// The first frames of the story only, for a short run; Auto is the whole story.
        public var frames: Setting<Int> = .auto

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            particles = try c.decodeIfPresent(Setting<Int>.self, forKey: .particles) ?? .auto
            frames = try c.decodeIfPresent(Setting<Int>.self, forKey: .frames) ?? .auto
        }
    }

    public struct Style: Codable, Sendable, Equatable {
        /// `telescope` or `free`.
        public var world: Setting<String> = .auto
        /// A rendering of the look catalogue, such as `hubble` or `aurora`.
        public var style: Setting<String> = .auto
        /// A palette family, a favourite's name or a `.palette.json` file.
        public var palette: Setting<String> = .auto
        /// Several colours per galaxy (#120). Auto is on; `false` gives each galaxy one colour.
        public var multicolour: Setting<Bool> = .auto

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            world = try c.decodeIfPresent(Setting<String>.self, forKey: .world) ?? .auto
            style = try c.decodeIfPresent(Setting<String>.self, forKey: .style) ?? .auto
            palette = try c.decodeIfPresent(Setting<String>.self, forKey: .palette) ?? .auto
            multicolour =
                try c.decodeIfPresent(Setting<Bool>.self, forKey: .multicolour) ?? .auto
        }
    }

    public var version = NightRecipe.version
    /// A clock time, `"07:00"`, for its next occurrence, or a whole ISO 8601 date.
    public var deliver: Setting<String> = .auto
    /// Or a number of hours from the start.
    public var hours: Setting<Double> = .auto
    public var explore = Explore()
    public var pick = Selection.auto
    public var hires = Hires()
    public var style = Style()
    /// Video presets, and `webp` or `gif` for an animated preview.
    public var export: Setting<[String]> = .auto

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.version
        deliver = try c.decodeIfPresent(Setting<String>.self, forKey: .deliver) ?? .auto
        hours = try c.decodeIfPresent(Setting<Double>.self, forKey: .hours) ?? .auto
        explore = try c.decodeIfPresent(Explore.self, forKey: .explore) ?? Explore()
        pick = try c.decodeIfPresent(Selection.self, forKey: .pick) ?? .auto
        hires = try c.decodeIfPresent(Hires.self, forKey: .hires) ?? Hires()
        style = try c.decodeIfPresent(Style.self, forKey: .style) ?? Style()
        export = try c.decodeIfPresent(Setting<[String]>.self, forKey: .export) ?? .auto
    }
}

// MARK: - Auto

extension NightRecipe {
    /// When neither a delivery time nor hours are given.
    public static let defaultDelivery = "07:00"
    /// Pierre's night: fifty scenes to choose from.
    public static let defaultScenes = 50
    /// What Auto sizes an exploration among. Past 200 000 a galaxy, a preview keeps no more of
    /// the pericentres and tails a hires shows (#21).
    public static let perGalaxyLadder = [50_000, 75_000, 100_000, 150_000, 200_000]
    /// The size of the 2026-10-25 night, which leaves room for four scenes in a night.
    public static let defaultHiresParticles = 2_000_000
    public static let defaultExports = ["4k", "vertical"]
    public static let pickRange = 2...4
    /// The animated previews `export` writes besides video presets.
    public static let previewFormats = ["webp", "gif"]

    public func hiresParticles(maximum: Int) -> Int {
        hires.particles.value ?? min(Self.defaultHiresParticles, maximum)
    }

    public var exports: [String] { export.value ?? Self.defaultExports }

    /// The night's seed when the recipe gives none: the day it starts, as `explore-batch.sh`.
    public static func daySeed(_ date: Date, calendar: Calendar = .current) -> UInt64 {
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return UInt64((day.year ?? 2026) * 10_000 + (day.month ?? 1) * 100 + (day.day ?? 1))
    }

    /// The moment the night must be done: the next time the clock reads `deliver`, an exact
    /// date, or `hours` from now.
    public func deliverBy(now: Date, calendar: Calendar = .current) throws -> Date {
        if let hours = hours.value { return now.addingTimeInterval(hours * 3600) }
        let text = deliver.value ?? Self.defaultDelivery
        if let date = RunStatus.date(text) { return date }
        let parts = text.split(separator: ":").map { Int($0) }
        guard parts.count == 2, let hour = parts[0], let minute = parts[1], (0..<24).contains(hour),
            (0..<60).contains(minute),
            let date = calendar.nextDate(
                after: now, matching: DateComponents(hour: hour, minute: minute, second: 0),
                matchingPolicy: .nextTime)
        else { throw Failure.badValue("deliver", "\(text) is neither HH:mm nor an ISO 8601 date") }
        return date
    }
}

// MARK: - Reading

extension NightRecipe {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unknownKey(String)
        case version(Int)
        case badValue(String, String)
        case notJSON(String)

        public var description: String {
            switch self {
            case .unknownKey(let key): "recipe: \(key) is not a setting of a night"
            case .version(let found): "recipe: version \(found), this build reads \(NightRecipe.version)"
            case .badValue(let key, let why): "recipe: \(key): \(why)"
            case .notJSON(let why): "recipe: \(why)"
            }
        }
    }

    static let keys: [String: Set<String>] = [
        "": ["version", "deliver", "hours", "explore", "pick", "hires", "style", "export"],
        "explore": ["scenes", "particlesPerGalaxy", "archetypeShare", "archetypes", "galaxies", "seed"],
        "hires": ["particles", "frames"],
        "style": ["world", "style", "palette", "multicolour"],
    ]

    /// Reads a recipe and checks it: a misspelt setting is an error rather than a silent Auto.
    public static func decoded(from data: Data) throws -> NightRecipe {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.notJSON("not a JSON object")
        }
        for (group, allowed) in keys {
            let fields = group.isEmpty ? object : object[group] as? [String: Any] ?? [:]
            for key in fields.keys where !allowed.contains(key) {
                throw Failure.unknownKey(group.isEmpty ? key : "\(group).\(key)")
            }
        }
        let recipe: NightRecipe
        do {
            recipe = try JSONDecoder().decode(NightRecipe.self, from: data)
        } catch let failure as Failure {
            throw failure
        } catch DecodingError.typeMismatch(_, let context), DecodingError.dataCorrupted(let context) {
            let path = context.codingPath.map(\.stringValue).joined(separator: ".")
            throw Failure.badValue(path, "neither auto nor a value of the right kind")
        }
        try recipe.validate()
        return recipe
    }

    public static func read(_ url: URL) throws -> NightRecipe {
        try decoded(from: Data(contentsOf: url))
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public func validate() throws {
        guard version == Self.version else { throw Failure.version(version) }
        if deliver.value != nil, hours.value != nil {
            throw Failure.badValue("deliver", "give a delivery time or hours, not both")
        }
        if let hours = hours.value, !(hours > 0) { throw Failure.badValue("hours", "above 0") }
        _ = try deliverBy(now: Date())
        if let scenes = explore.scenes.value, scenes < 1 {
            throw Failure.badValue("explore.scenes", "at least 1")
        }
        if let count = explore.particlesPerGalaxy.value, count < 1_000 {
            throw Failure.badValue("explore.particlesPerGalaxy", "at least 1000")
        }
        if let share = explore.archetypeShare.value, !(0...1).contains(share) {
            throw Failure.badValue("explore.archetypeShare", "from 0 to 1")
        }
        if let names = explore.archetypes.value {
            let known = Archetype.allCases.map(\.rawValue)
            for name in names where !known.contains(name) {
                throw Failure.badValue(
                    "explore.archetypes", "\(name) is not one of \(known.joined(separator: ", "))")
            }
        }
        if let range = explore.galaxies.value {
            guard range.count == 2, range[0] >= 1, range[0] <= range[1] else {
                throw Failure.badValue("explore.galaxies", "[least, most], such as [2, 4]")
            }
        }
        if case .count(let count) = pick, !Self.pickRange.contains(count) {
            throw Failure.badValue("pick", "auto, none or 2 to 4")
        }
        if let particles = hires.particles.value, particles < 1_000 {
            throw Failure.badValue("hires.particles", "at least 1000")
        }
        if let frames = hires.frames.value, frames < 2 {
            throw Failure.badValue("hires.frames", "at least 2")
        }
        if let world = style.world.value, Palette.World(rawValue: world) == nil {
            throw Failure.badValue("style.world", "telescope or free")
        }
        if let names = export.value {
            for name in names
            where VideoPreset.named(name) == nil && !Self.previewFormats.contains(name) {
                let all = VideoPreset.all.map(\.name) + Self.previewFormats
                throw Failure.badValue("export", "\(name) is not one of \(all.joined(separator: ", "))")
            }
        }
    }

    /// `explore.galaxies` as a range.
    public var galaxyRange: ClosedRange<Int>? {
        explore.galaxies.value.map { $0[0]...$0[1] }
    }
}
