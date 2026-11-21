import Foundation
import SillageCore

/// `take extract` (#379): the frames of a take around chosen moments, written as a take of their
/// own with their centres and disk states, the positions copied as they are stored. It is how a
/// few frames of a large take made on a rented box come back without the rest.
public enum TakeExtract {
    public enum Failure: Error, CustomStringConvertible, Equatable {
        case outsideTake(myr: Double, first: Double, last: Double)
        case badMoments(String)
        case badSpan(String)
        case usage

        public var description: String {
            switch self {
            case .outsideTake(let myr, let first, let last):
                String(format: "--at: %g Myr is outside the take, %.2f to %.2f Myr", myr, first, last)
            case .badMoments(let text): "--at: \(text) is not a list of moments in Myr, as 452,520"
            case .badSpan(let text): "--span: \(text) is not a count of frames"
            case .usage: TakeExtract.usage
            }
        }
    }

    public static let usage =
        "usage: take extract <take> --at <myr,...> [--span <frames>] <out.sillage>"

    /// The stored frames kept: for each moment the stored frame nearest it and the `span - 1`
    /// stored frames after it, in order, each once.
    public static func frames(of recording: Recording, at moments: [Double], span: Int) throws -> [Int] {
        let times = recording.frames.map { Double($0.time) * Physics.megayearsPerTimeUnit }
        guard let first = times.first, let last = times.last else { return [] }
        var kept = Set<Int>()
        for myr in moments {
            let slack = times.count > 1 ? (last - first) / Double(times.count - 1) / 2 : 1e-3
            guard myr.isFinite, myr >= first - slack, myr <= last + slack else {
                throw Failure.outsideTake(myr: myr, first: first, last: last)
            }
            guard let nearest = times.indices.min(by: { abs(times[$0] - myr) < abs(times[$1] - myr) })
            else { continue }
            for index in nearest..<min(nearest + max(span, 1), times.count) { kept.insert(index) }
        }
        return kept.sorted()
    }

    /// Writes `frames`, stored frames of `take`, to `url` as a take whose every frame is stored.
    /// The positions go through a file beside `url`, mapped, so a frame of a large take is held
    /// once at most.
    public static func write(_ take: RecordingFile.Loaded, frames indices: [Int], to url: URL) throws {
        let recording = take.recording
        let galaxies = recording.galaxyCount
        let contents = recording.contents()
        let hasDisks = contents.disks.count >= contents.frames.count * galaxies
        let staging = url.appendingPathExtension("positions")
        FileManager.default.createFile(atPath: staging.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: staging) }
        let handle = try FileHandle(forWritingTo: staging)
        let bytes = recording.frameBytes
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: max(bytes, 1), alignment: 16)
        defer { buffer.deallocate() }
        var frames: [Recording.Frame] = []
        var centers: [SIMD3<Float>] = []
        var disks: [DiskState] = []
        for index in indices {
            guard let frame = recording.copy(frame: index, to: buffer) else {
                try? handle.close()
                throw RecordingFile.Failure.truncated
            }
            try handle.write(contentsOf: Data(bytesNoCopy: buffer, count: bytes, deallocator: .none))
            frames.append(frame)
            centers += contents.centers[(index * galaxies)..<((index + 1) * galaxies)]
            if hasDisks { disks += contents.disks[(index * galaxies)..<((index + 1) * galaxies)] }
        }
        try handle.close()
        let extracted = Recording(
            particleCount: recording.particleCount, galaxyCount: galaxies, frames: frames,
            centers: centers, disks: disks, interval: 1, capturedCount: frames.count,
            bitsPerAxis: recording.bitsPerAxis, mapped: try Data(contentsOf: staging, options: .alwaysMapped))
        try RecordingFile.write(extracted, scene: take.scene, particles: take.particles, to: url)
    }

    /// `take extract <take> --at <myr,...> [--span <frames>] <out.sillage>`, the words after
    /// `take`: what it kept, a line each.
    public static func command(_ words: [String]) throws -> [String] {
        var positional: [String] = []
        var at: String?
        var span = 1
        var index = 0
        while index < words.count {
            let word = words[index]
            switch word {
            case "--at", "--span":
                guard index + 1 < words.count else { throw Failure.usage }
                let value = words[index + 1]
                if word == "--at" {
                    at = value
                } else {
                    guard let count = Int(value), count >= 1 else { throw Failure.badSpan(value) }
                    span = count
                }
                index += 2
            default:
                guard !word.hasPrefix("--") else { throw Failure.usage }
                positional.append(word)
                index += 1
            }
        }
        guard positional.count == 3, positional[0] == "extract", let at else { throw Failure.usage }
        let parts = at.split(separator: ",")
        let moments = parts.compactMap { Double($0) }
        guard !moments.isEmpty, moments.count == parts.count else { throw Failure.badMoments(at) }
        let source = URL(fileURLWithPath: positional[1])
        let out = URL(fileURLWithPath: positional[2])
        let take = try RecordingFile.read(from: source)
        let kept = try frames(of: take.recording, at: moments, span: span)
        try FileManager.default.createDirectory(
            at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(take, frames: kept, to: out)
        let size = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
        let stored = take.recording.frames
        return kept.map { index in
            String(
                format: "frame      %d of %d, %.3f Myr", index, stored.count,
                Double(stored[index].time) * Physics.megayearsPerTimeUnit)
        } + [
            String(
                format: "extract    %d frames of %d particles, %.2f GB, in %@", kept.count,
                take.recording.particleCount, Double(size) / 1e9, out.path)
        ]
    }
}
