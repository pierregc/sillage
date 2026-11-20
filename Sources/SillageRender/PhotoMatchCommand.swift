import Foundation
import SillageCore

/// `sillage-render match` and `sillage-cuda match` (#320): `PhotoMatch` over a scene folder's
/// take, the outcome kept in the folder's `match/`.
public enum PhotoMatchCommand {
    public static let usage = """
        usage: match <scene folder> <picture.map.json> [--take <file>] [--at <myr>] [--within <myr>]
                   [--view <elevation,azimuth,roll>] [--span <degrees>] [--kpc-across <kpc>] [--stars <n>]
                   [--ceiling <decades>] [--measure isophotes|correlation|balanced] [--fresh]

        Finds the moment and the view where the take overlaps the picture best. The map comes from
        scripts/photo-match.py picture. Writes match/<picture>.json in the folder (the moment,
        the view and the score, read back as the starting guess next time unless --fresh) and
        match/<picture>.sheet.json, which scripts/photo-match.py sheet draws.
        """

    /// What a match leaves in the scene folder: where a named scene keeps its moment and view.
    public struct Record: Codable, Sendable, Equatable {
        public var picture: String
        public var map: String
        public var score: Double
        public var megayears: Double
        public var storedFrame: Int
        public var capturedFrame: Double
        public var view: PhotoMatch.View
        public var ceiling: Float
        public var trials: Int
        public var seconds: Double
    }

    public static func main(_ arguments: [String]) -> Int32 {
        func fail(_ message: String) -> Int32 {
            FileHandle.standardError.write(Data("match: \(message)\n".utf8))
            return 2
        }
        guard arguments.count >= 2, !arguments[0].hasPrefix("--"), !arguments[1].hasPrefix("--") else {
            print(usage)
            return 2
        }
        func option(_ name: String) -> String? {
            arguments.firstIndex(of: "--\(name)").flatMap {
                $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
            }
        }
        let folder = SceneFolder(path: arguments[0])
        let mapURL = URL(fileURLWithPath: arguments[1])
        let stem = Self.stem(of: mapURL)
        let directory = folder.url.appendingPathComponent("match", isDirectory: true)
        let recordURL = directory.appendingPathComponent("\(stem).json")
        do {
            let picture = try PhotoMatch.Picture(data: Data(contentsOf: mapURL))
            let take = try RecordingFile.read(
                from: option("take").map { URL(fileURLWithPath: $0) } ?? folder.take)
            let frames = try PhotoMatch.TakeFrames(take)
            var options = PhotoMatch.Options()
            if !arguments.contains("--fresh"), let data = try? Data(contentsOf: recordURL),
                let previous = try? JSONDecoder().decode(Record.self, from: data)
            {
                options.moment = previous.megayears
                options.view = previous.view
                options.span = 30
                options.within = 100
                print(String(format: "guess      %.0f Myr from %@", previous.megayears, recordURL.path))
            }
            if let at = option("at") {
                guard let value = Double(at) else { return fail("--at wants Myr, not \(at)") }
                options.moment = value
            }
            if let within = option("within") {
                guard let value = Double(within), value > 0 else {
                    return fail("--within wants Myr, not \(within)")
                }
                options.within = value
            }
            if let text = option("view") {
                let parts = text.split(separator: ",").compactMap { Double($0) }
                guard parts.count == 2 || parts.count == 3 else {
                    return fail("--view is elevation,azimuth[,roll] in degrees")
                }
                options.view = PhotoMatch.View(
                    elevation: parts[0], azimuth: parts[1], roll: parts.count == 3 ? parts[2] : 0)
            }
            if let span = option("span") {
                guard let value = Double(span), value > 0 else {
                    return fail("--span wants degrees, not \(span)")
                }
                options.span = value
            }
            if let across = option("kpc-across") {
                guard let value = Double(across), value > 0 else {
                    return fail("--kpc-across wants kiloparsecs, not \(across)")
                }
                options.kpcPerWidth = value
            }
            if let stars = option("stars") {
                guard let value = Int(stars), value > 0 else {
                    return fail("--stars wants a count, not \(stars)")
                }
                options.stars = value
            }
            if let text = option("measure") {
                guard let measure = PhotoMatch.Measure(rawValue: text) else {
                    return fail(
                        "--measure is one of "
                            + PhotoMatch.Measure.allCases.map(\.rawValue).joined(separator: ", "))
                }
                options.measure = measure
            }
            if let ceiling = option("ceiling") {
                guard let value = Float(ceiling), value <= 0 else {
                    return fail("--ceiling wants decades below the reference, 0 or less, not \(ceiling)")
                }
                options.ceiling = value
            }
            let started = Date()
            let outcome = try PhotoMatch.search(picture, frames: frames, options: options) { print($0) }
            let seconds = Date().timeIntervalSince(started)
            let best = outcome.best
            let record = Record(
                picture: picture.source, map: mapURL.lastPathComponent, score: best.score,
                megayears: best.megayears, storedFrame: best.frame,
                capturedFrame: frames.captured(best.frame), view: best.view, ceiling: options.ceiling,
                trials: outcome.trials, seconds: (seconds * 10).rounded() / 10)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(record).write(to: recordURL)
            let sheetURL = directory.appendingPathComponent("\(stem).sheet.json")
            try sheet(outcome, picture: picture, ceiling: options.ceiling).write(to: sheetURL)
            print(
                String(
                    format:
                        "match      %.3f at %.1f Myr (stored frame %d, captured %.1f), elevation %.1f, azimuth %.1f, roll %.1f, %.1f kpc across, %d trials in %.0f s",
                    best.score, best.megayears, best.frame, record.capturedFrame, best.view.elevation,
                    best.view.azimuth, best.view.roll, best.view.kpcPerWidth, outcome.trials, seconds))
            print("wrote      \(recordURL.path)")
            print("sheet      scripts/photo-match.py sheet \(sheetURL.path)")
            return 0
        } catch {
            return fail("\(error)")
        }
    }

