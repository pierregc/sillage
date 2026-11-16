import Foundation

/// What is written over a video's picture (#317): a title over the first seconds, a clock in
/// millions of years, a scale bar, and a caption at each of the story's events. Every element
/// is off unless named, and a video that names none is drawn as it always was.
///
/// A look carries it as `overlay`; a scene's `overlay.json` replaces the look's for that scene,
/// and `export --overlay` both, for one export (`docs/reference.md`). As strict as `LookFile`:
/// a field this build does not know is an error.
public struct Overlay: Codable, Sendable, Equatable {
    public enum Corner: String, Codable, Sendable, CaseIterable {
        case topLeft = "top-left"
        case topRight = "top-right"
        case bottomLeft = "bottom-left"
        case bottomRight = "bottom-right"

        public var isTop: Bool { self == .topLeft || self == .topRight }
        public var isLeft: Bool { self == .topLeft || self == .bottomLeft }
    }

    public struct Title: Codable, Sendable, Equatable {
        /// Absent, the scene's name, or the table's title for a scene named after its generator.
        public var text: String?
        /// Absent, a line the table makes of the galaxies: how many, what kind, how large.
        public var subtitle: String?
        /// How long it holds at full strength, in seconds of video.
        public var seconds: Double?

        public init(text: String? = nil, subtitle: String? = nil, seconds: Double? = nil) {
            self.text = text
            self.subtitle = subtitle
            self.seconds = seconds
        }

