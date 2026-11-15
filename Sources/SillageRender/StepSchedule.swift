import Foundation

/// A coarser step where nothing fast happens, for the spike of #307 (`--dt-schedule`,
/// docs/notes/variable-time.md): from each entry's moment on, the step is `scale` times the
/// run's own. The scale is a power of two that divides a frame's steps, and a switch waits for
/// the next frame boundary, so the captured frames keep their cadence in megayears.
public struct StepSchedule: Codable, Sendable, Equatable, CustomStringConvertible {
    public struct Entry: Codable, Sendable, Equatable {
        public var fromMyr: Double
        public var scale: Int

        public init(fromMyr: Double, scale: Int) {
            self.fromMyr = fromMyr
            self.scale = scale
        }
    }

    /// Where a run changed its step, in steps of its own from its first, settle included.
    public struct Switch: Codable, Sendable, Equatable {
        public var step: Int
        public var myr: Double
        public var scale: Int
        /// The captured frame it came before; absent while settling.
        public var frame: Int?

        public init(step: Int, myr: Double, scale: Int, frame: Int?) {
            self.step = step
            self.myr = myr
            self.scale = scale
            self.frame = frame
        }
    }

    public enum Problem: Error, CustomStringConvertible {
        case badEntry(String)
        case badScale(Int, perFrame: Int)

        public var description: String {
            switch self {
            case .badEntry(let entry):
                "--dt-schedule: \"\(entry)\" is not <Myr>:<scale>, e.g. 0:2,162:1"
            case .badScale(let scale, let perFrame):
                "--dt-schedule: a scale of \(scale) is not a power of two dividing a frame's"
                    + " \(perFrame) steps"
            }
        }
    }

    /// In order of time; the run's own step before the first.
    public private(set) var entries: [Entry]

    public init(entries: [Entry]) { self.entries = entries.sorted { $0.fromMyr < $1.fromMyr } }

    /// `0:2,162:1`: twice the step from the start, the run's own from 162 Myr.
    public init(parsing text: String) throws {
        let entries = try text.split(separator: ",").map { part -> Entry in
            let fields = part.split(separator: ":")
            guard fields.count == 2, let myr = Double(fields[0]), myr >= 0, let scale = Int(fields[1]),
                scale >= 1
            else { throw Problem.badEntry(String(part)) }
            return Entry(fromMyr: myr, scale: scale)
        }
        guard !entries.isEmpty else { throw Problem.badEntry(text) }
        self.init(entries: entries)
    }

    public func check(stepsPerFrame: Int) throws {
        for entry in entries
        where entry.scale & (entry.scale - 1) != 0 || stepsPerFrame % entry.scale != 0 {
            throw Problem.badScale(entry.scale, perFrame: stepsPerFrame)
        }
    }

    /// The scale for a stretch starting at `myr`.
    public func scale(atMyr myr: Double) -> Int {
        entries.last { $0.fromMyr <= myr + 1e-6 }?.scale ?? 1
    }

    public var description: String {
        entries.map { String(format: "%g:%d", $0.fromMyr, $0.scale) }.joined(separator: ",")
    }
}
