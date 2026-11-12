import Foundation
import SillageCUDA
import SillageCore
import SillageRender

/// `sillage-cuda`, the CUDA engine's command on Linux (#277). `still` draws chosen frames of a
/// take as PNGs, with the cameras and looks `sillage-render export` gives them, on the GPU
/// library or on the CPU target, whichever it was linked with. docs/notes/cuda-engine.md.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("sillage-cuda: \(message)\n".utf8))
    exit(1)
}

let usage = """
    usage: sillage-cuda still <take> --look <look> [--framing <massive take>]
               [--preset 1080p|4k|vertical|square|whatsapp] [--width W --height H]
               --frames 0,200,900 [--fps N] [--rate N] [--threads N] --out <dir>

    Draws those frames of the take as PNGs, as `sillage-render export --stills` does: frame N is
    the Nth frame of a video of the take at --fps (the captured rate by default), and the film
    grain stands where that frame finds it. <look> is a look file, or the name of one in
    looks/ beside the take or in the current directory. The captured rate is read from
    hires.json or clip.json beside the take unless --rate gives it.
    """

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first, command == "still" else {
    print(usage)
    exit(arguments.isEmpty || arguments.first == "help" ? 0 : 2)
}
let rest = Array(arguments.dropFirst())

func option(_ name: String) -> String? {
    rest.firstIndex(of: "--\(name)").flatMap { $0 + 1 < rest.count ? rest[$0 + 1] : nil }
}

func integer(_ name: String) -> Int? {
    guard let text = option(name) else { return nil }
    guard let value = Int(text), value > 0 else { fail("--\(name) wants a whole number, not \(text)") }
    return value
}

guard let takePath = rest.first, !takePath.hasPrefix("--") else { fail("no take\n\n\(usage)") }
let takeURL = URL(fileURLWithPath: takePath)
guard let lookName = option("look") else { fail("--look is needed\n\n\(usage)") }
guard let framesText = option("frames") else { fail("--frames is needed\n\n\(usage)") }
guard let outPath = option("out") else { fail("--out is needed\n\n\(usage)") }
let frames = framesText.split(separator: ",").compactMap { Int($0) }
guard !frames.isEmpty, frames.count == framesText.split(separator: ",").count, frames.allSatisfy({ $0 >= 0 })
else { fail("--frames is a list of frame numbers, as 0,200,900") }

let presetName = option("preset") ?? "1080p"
guard let preset = VideoPreset.named(presetName) else {
    fail("no preset \(presetName): \(VideoPreset.all.map(\.name).joined(separator: ", "))")
}
let width = (integer("width") ?? preset.width) / 2 * 2
let height = (integer("height") ?? preset.height) / 2 * 2
guard width >= 16, height >= 16 else { fail("a picture of \(width) by \(height) is too small") }

func lookFile(_ name: String) throws -> LookFile {
    let manager = FileManager.default
    var candidates = [URL(fileURLWithPath: name)]
    let beside = takeURL.deletingLastPathComponent()
    for folder in [
        beside, beside.deletingLastPathComponent(), URL(fileURLWithPath: manager.currentDirectoryPath),
    ] {
        candidates.append(folder.appendingPathComponent("looks/\(name).look.json"))
    }
    guard let url = candidates.first(where: { manager.fileExists(atPath: $0.path) && !$0.hasDirectoryPath })
    else { fail("no look \(name)") }
    return try LookFile.decoded(from: Data(contentsOf: url))
}

func storedRate() -> Int? {
    let folder = takeURL.deletingLastPathComponent()
    for name in ["hires.json", "clip.json"] {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let rate = json["fps"] as? Int, rate > 0
        else { continue }
        return rate
    }
    return nil
}

do {
    guard let rate = integer("rate") ?? storedRate() else {
        fail("the captured rate is in neither hires.json nor clip.json beside the take: give --rate")
    }
    let take = try RecordingFile.read(from: takeURL)
    let framing = try option("framing").map { try RecordingFile.read(from: URL(fileURLWithPath: $0)) }
    let look = try lookFile(lookName)
    let context = try CUDAContext()
    let drawing = try CUDATakeStills(
        context: context, take: take, look: look, capturedRate: rate, width: width,
        height: height, framing: framing)
    let framesPerSecond = integer("fps") ?? rate
    let threads = integer("threads") ?? ProcessInfo.processInfo.activeProcessorCount
    let out = URL(fileURLWithPath: outPath, isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    print(
        "still      \(preset.name) \(width)x\(height), look \(look.name), \(take.recording.particleCount)"
            + " particles, \(drawing.capturedFrames) captured frames at \(rate) a second, on "
            + "\(CUDAContext.target == .gpu ? "the GPU" : "the CPU target") (\(context.name))")
    for index in frames {
        let started = Date()
        let position = drawing.position(ofFrame: index, framesPerSecond: framesPerSecond)
        guard position <= Double(drawing.capturedFrames - 1) else {
            fail("frame \(index) is past the end of the take: \(drawing.capturedFrames) captured frames")
        }
        let pixels = try drawing.still(
            atCaptured: position, frame: index, format: .rgb, threads: threads)
        let image = PNG.Image(
            width: width, height: height, channels: 3, bytes: [UInt8](pixels))
        let url = out.appendingPathComponent(String(format: "%@-%04d.png", preset.name, index))
        try PNG.write(image, to: url)
        print(
            String(format: "still      %@  %.2f s", url.lastPathComponent, Date().timeIntervalSince(started)))
    }
} catch {
    fail("\(error)")
}