    /// `antennae-ls.map.json` is `antennae-ls`.
    static func stem(of url: URL) -> String {
        var name = url.lastPathComponent
        for suffix in [".json", ".map"] where name.hasSuffix(suffix) {
            name = String(name.dropLast(suffix.count))
        }
        return name
    }

    /// The maps and the curves, for the sheet.
    static func sheet(_ outcome: PhotoMatch.Outcome, picture: PhotoMatch.Picture, ceiling: Float) throws
        -> Data
    {
        struct Best: Encodable {
            var score, megayears, elevation, azimuth, roll, kpcPerWidth: Double
        }
        struct Curves: Encodable {
            var time, elevation, azimuth, roll: [[Double]]
        }
        struct Sheet: Encodable {
            var source: String
            var width, height: Int
            var depth, ceiling: Float
            var best: Best
            var curves: Curves
            var pictureLevels, takeLevels: [Float?]
        }
        func rounded(_ values: [Float]) -> [Float?] {
            values.map { $0.isNaN ? nil : ($0 * 1000).rounded() / 1000 }
        }
        func curve(_ points: [SIMD2<Double>]) -> [[Double]] {
            points.map { [($0.x * 100).rounded() / 100, ($0.y * 10000).rounded() / 10000] }
        }
        let best = outcome.best
        return try JSONEncoder().encode(
            Sheet(
                source: picture.source, width: picture.width, height: picture.height,
                depth: picture.depth, ceiling: ceiling,
                best: Best(
                    score: best.score, megayears: best.megayears, elevation: best.view.elevation,
                    azimuth: best.view.azimuth, roll: best.view.roll, kpcPerWidth: best.view.kpcPerWidth),
                curves: Curves(
                    time: curve(outcome.time), elevation: curve(outcome.elevation),
                    azimuth: curve(outcome.azimuth), roll: curve(outcome.roll)),
                pictureLevels: rounded(outcome.pictureLevels), takeLevels: rounded(outcome.takeLevels)))
    }
}
