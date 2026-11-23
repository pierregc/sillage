import Foundation
import SillageCore

/// `pace <scene folder> --speed story[:pace[:top]] [--slow from:to:speed] [--take <file>]
/// [--out <file>] [--csv <file>]` without drawing anything (#309, #467): the story pace read off
/// the scene's curves, written as a time track for `export --speed <file>`, as the Mac's `pace`
/// writes it. The visual pace draws the take and stays the Mac's.
public enum PaceStory {
    public enum Failure: Error, CustomStringConvertible {
        case usage(String)
        public var description: String {
            switch self {
            case .usage(let text): text
            }
        }
    }

    public static func lines(_ arguments: [String], command: String) throws -> [String] {
        let usage =
            "usage: \(command) pace <scene folder> --speed story[:pace[:top]] [--slow from:to:speed]"
            + " [--take <file>] [--out <file>] [--csv <file>]"
        guard let path = arguments.first, !path.hasPrefix("--") else { throw Failure.usage(usage) }
        func option(_ name: String) -> String? {
            arguments.firstIndex(of: "--\(name)").flatMap {
                $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
            }
        }
        guard let text = option("speed"), let spec = PaceSpec(text) else { throw Failure.usage(usage) }
        guard case .story = spec else {
            throw Failure.usage(
                "the visual pace draws the take with Metal: run it with sillage-render pace, "
                    + "and give its .time.json to export --speed")
        }
        let folder = SceneFolder(path: path)
        let loaded = try RecordingFile.read(
            from: option("take").map { URL(fileURLWithPath: $0) } ?? folder.take)
        let capturedRate = try folder.capturedRate()
        let megayears = TimeTrack.megayears(of: loaded.recording)
        let read = try PaceTrack.fromCurves(spec, folder: folder, scene: loaded.scene, megayears: megayears)
        var made = read.made
        var lines = [
            String(
                format: "pace       %@ from %@: first pass %@ Myr, engaged until %@ Myr", text,
                read.curves.lastPathComponent, made.firstPassMyr.map { String(format: "%.0f", $0) } ?? "none",
                made.engagedUntilMyr.map { String(format: "%.0f", $0) } ?? "never")
        ]
        if let slow = option("slow") {
            let parts = slow.split(separator: ":").compactMap { Double($0) }
            guard parts.count == 3, parts[2] > 0 else { throw SceneFolder.ExportError.badValue("slow", slow) }
            made.speeds = PaceSpec.slowed(
                made.speeds, megayears: megayears, from: parts[0], to: parts[1], speed: parts[2])
        }
        let file = TimeTrackFile(speeds: made.speeds)
        let track = try file.track(megayears: megayears, capturedRate: capturedRate)
        if let csv = option("csv").map({ URL(fileURLWithPath: $0) }) {
            try made.traceCSV.write(
                to: csv.deletingPathExtension().appendingPathExtension("trace.csv"), atomically: true,
                encoding: .utf8)
            try PaceTrack.videoCSV(track, megayears: megayears, framesPerSecond: capturedRate).write(
                to: csv, atomically: true, encoding: .utf8)
        }
        let out = URL(fileURLWithPath: option("out") ?? "\(path)/exports/pace.time.json")
        try FileManager.default.createDirectory(
            at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try file.encoded().write(to: out)
        let seconds = track.seconds
        let takeSeconds = Double(track.capturedFrames - 1) / Double(capturedRate)
        lines.append(
            String(
                format: "pace       %.1f s of video for a %.1f s take (%.0f%%), top speed %.1fx", seconds,
                takeSeconds, 100 * seconds / takeSeconds, file.speeds?.max() ?? 1))
        lines.append("track      \(out.path)")
        return lines
    }
}
