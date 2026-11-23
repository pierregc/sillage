import Foundation
import SillageCUDA
import SillageCore
import SillageRender

/// `sillage-cuda`, the CUDA engine's command on Linux (#277, #278, #378): `explore` runs a scene's
/// preview (#430), `hires` computes a scene folder, the pass that writes its take or its full
/// pass, on the GPU library or on the CPU target, whichever it was linked with; `check` holds that
/// engine to the reference outputs first; `still` draws chosen frames of a take as PNGs; `export`
/// draws a take's video, along a flight or not (#382, #429); `status` says how far a run has got.
/// docs/notes/cuda-engine.md.

func fail(_ message: String) -> Never {
    RunSummary.end(status: 1, error: message)
    FileHandle.standardError.write(Data("sillage-cuda: \(message)\n".utf8))
    exit(1)
}

let usage = """
    usage: sillage-cuda <command> --help   the options of one command
           sillage-cuda explore <scene folder> [options]
           sillage-cuda hires <scene folder> [--particles N] [--massive N] [--pass massive|full] [options]
           sillage-cuda check [--fixtures <dir>] [--record <file>]
           sillage-cuda status <scene folder>
           sillage-cuda match <scene folder> <picture.map.json> [options]
           sillage-cuda take extract <take> --at <myr,...> [--span <frames>] <out.sillage>
           sillage-cuda flight <scene folder> --at <myr,...> [--look <name>] [--take <file>] [--arms <kpc,...>]
           sillage-cuda look <scene folder> --palette <auto|family|file> | --promote <name> [options]
           sillage-cuda pace <scene folder> --speed story[:pace[:top]] [--slow <from>:<to>:<speed>] [--out <file>]
           sillage-cuda still <take> --look <look> [--framing <massive take>]
               [--preset 1080p|4k|vertical|square|whatsapp] [--width W --height H]
               --frames 0,200,900 [--fps N] [--rate N] [--threads N] --out <dir>
           sillage-cuda still <take> --look <look> --flight <file> --seconds 0,2.5,9 [...] --out <dir>
           sillage-cuda export <scene folder | take> [--flight <name | file>] [--look <look>]
               [--speed <x>|<file>|story[:pace[:top]] [--slow <from>:<to>:<speed>]] [--framing <massive take>] [--preset 1080p|4k|vertical|square|whatsapp]
               [--width W --height H] [--fps N] [--start s] [--duration s] [--codec hevc|h264|prores]
               [--bitrate Mbit] [--out <file>] [--resume] [--part k/n] [--device N] [--profile]
           sillage-cuda export <scene folder | take> --flight <name | file> --flight-keys <dir>
               [--flight-at 0,2.5,9]
           sillage-cuda black-hole still <folder> <png> [--at t] [--look name] [--width W --height H]
               [--elevation deg] [--azimuth deg] [--distance r] [--fov deg] [--straight] [--images n]
               [--temperature radius|crossing] [--hottest K] [--beaming x] [--exposure x] [--stars n]
               [--thinning x] [--flight name|file --second s]

    An option a command does not read, a value that does not parse or a stray word is refused with
    the command's usage and exit status 2 before anything runs (#465).

    explore runs a scene's preview as sillage-render explore does on the Mac (#430), from the
    same options: a folder with nothing in it starts a free draw at the batch's defaults, one with
    a scene.json runs it. It writes clip.json with the story the run followed, scene.json,
    look.json, preview.mov, curves.csv and thumbnail.png, and exits 3 on a scene that would show
    nothing.

    hires computes a scene folder explored here or on the Mac, as sillage-render hires does there.
    Without --pass it is the pass that writes the take, one pass of every particle (#378): it
    reads scene.json, clip.json and look.json, samples the scene here, and writes take.sillage,
    curves-hires.csv, hires.mov and hires.json, so the folder goes back to the Mac as a hires
    made there. --pass massive runs the massive particles of a draw with light tracers alone
    (--massive below --particles) and writes massive.bin too. --pass full runs the full pass of
    a folder whose massive pass is done, here or on the Mac (#278): it reads take.sillage,
    curves-hires.csv, hires.json and massive.bin, and writes exports/<preset>.<ext>,
    keyframes.sillage, keyframes.json and the full section of hires.json. Options:
    --checkpoint-every <minutes>, --checkpoint-frames N, --checkpoint-steps N, --resume,
    --dt-schedule off|story|<entries>, --take-interval N, --no-video (no hires.mov, the take
    alone), --profile, --threads N (the CPU target's drawing); for --pass full --export 4k,vertical,
    --tracer-sort N, --tracer-sort-chunk N, --draw-stills 0,12 [--draw-stills-dir <dir>],
    --draw-divisor N, --speed <x>|<file> (the videos along a time track, #310), --key-frames-at
    <myr,...> [--key-frames-span N] (every drawn particle kept at the frames nearest those moments
    too, #379; --stop-after-key-frames ends the run once they are kept). It refuses to start on
    an engine whose check did not pass for this build.

    check builds the reference tree and draws the reference frames of Tests/Fixtures/engines
    with this build, and records the outcome beside the libraries (engine-check.json).

    still draws those frames of the take as PNGs, as `sillage-render export --stills` does: frame
    N is the Nth frame of a video of the take at --fps (the captured rate by default), and the
    film grain stands where that frame finds it. <look> is a look file, or the name of one in
    looks/ beside the take or in the current directory. The captured rate is read from
    hires.json or clip.json beside the take unless --rate gives it.

    With --flight, a flight file (docs/notes/flights.md), --seconds lists moments of the flight
    in place of --frames: each is the frame the video shows there at --fps, drawn from inside a
    galaxy where the eye is near matter (point stars, motion blur) at its own automatic exposure.

    export draws a take's video as sillage-render export does on the Mac, encoded by ffmpeg.
    Without --flight (#429): the look's camera, along a time track with --speed (one speed, a
    .time.json, or story read off the curves, held with --slow; the visual pace is the Mac's, whose
    .time.json is given instead), the look's exposure measured once over the video, into
    exports/<preset>.mp4 of the scene folder, the track written beside it. With --flight (#382):
    the camera, the time, the inside of a galaxy and the exposure of the flight, measured once
    along the whole of it, into exports/<flight>-<preset>.mp4. The video is drawn in segments of whole files (--segment-frames N, a second of video
    by default) kept beside it until it is whole: a run that stops loses one at most, --resume
    draws the ones missing and joins them without encoding them again, and --part k/n draws one
    segment in n, for several GPUs (--device N) or several boxes on one video. --flight-keys
    draws the frame at every key of the flight, or at the seconds of --flight-at, as PNGs, each
    at its own exposure, and no video. --no-overlay draws a look that asks for words without
    them: they are the Mac's. --stills <dir> --still-frames 0,12 keeps those frames as PNGs,
    --large-splats <pixels>|off sets the size past which a splat is drawn by a block of threads
    on a GPU (1024 by default, the same bits either way), --profile times each phase, and --rate,
    --take and --threads are as for still and hires.

    match finds the moment and the view where the take overlaps a real picture best, on the CPU,
    as sillage-render match does (#320); `sillage-cuda match` alone gives its options.

    take extract writes the frames of a take nearest those moments, and the span - 1 frames after
    each, as a take of their own with their centres and disk states, as sillage-render take
    extract does (#379): a few frames of a large take come back without the rest.

    black-hole still draws one moment of a black hole close up's take as sillage-render
    black-hole still does (#336): --at in the hole's time units, the end of the run by default,
    stepped on from the frame the take kept before it.
    """

