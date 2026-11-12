import Foundation
import SillageCUDA
import SillageCore
import SillageRender

/// `sillage-cuda`, the CUDA engine's command on Linux (#277, #278): `hires` runs the full pass
/// of a hires on the GPU library or on the CPU target, whichever it was linked with; `check`
/// holds that engine to the reference outputs first; `still` draws chosen frames of a take as
/// PNGs; `status` says how far a run has got. docs/notes/cuda-engine.md.

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("sillage-cuda: \(message)\n".utf8))
    exit(1)
}

let usage = """
    usage: sillage-cuda hires <scene folder> --pass full [--export 4k,vertical] [options]
           sillage-cuda check [--fixtures <dir>] [--record <file>]
           sillage-cuda status <scene folder>
           sillage-cuda still <take> --look <look> [--framing <massive take>]
               [--preset 1080p|4k|vertical|square|whatsapp] [--width W --height H]
               --frames 0,200,900 [--fps N] [--rate N] [--threads N] --out <dir>

    hires runs the full pass of a scene whose massive pass and style were done on the Mac: it
    reads scene.json, look.json, take.sillage, curves-hires.csv, hires.json and massive.bin from
    the folder, and writes exports/<preset>.<ext>, keyframes.sillage, keyframes.json and the full
    section of hires.json there, as sillage-render hires --pass full does. Options:
    --checkpoint-every <minutes>, --checkpoint-frames N, --checkpoint-steps N, --resume,
    --tracer-sort N, --tracer-sort-chunk N, --draw-stills 0,12 [--draw-stills-dir <dir>],
    --draw-divisor N, --profile, --threads N (the CPU target's drawing). It refuses to start on
    an engine whose check did not pass for this build.

    check builds the reference tree and draws the reference frames of Tests/Fixtures/engines
    with this build, and records the outcome beside the libraries (engine-check.json).

    still draws those frames of the take as PNGs, as `sillage-render export --stills` does: frame
    N is the Nth frame of a video of the take at --fps (the captured rate by default), and the
    film grain stands where that frame finds it. <look> is a look file, or the name of one in
    looks/ beside the take or in the current directory. The captured rate is read from
    hires.json or clip.json beside the take unless --rate gives it.
    """

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first, ["still", "hires", "check", "status"].contains(command) else {
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

/// The reference outputs: `--fixtures`, or `Tests/Fixtures/engines` of the repository the
/// command was built in, or of the current directory.
func fixtures() -> URL {
    if let path = option("fixtures") { return URL(fileURLWithPath: path, isDirectory: true) }
    let built = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    for root in [built, URL(fileURLWithPath: FileManager.default.currentDirectoryPath)] {
        let folder = root.appendingPathComponent("Tests/Fixtures/engines", isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) {
            return folder
        }
    }
    fail("no Tests/Fixtures/engines beside the build or here: give --fixtures")
}

if command == "check" {
    do {
        let context = try CUDAContext()
        let record = CUDAEngineCheck.run(
            context: context, fixtures: fixtures(),
            threads: integer("threads") ?? ProcessInfo.processInfo.activeProcessorCount)
        let url = option("record").map { URL(fileURLWithPath: $0) } ?? CUDAEngineCheck.defaultRecord
        try CUDAEngineCheck.write(record, to: url)
        for item in record.items {
            print("check      \(item.name): \(item.passed ? "passed" : "FAILED"), \(item.detail)")
        }
        print(
            "check      \(record.engine) on \(record.device), build \(record.build): \(record.passed ? "passed" : "FAILED"), \(url.path)"
        )
        exit(record.passed ? 0 : 1)
    } catch {
        fail("\(error)")
    }
}

if command == "status" {
    guard let path = rest.first, !path.hasPrefix("--") else { fail("no scene folder\n\n\(usage)") }
    let folder = SceneFolder(path: path)
    let activity = ActivityFile.read(from: RunStatusFiles.activity(library: folder.library))
    guard let job = activity?.job, activity?.state == .running else {
        print("status     idle")
        exit(0)
    }
    let eta = job.eta.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"
    print(
        String(
            format: "status     %@ %@ %@: %.1f %%, %@, ends about %@", job.kind, job.batch ?? "",
            job.scene ?? "",
            job.progress * 100, job.detail ?? "", eta))
    exit(0)
}

if command == "hires" {
    guard let path = rest.first, !path.hasPrefix("--") else { fail("no scene folder\n\n\(usage)") }
    let folder = SceneFolder(path: path)
    var options = Array(rest.dropFirst())
    guard SceneFolder.pass(in: options) == "full" else {
        fail("only the full pass runs here (--pass full): the massive pass and the style are the Mac's")
    }
    var threads = ProcessInfo.processInfo.activeProcessorCount
    if let index = options.firstIndex(of: "--threads"), index + 1 < options.count {
        threads = Int(options[index + 1]) ?? threads
        options.removeSubrange(index...index + 1)
    }
    // A run whose encoder stops must fail with ffmpeg's message, not die of a broken pipe.
    signal(SIGPIPE, SIG_IGN)
    let started = Date()
    do {
        let maximum =
            ProcessInfo.processInfo.environment[SceneFolder.maximumParticlesVariable].flatMap(Double.init)
            .map(Int.init) ?? 2_000_000_000
        let plan = try folder.hiresArguments(options, maximumParticles: maximum)
        let record = plan.record
        let reporter = StageReporter(stage: "hires", folder: folder)
        reporter.start(detail: "full pass, starting")
        var begun = RunEvent(RunEvent.Kind.hiresStart)
        begun.particles = record.particles
        begun.massive = record.massive
        begun.steps = record.steps
        begun.pass = "full"
        reporter.record(begun)
        print(
            String(
                format:
                    "hires      %d particles%@, step %.5f Myr, settle %d, %d steps, %d frames, clip %.1f to %.1f Myr,"
                    + " full pass on %@",
                record.particles, record.massive.map { " from \($0) massive" } ?? "", record.timeStepMyr,
                record.settle, record.steps, record.frames, record.clipStartMyr, record.clipEndMyr,
                CUDAEngineCheck.engine))
        let context = try CUDAContext()
        do {
            try FullPassRun(
                arguments: plan.arguments, engine: CUDAFullPassMaker(context: context, threads: threads),
                started: started, reporter: reporter, hires: (folder, record)
            ).run()
        } catch {
            reporter.finish()
            throw error
        }
        reporter.finish()
    } catch {
        fail("hires: \(error)")
    }
    print(String(format: "done in %.1f s", Date().timeIntervalSince(started)))
    exit(0)
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
