import Foundation

/// What a command of `sillage-render` takes: its words and its options, each with the kind of
/// value it reads. One parser holds every command to it, so that an option nothing reads or a
/// value that does not parse is refused with a message instead of rendering the default.
public struct CommandSpec: Sendable {
    public enum Kind: Sendable, Equatable {
        case flag
        case text
        case whole
        case number
    }

    public struct Option: Sendable, Equatable {
        public var name: String
        public var kind: Kind
        /// What it does, its unit and its default, one line for `--help` (#464).
        public var help: String
        /// The heading `--help` lists it under, for a command with many.
        public var group: String?

        public init(_ name: String, _ kind: Kind, help: String = "", group: String? = nil) {
            self.name = name
            self.kind = kind
            self.help = help
            self.group = group
        }
    }

    /// The options named in each list, each with its line from `about`, else `OptionHelp.shared`.
    static func options(
        flags: String = "", text: String = "", whole: String = "", number: String = "",
        about: [String: String] = [:], group: String? = nil
    ) -> [Option] {
        func names(_ list: String) -> [String] { list.split(whereSeparator: \.isWhitespace).map(String.init) }
        let all =
            names(flags).map { ($0, Kind.flag) } + names(text).map { ($0, Kind.text) }
            + names(whole).map { ($0, Kind.whole) } + names(number).map { ($0, Kind.number) }
        return all.map { name, kind in
            Option(name, kind, help: about[name] ?? OptionHelp.shared[name] ?? "", group: group)
        }
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case unknownOption(String, suggestion: String?)
        case missingValue(String)
        case badValue(option: String, value: String, wants: String)
        case unexpected(String)
        case missingWord(String)

        public var description: String {
            switch self {
            case .unknownOption(let name, let suggestion):
                "unknown option \(name)" + (suggestion.map { ", did you mean \($0)?" } ?? "")
            case .missingValue(let name): "\(name) needs a value"
            case .badValue(let option, let value, let wants):
                "\(option) wants \(wants), not \"\(value)\""
            case .unexpected(let word): "unexpected argument \"\(word)\""
            case .missingWord(let what): "missing \(what)"
            }
        }
    }

    /// What a parse found.
    public struct Parsed: Sendable, Equatable {
        public var words: [String] = []
        public var values: [String: String] = [:]
        public var flags: Set<String> = []

        public func has(_ name: String) -> Bool { flags.contains(name) || values[name] != nil }
        public func text(_ name: String) -> String? { values[name] }
        public func whole(_ name: String) -> Int? { values[name].flatMap(CommandSpec.whole) }
        public func number(_ name: String) -> Double? { values[name].flatMap(CommandSpec.number) }
    }

    /// The word the command is typed as; empty for the plain render.
    public var name: String
    public var summary: String
    /// What a person types after `sillage-render`, one line, then what each part means.
    public var usage: [String]
    /// The words that come first: a folder, an index.
    public var words: [String]
    /// Any word may follow them, as `look` takes look files.
    public var extraWords: Bool
    /// Any option is taken as it comes, a name and its value, as `event` writes fields.
    public var freeOptions: Bool
    public var options: [Option]

    public init(
        _ name: String, summary: String, usage: [String], words: [String] = [],
        extraWords: Bool = false, freeOptions: Bool = false, options: [Option] = []
    ) {
        self.name = name
        self.summary = summary
        self.usage = usage
        self.words = words
        self.extraWords = extraWords
        self.freeOptions = freeOptions
        self.options = options
    }

    static func whole(_ text: String) -> Int? {
        if let value = Int(text) { return value }
        if let value = UInt64(text) { return Int(truncatingIfNeeded: value) }
        guard let value = Double(text), value.isFinite, value == value.rounded(), abs(value) < 1e18
        else { return nil }
        return Int(value)
    }

    static func number(_ text: String) -> Double? {
        guard let value = Double(text), value.isFinite else { return nil }
        return value
    }

    public func option(_ name: String) -> Option? { options.first { $0.name == name } }

    /// `arguments` follow the command's name.
    public func parse(_ arguments: [String]) throws -> Parsed {
        var parsed = Parsed()
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            index += 1
            guard word.hasPrefix("--"), word.count > 2 else {
                if parsed.words.count < words.count || extraWords {
                    parsed.words.append(word)
                    continue
                }
                throw Failure.unexpected(word)
            }
            let name = String(word.dropFirst(2))
            guard let known = option(name) else {
                if freeOptions {
                    guard index < arguments.count else { throw Failure.missingValue(word) }
                    parsed.values[name] = arguments[index]
                    index += 1
                    continue
                }
                throw Failure.unknownOption(word, suggestion: closest(to: name).map { "--\($0)" })
            }
            if known.kind == .flag {
                parsed.flags.insert(name)
                continue
            }
            guard index < arguments.count else { throw Failure.missingValue(word) }
            let value = arguments[index]
            index += 1
            switch known.kind {
            case .whole where Self.whole(value) == nil:
                throw Failure.badValue(option: word, value: value, wants: "a whole number")
            case .number where Self.number(value) == nil:
                throw Failure.badValue(option: word, value: value, wants: "a number")
            default: break
            }
            parsed.values[name] = value
        }
        if parsed.words.count < words.count {
            throw Failure.missingWord(words[parsed.words.count])
        }
        return parsed
    }

    /// The option a misspelled name is nearest to, when it is near enough to be a typo.
    func closest(to name: String) -> String? {
        let candidates = options.map(\.name).map { ($0, Self.distance($0, name)) }
        guard let best = candidates.min(by: { $0.1 < $1.1 }), best.1 <= max(2, name.count / 3)
        else { return nil }
        return best.0
    }

    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a)
        let b = Array(b)
        var row = Array(0...b.count)
        for (i, left) in a.enumerated() {
            var previous = row[0]
            row[0] = i + 1
            for (j, right) in b.enumerated() {
                let kept = row[j + 1]
                row[j + 1] = min(row[j + 1] + 1, row[j] + 1, previous + (left == right ? 0 : 1))
                previous = kept
            }
        }
        return row[b.count]
    }

    /// The usage a person reads for `--help`: the line, what the command does, its options.
    public var help: String {
        var lines = usage
        lines.append("")
        lines.append(summary)
        guard !options.isEmpty else { return lines.joined(separator: "\n") }
        lines.append("")
        lines.append("Options:")
        var group: String?
        for option in options {
            if option.group != group, let heading = option.group {
                lines.append("")
                lines.append("  \(heading):")
            }
            group = option.group
            lines += Self.described(option)
        }
        return lines.joined(separator: "\n")
    }

    /// `--name KIND` and its line, the line wrapped under a column of its own.
    static func described(_ option: Option) -> [String] {
        let name: String
        switch option.kind {
        case .flag: name = "--\(option.name)"
        case .text: name = "--\(option.name) TEXT"
        case .whole: name = "--\(option.name) N"
        case .number: name = "--\(option.name) X"
        }
        let column = 30
        let words = option.help.split(separator: " ").map(String.init)
        var lines: [String] = []
        var line = "  " + name
        if line.count >= column - 1 {
            lines.append(line)
            line = ""
        }
        line = line.padding(toLength: column, withPad: " ", startingAt: 0)
        var used = 0
        for word in words {
            if used > 0, column + used + 1 + word.count > 100 {
                lines.append(line)
                line = String(repeating: " ", count: column)
                used = 0
            }
            line += (used > 0 ? " " : "") + word
            used += (used > 0 ? 1 : 0) + word.count
        }
        lines.append(words.isEmpty ? line.trimmingCharacters(in: .whitespaces) : line)
        return lines
    }
}