let arguments = Array(CommandLine.arguments.dropFirst())
switch CUDACommands.check(arguments, overview: usage) {
case .run: break
case .help(let text):
    print(text)
    exit(0)
case .refused(let message):
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}
let command = arguments[0]
if ["explore", "hires", "export"].contains(command), arguments.count > 1 {
    RunSummary.begin(
        command: command, engine: CUDAContext.target == .gpu ? "cuda" : "cuda-cpu", target: arguments[1],
        arguments: Array(arguments.dropFirst(2)))
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

if command == "match" {
    exit(PhotoMatchCommand.main(rest))
}

if command == "check" {
    do {
        let context = try CUDAContext()
        var record = CUDAEngineCheck.run(
            context: context, fixtures: fixtures(),
            threads: integer("threads") ?? ProcessInfo.processInfo.activeProcessorCount)
        // The black hole close up's, beside the engines' fixtures (#336).
        let hole = fixtures().deletingLastPathComponent().appendingPathComponent("hole")
        if FileManager.default.fileExists(atPath: hole.appendingPathComponent("manifest.json").path) {
            record.items += CUDAHoleCheck.items(context: context, folder: hole)
        }
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

if command == "black-hole" {
    let options = HoleOptions(rest)
    guard options.words.first == "still", options.words.count == 3 else {
        fail("black-hole still <folder> <png>\n\n\(usage)")
    }
    do {
        let started = Date()
        let context = try CUDAContext()
        let picture = try CUDAHoleStill.draw(
            options, folder: SceneFolder(path: options.words[1]), context: context)
        try PNG.write(
            PNG.Image(width: picture.width, height: picture.height, channels: 3, bytes: picture.pixels),
            to: URL(fileURLWithPath: options.words[2]))
        print(
            String(
                format: "t = %.1f, %.2f s on %@ (%@)", picture.time, Date().timeIntervalSince(started),
                CUDAContext.target == .gpu ? "the GPU" : "the CPU target", context.name))
    } catch {
        fail("black-hole: \(error)")
    }
    exit(0)
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

if command == "flight" {
    do {
        let catalogue = (try? LookCatalogue.fromRepository()) ?? []
        for line in try FlightReport.lines(rest, catalogue: catalogue) { print(line) }
    } catch {
        fail("flight: \(error)")
    }
    exit(0)
}

if command == "look" {
    do {
        for line in try LookChoice.lines(rest, command: "sillage-cuda") { print(line) }
    } catch {
        fail("look: \(error)")
    }
    exit(0)
}

if command == "pace" {
    do {
        for line in try PaceStory.lines(rest, command: "sillage-cuda") { print(line) }
    } catch {
        fail("pace: \(error)")
    }
    exit(0)
}

if command == "take" {
    do {
        for line in try TakeExtract.command(rest) { print(line) }
    } catch {
        fail("take: \(error)")
    }
    exit(0)
}

if command == "explore" {
    guard let path = rest.first, !path.hasPrefix("--") else { fail("no scene folder\n\n\(usage)") }
    var options = Array(rest.dropFirst())
    var threads = ProcessInfo.processInfo.activeProcessorCount
    if let index = options.firstIndex(of: "--threads"), index + 1 < options.count {
        threads = Int(options[index + 1]) ?? threads
        options.removeSubrange(index...index + 1)
    }
    signal(SIGPIPE, SIG_IGN)
    do {
        let outcome = try CUDAExplore.run(
            SceneFolder(path: path), options: options, context: try CUDAContext(), threads: threads)
        if outcome == .rejected { RunSummary.end(status: 3, error: "the scene would show nothing") }
        exit(outcome == .rejected ? 3 : 0)
    } catch {
        fail("explore: \(error)")
    }
}

if command == "hires" {
    guard let path = rest.first, !path.hasPrefix("--") else { fail("no scene folder\n\n\(usage)") }
    var options = Array(rest.dropFirst())
    var threads = ProcessInfo.processInfo.activeProcessorCount
    if let index = options.firstIndex(of: "--threads"), index + 1 < options.count {
        threads = Int(options[index + 1]) ?? threads
        options.removeSubrange(index...index + 1)
    }
    // A run whose encoder stops must fail with ffmpeg's message, not die of a broken pipe.
    signal(SIGPIPE, SIG_IGN)
    let started = Date()
    do {
        try CUDAHires.run(
            SceneFolder(path: path), options: options, context: try CUDAContext(), threads: threads,
            started: started)
    } catch {
        fail("hires: \(error)")
    }
    exit(0)
}

if command == "export" {
    guard let path = rest.first, !path.hasPrefix("--") else { fail("no scene folder or take\n\n\(usage)") }
    signal(SIGPIPE, SIG_IGN)
    do {
        let context = try CUDAContext(device: option("device").flatMap { Int($0) } ?? 0)
        try CUDAExport.run(
            path, options: Array(rest.dropFirst()), context: context,
            threads: integer("threads") ?? ProcessInfo.processInfo.activeProcessorCount)
    } catch {
        fail("export: \(error)")
    }
    exit(0)
}

guard let takePath = rest.first, !takePath.hasPrefix("--") else { fail("no take\n\n\(usage)") }
let takeURL = URL(fileURLWithPath: takePath)
guard let lookName = option("look") else { fail("--look is needed\n\n\(usage)") }
let flightPath = option("flight")
guard let framesText = option(flightPath == nil ? "frames" : "seconds") else {
    fail("\(flightPath == nil ? "--frames" : "--seconds") is needed\n\n\(usage)")
}
guard let outPath = option("out") else { fail("--out is needed\n\n\(usage)") }
let frames = flightPath == nil ? framesText.split(separator: ",").compactMap { Int($0) } : []
let moments = flightPath == nil ? [] : framesText.split(separator: ",").compactMap { Double($0) }
if flightPath == nil {
    guard !frames.isEmpty, frames.count == framesText.split(separator: ",").count,
        frames.allSatisfy({ $0 >= 0 })
    else { fail("--frames is a list of frame numbers, as 0,200,900") }
} else {
    guard !moments.isEmpty, moments.count == framesText.split(separator: ",").count,
        moments.allSatisfy({ $0 >= 0 })
    else { fail("--seconds is a list of seconds of the flight, as 0,2.5,9") }
}

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
    let flight = try flightPath.map {
        try FlightFile.decoded(from: Data(contentsOf: URL(fileURLWithPath: $0)))
    }
    let drawing = try CUDATakeStills(
        context: context, take: take, look: look, capturedRate: rate, width: width,
        height: height, framing: framing, flight: flight)
    let framesPerSecond = integer("fps") ?? rate
    let threads = integer("threads") ?? ProcessInfo.processInfo.activeProcessorCount
    let out = URL(fileURLWithPath: outPath, isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    print(
        "still      \(preset.name) \(width)x\(height), look \(look.name), \(take.recording.particleCount)"
            + " particles, \(drawing.capturedFrames) captured frames at \(rate) a second, on "
            + "\(CUDAContext.target == .gpu ? "the GPU" : "the CPU target") (\(context.name))")
    for seconds in moments {
        let started = Date()
        let index = Int((seconds * Double(framesPerSecond)).rounded())
        let pixels = try drawing.flightStill(
            atSeconds: seconds, frame: index, interval: 1 / Double(framesPerSecond), format: .rgb,
            threads: threads)
        let image = PNG.Image(width: width, height: height, channels: 3, bytes: [UInt8](pixels))
        let url = out.appendingPathComponent(String(format: "%@-flight-%07.2fs.png", preset.name, seconds))
        try PNG.write(image, to: url)
        var line = String(
            format: "still      %@  %.2f s", url.lastPathComponent, Date().timeIntervalSince(started))
        if let drawn = drawing.lastFlightFrame {
            line += String(
                format: ", nearest matter %.3f kpc, exposure down %.1f stops, %d renders, %d point stars",
                drawn.nearness, drawn.stops, drawn.renders, drawn.stars)
        }
        print(line)
    }
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
