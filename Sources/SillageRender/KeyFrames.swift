import Foundation

/// A frame of the clip worth judging a look on, numbered in captured frames like the curves.
public struct KeyFrame: Sendable, Equatable {
    public enum Role: String, Sendable {
        case start, approach, pericentre, tails, end, middle, chosen
    }

    public var frame: Int
    public var role: Role
    public var timeMyr: Double

    public init(frame: Int, role: Role, timeMyr: Double) {
        self.frame = frame
        self.role = role
        self.timeMyr = timeMyr
    }
}

public enum KeyFrames {
    /// The columns of a curves file the choice reads.
    public struct Sample: Sendable, Equatable {
        public var frame: Int
        public var timeMyr: Double
        public var closest: Double
        public var tidal: Double

        public init(frame: Int, timeMyr: Double, closest: Double, tidal: Double) {
            self.frame = frame
            self.timeMyr = timeMyr
            self.closest = closest
            self.tidal = tidal
        }
    }

    /// Reads `curves.csv` or `curves-hires.csv` by column name, so columns added later do not
    /// shift anything.
    public static func samples(csv: String) -> [Sample] {
        let lines = csv.split(whereSeparator: \.isNewline)
        guard let header = lines.first?.split(separator: ",").map(String.init) else { return [] }
        let column = { (name: String) in header.firstIndex(of: name) }
        guard let frame = column("frame"), let time = column("time_myr"),
            let closest = column("closest_kpc"), let tidal = column("tidal_fraction")
        else { return [] }
        return lines.dropFirst().compactMap { line in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == header.count, let f = Int(fields[frame]),
                let t = Double(fields[time]), let c = Double(fields[closest]),
                let d = Double(fields[tidal])
            else { return nil }
            return Sample(frame: f, timeMyr: t, closest: c, tidal: d)
        }
    }

    /// Start, approach, pericentre, tails and end, dropping any that falls too close to one
    /// already kept, and topped up from the middle when fewer than three survive. Approach is
    /// the first frame halfway in distance from the start to the pericentre; tails the largest
    /// tidal fraction after it.
    public static func pick(_ samples: [Sample]) -> [KeyFrame] {
        guard let first = samples.first, let last = samples.last else { return [] }
        func key(_ sample: Sample, _ role: KeyFrame.Role) -> KeyFrame {
            KeyFrame(frame: sample.frame, role: role, timeMyr: sample.timeMyr)
        }
        var candidates: [KeyFrame] = []
        var afterFrame = first.frame
        // A lone galaxy has no separation, so no pericentre.
        if samples.contains(where: { $0.closest > 0 }),
            let pericentre = samples.min(by: { $0.closest < $1.closest })
        {
            candidates.append(key(pericentre, .pericentre))
            afterFrame = pericentre.frame
            let halfway = (first.closest + pericentre.closest) / 2
            if let approach = samples.first(where: {
                $0.frame > first.frame && $0.frame < pericentre.frame && $0.closest <= halfway
            }) {
                candidates.append(key(approach, .approach))
            }
        }
        candidates += [key(first, .start), key(last, .end)]
        if let tails = samples.filter({ $0.frame > afterFrame }).max(by: { $0.tidal < $1.tidal }),
            tails.tidal > 0
        {
            candidates.append(key(tails, .tails))
        }

        let gap = max((last.frame - first.frame) / 20, 1)
        var chosen: [KeyFrame] = []
        for candidate in candidates
        where chosen.allSatisfy({ abs($0.frame - candidate.frame) >= gap }) {
            chosen.append(candidate)
        }
        let middle = key(samples[samples.count / 2], .middle)
        if chosen.count < 3, !chosen.contains(where: { $0.frame == middle.frame }) {
            chosen.append(middle)
        }
        return chosen.sorted { $0.frame < $1.frame }
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case outsideClip(myr: Double, first: Double, last: Double)
        case badList(String)

        public var description: String {
            switch self {
            case .outsideClip(let myr, let first, let last):
                String(
                    format: "--key-frames-at: %g Myr is outside the clip, %.2f to %.2f Myr", myr, first, last)
            case .badList(let text): "--key-frames-at: \(text) is not a list of moments in Myr, as 452,520"
            }
        }
    }

    /// `--key-frames-at 452,520`: the moments, in Myr.
    public static func moments(_ text: String) throws -> [Double] {
        let parts = text.split(separator: ",")
        let moments = parts.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !moments.isEmpty, moments.count == parts.count, moments.allSatisfy(\.isFinite) else {
            throw Failure.badList(text)
        }
        return moments
    }

    /// `keys` with the frames asked for (#379): for each moment the captured frame nearest it,
    /// and the `span - 1` captured frames after it, so time can run slowly through them, each
    /// with the role `chosen`. `megayears` holds the moment of every captured frame of the run.
    /// A frame already a key takes the role `chosen`; a moment outside the run is refused.
    public static func adding(
        chosen moments: [Double], span: Int, to keys: [KeyFrame], megayears: [Double]
    ) throws -> [KeyFrame] {
        guard let first = megayears.first, let last = megayears.last else { return keys }
        var frames = Set<Int>()
        for myr in moments {
            // Half a frame of slack each side, so the clip's own ends can be asked for.
            let slack = megayears.count > 1 ? (last - first) / Double(megayears.count - 1) / 2 : 0
            guard myr >= first - slack, myr <= last + slack else {
                throw Failure.outsideClip(myr: myr, first: first, last: last)
            }
            guard
                let nearest = megayears.indices.min(by: {
                    abs(megayears[$0] - myr) < abs(megayears[$1] - myr)
                })
            else { continue }
            for frame in nearest..<min(nearest + max(span, 1), megayears.count) { frames.insert(frame) }
        }
        let chosen = frames.map { KeyFrame(frame: $0, role: .chosen, timeMyr: megayears[$0]) }
        return (keys.filter { !frames.contains($0.frame) } + chosen).sorted { $0.frame < $1.frame }
    }

    /// The captured frame nearest a moment.
    public static func nearest(timeMyr: Double, in samples: [Sample]) -> Sample? {
        samples.min { abs($0.timeMyr - timeMyr) < abs($1.timeMyr - timeMyr) }
    }
}
