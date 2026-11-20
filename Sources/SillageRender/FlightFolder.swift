import Foundation

/// A scene's flight as the panel and the export sheet list it (#298).
public struct FlightListing: Sendable, Equatable, Identifiable {
    public var name: String
    /// The flight's length in seconds, and its keys; nil for a file that cannot be read.
    public var seconds: Double?
    public var keys: Int?
    /// Why the file cannot be read.
    public var fault: String?

    public var id: String { name }

    public init(name: String, seconds: Double? = nil, keys: Int? = nil, fault: String? = nil) {
        self.name = name
        self.seconds = seconds
        self.keys = keys
        self.fault = fault
    }
}

/// The flights kept in a scene's `flights/` folder: which there are, a name for the next, and the
/// writes the app makes (#298). The file is `FlightFile`'s; the folder is `SceneFolder.flights`.
extension SceneFolder {
    public enum FlightError: Error, CustomStringConvertible, Equatable {
        case badName(String)
        case exists(String)
        case missing(String)

        public var description: String {
            switch self {
            case .badName(let name): "\"\(name)\" is not a name: letters, digits, - and _"
            case .exists(let name): "a flight called \(name) is already there"
            case .missing(let name): "there is no flight called \(name)"
            }
        }
    }

    /// A name typed by hand made into one `export --flight` can be given on a command line:
    /// spaces become dashes, anything else but letters, digits, `-` and `_` goes; nil when
    /// nothing is left.
    public static func flightName(from text: String) -> String? {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_")
        let name = String(
            text.trimmingCharacters(in: .whitespacesAndNewlines).map { $0 == " " ? "-" : $0 }.filter {
                allowed.contains($0)
            })
        return name.isEmpty ? nil : name
    }

    /// The names of the flights in `flights/`, in alphabetical order.
    public func flightNames() -> [String] {
        let suffix = "." + FlightFile.fileExtension
        let names = (try? FileManager.default.contentsOfDirectory(atPath: flights.path)) ?? []
        return names.filter { $0.hasSuffix(suffix) && !$0.hasPrefix(".") }
            .map { String($0.dropLast(suffix.count)) }
            .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
    }

    /// Every flight with what can be told of it without the take.
    public func flightListings() -> [FlightListing] {
        flightNames().map { name in
            do {
                let file = try FlightFile.decoded(from: Data(contentsOf: flight(name)))
                return FlightListing(name: name, seconds: file.seconds, keys: file.keys.count)
            } catch {
                return FlightListing(name: name, fault: "\(error)")
            }
        }
    }

    /// `flight-1`, or the first of `flight-2`, `flight-3`, ... not taken.
    public func nextFlightName(prefix: String = "flight") -> String {
        let taken = Set(flightNames())
        var number = 1
        while taken.contains("\(prefix)-\(number)") { number += 1 }
        return "\(prefix)-\(number)"
    }

    /// Writes `file` as `flights/<name>.flight.json`, the folder made when it is not there. A
    /// name already taken is an error unless `replacing`.
    @discardableResult
    public func writeFlight(_ file: FlightFile, named name: String, replacing: Bool = false) throws -> URL {
        guard Self.flightName(from: name) == name else { throw FlightError.badName(name) }
        let url = flight(name)
        if !replacing, FileManager.default.fileExists(atPath: url.path) { throw FlightError.exists(name) }
        try FileManager.default.createDirectory(at: flights, withIntermediateDirectories: true)
        try file.encoded().write(to: url, options: .atomic)
        return url
    }

    public func renameFlight(_ name: String, to new: String) throws {
        guard Self.flightName(from: new) == new else { throw FlightError.badName(new) }
        let (from, to) = (flight(name), flight(new))
        guard FileManager.default.fileExists(atPath: from.path) else { throw FlightError.missing(name) }
        guard name != new else { return }
        guard !FileManager.default.fileExists(atPath: to.path) else { throw FlightError.exists(new) }
        try FileManager.default.moveItem(at: from, to: to)
    }
}