        public init(from decoder: any Decoder) throws {
            try rejectUnknownFields(decoder, CodingKeys.self)
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                text: try c.decodeIfPresent(String.self, forKey: .text),
                subtitle: try c.decodeIfPresent(String.self, forKey: .subtitle),
                seconds: try c.decodeIfPresent(Double.self, forKey: .seconds))
        }
    }

    public struct Clock: Codable, Sendable, Equatable {
        public enum Origin: String, Codable, Sendable {
            /// The take's first frame.
            case start
            /// The first passage, negative before it.
            case passage
        }

        public var from: Origin?
        public var corner: Corner?

        public init(origin: Origin? = nil, corner: Corner? = nil) {
            from = origin
            self.corner = corner
        }

        public init(from decoder: any Decoder) throws {
            try rejectUnknownFields(decoder, CodingKeys.self)
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                origin: try c.decodeIfPresent(Origin.self, forKey: .from),
                corner: try c.decodeIfPresent(Corner.self, forKey: .corner))
        }
    }

    public struct Scale: Codable, Sendable, Equatable {
        public enum Unit: String, Codable, Sendable {
            case lightYears = "light-years"
            case kiloparsecs
        }

        public var unit: Unit?
        public var corner: Corner?

        public init(unit: Unit? = nil, corner: Corner? = nil) {
            self.unit = unit
            self.corner = corner
        }

        public init(from decoder: any Decoder) throws {
            try rejectUnknownFields(decoder, CodingKeys.self)
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.init(
                unit: try c.decodeIfPresent(Unit.self, forKey: .unit),
                corner: try c.decodeIfPresent(Corner.self, forKey: .corner))
        }
    }

    public var title: Title?
    public var clock: Clock?
    public var scale: Scale?
    /// On with the table's words for every event found; an event given a text says that
    /// instead, and an empty text removes its caption.
    public var captions: [String: String]?
    /// Every element's size against the default, which is set on the frame's short side.
    public var size: Float?
    /// How opaque the white is at its strongest, from 0 to 1.
    public var opacity: Float?
    /// A font's PostScript name. Absent, the system's, at a light weight.
    public var font: String?
    /// The texts in another language: a file of `OverlayTexts`, relative to the scene folder.
    public var texts: String?

    public init(
        title: Title? = nil, clock: Clock? = nil, scale: Scale? = nil,
        captions: [String: String]? = nil, size: Float? = nil, opacity: Float? = nil,
        font: String? = nil, texts: String? = nil
    ) {
        self.title = title
        self.clock = clock
        self.scale = scale
        self.captions = captions
        self.size = size
        self.opacity = opacity
        self.font = font
        self.texts = texts
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownFields(decoder, CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            title: try c.decodeIfPresent(Title.self, forKey: .title),
            clock: try c.decodeIfPresent(Clock.self, forKey: .clock),
            scale: try c.decodeIfPresent(Scale.self, forKey: .scale),
            captions: try c.decodeIfPresent([String: String].self, forKey: .captions),
            size: try c.decodeIfPresent(Float.self, forKey: .size),
            opacity: try c.decodeIfPresent(Float.self, forKey: .opacity),
            font: try c.decodeIfPresent(String.self, forKey: .font),
            texts: try c.decodeIfPresent(String.self, forKey: .texts))
        if let stray = captions?.keys.first(where: { OverlayEvent(rawValue: $0) == nil }) {
            throw DecodingError.dataCorruptedError(
                forKey: .captions, in: c,
                debugDescription:
                    "no event \"\(stray)\": "
                    + OverlayEvent.allCases.map(\.rawValue).joined(separator: ", "))
        }
    }

    /// Whether it draws anything at all.
    public var isEmpty: Bool { title == nil && clock == nil && scale == nil && captions == nil }

    public enum Failure: Error, CustomStringConvertible {
        case noSuchElement(String)
        case texts(String, String)

        public var description: String {
            switch self {
            case .noSuchElement(let name):
                "--overlay: no element \"\(name)\", only title, clock, scale and captions, or all,"
                    + " or a file"
            case .texts(let path, let why): "the overlay's texts \(path): \(why)"
            }
        }
    }

    /// `all`, or element names separated by commas, each with its defaults.
    public static func elements(_ list: String) throws -> Overlay {
        var overlay = Overlay()
        for name in list.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch name {
            case "all":
                overlay = Overlay(title: Title(), clock: Clock(), scale: Scale(), captions: [:])
            case "title": overlay.title = Title()
            case "clock": overlay.clock = Clock()
            case "scale": overlay.scale = Scale()
            case "captions": overlay.captions = [:]
            default: throw Failure.noSuchElement(name)
            }
        }
        return overlay
    }

    public static func decoded(from data: Data) throws -> Overlay {
        try JSONDecoder().decode(Overlay.self, from: data)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    /// The table its words come from: English, or the file `texts` names, a relative path read
    /// from `folder`.
    public func loadTexts(folder: URL?) throws -> OverlayTexts {
        guard let texts else { return .english }
        let url =
            texts.hasPrefix("/") || folder == nil
            ? URL(fileURLWithPath: texts) : folder!.appendingPathComponent(texts)
        do {
            return try JSONDecoder().decode(OverlayTexts.self, from: Data(contentsOf: url))
        } catch {
            throw Failure.texts(url.path, "\(error)")
        }
    }
}

/// The moments of a story a caption can be given to.
public enum OverlayEvent: String, Codable, Sendable, CaseIterable {
    /// Halfway in distance from the take's start to the first passage.
    case approach
    /// The first passage of a pair inside its reach, as `Story.firstApproach` finds it.
    case passage
    /// The share of stars in tails halfway up its rise after the first passage.
    case tails
    /// The second passage of the same pair.
    case returning = "return"
    /// The pair's centres together for good.
    case merger
}

/// Every word the overlay writes, in one language. English is built in; another language is a
/// file of the same fields, each one it leaves out read in English (`Overlay.texts`). `{n}`,
/// `{count}`, `{kind}` and `{size}` are filled in.
public struct OverlayTexts: Codable, Sendable, Equatable {
    /// The title of a scene named after its generator.
    public var title: String
    /// The line under the title, for galaxies of one kind and about one size.
    public var subtitleEach: String
    /// For galaxies of several kinds or sizes.
    public var subtitleLargest: String
    /// For a galaxy alone.
    public var subtitleOne: String
    /// Numbers as words, from zero, at the start of a sentence.
    public var counts: [String]
    /// Each `GalaxyKind` as its galaxies are called.
    public var kinds: [String: String]
    public var clock: String
    public var lightYears: String
    public var kiloparsecs: String
    public var kiloparsec: String
    /// Between groups of three digits.
    public var thousands: String
    /// The minus sign before a time ahead of the first passage, and the plus after it.
    public var minus: String
    public var plus: String
    /// What each `OverlayEvent` says by default.
    public var captions: [String: String]

