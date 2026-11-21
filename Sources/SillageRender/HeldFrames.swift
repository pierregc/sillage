import Foundation

/// Where the frames of a take that holds only some moments of a run stand in that run (#379):
/// key frames kept by a full pass, or an extract. A video of it is framed on the run's massive
/// take, whose captured positions it is played in; each of its frames is placed among them by
/// its moment, and frames one stored frame of the massive take apart or less join in a run that
/// time may flow through. Anywhere else there is nothing to draw.
public struct HeldFrames: Sendable, Equatable {
    /// Consecutive frames of the take, `first` to `last`, from captured position `from` of the
    /// framing take to `to`.
    public struct Run: Sendable, Equatable {
        public var first: Int
        public var last: Int
        public var from: Double
        public var to: Double
        public var fromMyr: Double
        public var toMyr: Double

        public var description: String {
            first == last
                ? String(format: "%.3f Myr", fromMyr)
                : String(format: "%.3f to %.3f Myr (%d frames)", fromMyr, toMyr, last - first + 1)
        }
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case outside(myr: Double, held: String)
        case notInFraming(myr: Double, first: Double, last: Double)

        public var description: String {
            switch self {
            case .outside(let myr, let held):
                String(format: "the flight's time reaches %.3f Myr, and the take holds only %@", myr, held)
            case .notInFraming(let myr, let first, let last):
                String(
                    format: "a frame of the take at %.3f Myr is outside the framing take, %.2f to %.2f Myr",
                    myr, first, last)
            }
        }
    }

    /// How far, in captured frames, a moment may miss a held frame and still be drawn from it: a
    /// moment typed to three decimals of a megayear lands within it.
    public static let slack = 0.01

    /// The framing take's captured position of each frame of the take.
    public let positions: [Double]
    public let runs: [Run]
    /// The moment of every captured frame of the framing take.
    public let megayears: [Double]

    /// `times`, the moment of each frame of the take, in order; `megayears`, that of every
    /// captured frame of the framing take, which keeps one in `interval`.
    public init(times: [Double], megayears: [Double], interval: Int) throws {
        self.megayears = megayears
        positions = try times.map { myr in
            do {
                return try TimeTrack.position(of: myr, in: megayears)
            } catch {
                throw Failure.notInFraming(myr: myr, first: megayears.first ?? 0, last: megayears.last ?? 0)
            }
        }
        let joined = Double(max(interval, 1)) + 0.5
        var runs: [Run] = []
        for (index, position) in positions.enumerated() {
            if var run = runs.last, position - run.to <= joined, position >= run.to {
                run.last = index
                run.to = position
                run.toMyr = times[index]
                runs[runs.count - 1] = run
            } else {
                runs.append(
                    Run(
                        first: index, last: index, from: position, to: position, fromMyr: times[index],
                        toMyr: times[index]))
            }
        }
        self.runs = runs
    }

    /// The frames held, as a person reads them.
    public var description: String { runs.map(\.description).joined(separator: ", ") }

    /// The moment of a captured position of the framing take.
    public func myr(atCaptured position: Double) -> Double {
        guard let first = megayears.first else { return 0 }
        let clamped = min(max(position, 0), Double(megayears.count - 1))
        let index = min(Int(clamped), max(megayears.count - 2, 0))
        guard index + 1 < megayears.count else { return first }
        return megayears[index] + (megayears[index + 1] - megayears[index]) * (clamped - Double(index))
    }

    /// Where captured position `position` of the framing take falls among the take's frames,
    /// and the run it falls in; refused when it falls in none.
    public func place(atCaptured position: Double) throws -> (stored: Double, run: ClosedRange<Int>) {
        guard
            let run = runs.first(where: {
                position >= $0.from - Self.slack && position <= $0.to + Self.slack
            })
        else { throw Failure.outside(myr: myr(atCaptured: position), held: description) }
        let clamped = min(max(position, run.from), run.to)
        var index = run.first
        while index < run.last, positions[index + 1] < clamped { index += 1 }
        guard index < run.last else { return (Double(run.last), run.first...run.last) }
        let gap = positions[index + 1] - positions[index]
        let share = gap > 0 ? (clamped - positions[index]) / gap : 0
        return (Double(index) + share, run.first...run.last)
    }
}
