import CoreGraphics
import Foundation
import SillageCore
import SillageRender
import simd

/// `pace <scene folder> --speed <story|visual...> [--slow from:to:speed] [--out <file>.time.json]`
/// (#309): the track an automatic pace gives a take, written without drawing the video, for
/// `export --speed <file>`; with `--csv <file>` the video's time against the take's, and the
/// pace's own trace beside it as `.trace.csv`.
func paceCommand(_ arguments: [String]) -> Int32 {
    let usage =
        "usage: sillage-render pace <scene folder> --speed <story[:pace[:top]]|visual[:top[:busiest]]>"
        + " [--slow from:to:speed] [--take <file>] [--look <look>] [--out <file>] [--csv <file>]"
        + " [--drawings <dir> --drawings-myr <from>:<to>]"
    guard let path = arguments.first, !path.hasPrefix("--") else { fail(usage) }
    let options = Array(arguments.dropFirst())
    func option(_ name: String) -> String? {
        options.firstIndex(of: "--\(name)").flatMap { $0 + 1 < options.count ? options[$0 + 1] : nil }
    }
    guard let text = option("speed"), let spec = PaceSpec(text) else { fail(usage) }
    do {
        let folder = SceneFolder(path: path)
        let takeURL = option("take").map { URL(fileURLWithPath: $0) } ?? folder.take
        let loaded = try RecordingFile.read(from: takeURL)
        var look = try folder.exportLook(option("look"), catalogue: catalogueLooks())
        if look.palette.isEmpty {
            look.palette =
                (try? Data(contentsOf: folder.look)).flatMap { try? LookFile.decoded(from: $0) }?.palette
                .nonEmpty ?? loaded.scene.galaxies.map { GalaxyColours($0.color) }
        }
        let capturedRate = try folder.capturedRate()
        let paced = try pacedTrack(
            spec, name: text, folder: folder, loaded: loaded, look: look, capturedRate: capturedRate,
            framing: nil, aspect: 9.0 / 16, slow: option("slow"),
            csv: option("csv").map { URL(fileURLWithPath: $0) },
            drawings: option("drawings").flatMap { directory in
                let range = (option("drawings-myr") ?? "").split(separator: ":").compactMap { Double($0) }
                return range.count == 2
                    ? (
                        URL(fileURLWithPath: directory, isDirectory: true), range[0], range[1],
                        options.contains("--drawings-only")
                    ) : nil
            })
        let out = URL(fileURLWithPath: option("out") ?? "\(path)/exports/pace.time.json")
        try FileManager.default.createDirectory(
            at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        try paced.file.encoded().write(to: out)
        let seconds = paced.track.seconds
        print(
            String(
                format: "pace       %.1f s of video for a %.1f s take (%.0f%%), top speed %.1fx", seconds,
                Double(paced.track.capturedFrames - 1) / Double(capturedRate),
                100 * seconds / (Double(paced.track.capturedFrames - 1) / Double(capturedRate)),
                paced.file.speeds?.max() ?? 1))
        print("track      \(out.path)")
        return 0
    } catch {
        fail("pace: \(error)")
    }
}