    public static let english = OverlayTexts(
        title: "A collision of galaxies",
        subtitleEach: "{count} {kind} galaxies, each about {size} light years across",
        subtitleLargest: "{count} galaxies, the largest about {size} light years across",
        subtitleOne: "A {kind} galaxy about {size} light years across",
        counts: ["No", "One", "Two", "Three", "Four", "Five", "Six", "Seven", "Eight", "Nine", "Ten"],
        kinds: ["spiral": "spiral", "disk": "disk", "globular": "elliptical"],
        clock: "{n} million years",
        lightYears: "{n} light years",
        kiloparsecs: "{n} kiloparsecs",
        kiloparsec: "{n} kiloparsec",
        thousands: ",",
        minus: "\u{2212}",
        plus: "+",
        captions: [
            OverlayEvent.approach.rawValue: "Drawn together by gravity",
            OverlayEvent.passage.rawValue: "They pass through each other",
            OverlayEvent.tails.rawValue: "Tides pull out long tails of stars",
            OverlayEvent.returning.rawValue: "Gravity brings them back",
            OverlayEvent.merger.rawValue: "They merge into one galaxy",
        ])

    public init(
        title: String, subtitleEach: String, subtitleLargest: String, subtitleOne: String,
        counts: [String], kinds: [String: String], clock: String, lightYears: String,
        kiloparsecs: String, kiloparsec: String, thousands: String, minus: String, plus: String,
        captions: [String: String]
    ) {
        self.title = title
        self.subtitleEach = subtitleEach
        self.subtitleLargest = subtitleLargest
        self.subtitleOne = subtitleOne
        self.counts = counts
        self.kinds = kinds
        self.clock = clock
        self.lightYears = lightYears
        self.kiloparsecs = kiloparsecs
        self.kiloparsec = kiloparsec
        self.thousands = thousands
        self.minus = minus
        self.plus = plus
        self.captions = captions
    }

    public init(from decoder: any Decoder) throws {
        try rejectUnknownFields(decoder, CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let e = OverlayTexts.english
        self.init(
            title: try c.value(.title, or: e.title),
            subtitleEach: try c.value(.subtitleEach, or: e.subtitleEach),
            subtitleLargest: try c.value(.subtitleLargest, or: e.subtitleLargest),
            subtitleOne: try c.value(.subtitleOne, or: e.subtitleOne),
            counts: try c.value(.counts, or: e.counts),
            kinds: e.kinds.merging(try c.value(.kinds, or: [:])) { $1 },
            clock: try c.value(.clock, or: e.clock),
            lightYears: try c.value(.lightYears, or: e.lightYears),
            kiloparsecs: try c.value(.kiloparsecs, or: e.kiloparsecs),
            kiloparsec: try c.value(.kiloparsec, or: e.kiloparsec),
            thousands: try c.value(.thousands, or: e.thousands),
            minus: try c.value(.minus, or: e.minus),
            plus: try c.value(.plus, or: e.plus),
            captions: e.captions.merging(try c.value(.captions, or: [:])) { $1 })
    }

    /// `value` with its digits grouped by three.
    public func number(_ value: Int) -> String {
        let digits = String(abs(value))
        var grouped = ""
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { grouped += thousands }
            grouped.append(digit)
        }
        return grouped
    }

    func fill(_ template: String, _ values: [String: String]) -> String {
        values.reduce(template) { $0.replacingOccurrences(of: "{\($1.key)}", with: $1.value) }
    }
}
