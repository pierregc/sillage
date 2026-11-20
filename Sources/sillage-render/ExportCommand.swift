import CoreGraphics
import Foundation
import SillageCore
import SillageRender
import simd

/// What a still that measures its own exposure (#340) was drawn with.
func exposureLine(_ solved: ExposureSolver.Solution) -> String {
    String(
        format: "exposure   brightness x%.3f, stretch x%.3f: L50 %.3f, L99 %.3f, lit %.0f %%, %d draws",
        solved.scale.brightness, solved.scale.stretch, solved.reading.median, solved.reading.top,
        solved.reading.lit * 100, solved.draws)
}

/// `export <scene folder>`: the take drawn with the scene's look into `exports/<preset>.mp4`,
/// HEVC unless the preset or `--codec` says otherwise; another codec adds its name, as
/// `<preset>-h264.mp4` and `<preset>-prores.mov`.
func exportStage(_ folder: SceneFolder, options: [String], reporter: StageReporter) throws -> Int32 {
    // A line at a time even into a file, so that a long export started detached can be followed.
    setvbuf(stdout, nil, _IOLBF, 0)
    func option(_ name: String) -> String? {
        options.firstIndex(of: "--\(name)").flatMap {
            $0 + 1 < options.count ? options[$0 + 1] : nil
        }
    }
    func value(_ name: String) throws -> Double? {
        guard let text = option(name) else { return nil }
        guard let number = Double(text), number >= 0 else {
            throw SceneFolder.ExportError.badValue(name, text)
        }
        return number
    }

    let presetName = option("preset") ?? "1080p"
    guard let preset = VideoPreset.named(presetName) else {
        throw SceneFolder.ExportError.noSuchPreset(presetName)
    }
    let codec: VideoCodec
    if let name = option("codec") {
        guard let named = VideoCodec(rawValue: name.lowercased()) else {
            throw SceneFolder.ExportError.noSuchCodec(name)
        }
        codec = named
    } else {
        codec = preset.defaultCodec
    }
    if let pinned = preset.codec, pinned != codec {
        throw SceneFolder.ExportError.codecNotAllowed(preset: preset.name, codec: pinned)
    }
    let takeURL = option("take").map { URL(fileURLWithPath: $0) } ?? folder.take
    guard FileManager.default.fileExists(atPath: takeURL.path) else {
        throw SceneFolder.LookError.noTake(folder.url)
    }
    let loaded = try RecordingFile.read(from: takeURL)
    let scenePalette =
        (try? Data(contentsOf: folder.look)).flatMap { try? LookFile.decoded(from: $0) }?.palette
        .nonEmpty ?? loaded.scene.galaxies.map { GalaxyColours($0.color) }
    var look = try folder.exportLook(option("look"), catalogue: catalogueLooks())
    if look.palette.isEmpty { look.palette = scenePalette }
    // For this export only: the scene's look.json is left as it is.
    if let choice = option("palette") {
        apply(
            try resolvePalette(
                folder, choice: choice, world: askedWorld(option("world"), command: "export"),
                command: "export", single: options.contains("--single")), to: &look)
    }

    let capturedRate = try folder.capturedRate()
    // `--framing <take>`: the camera, the painted arms, the time and the exposure of another take
    // of the same run, as a full pass draws them from the massive take (#239).
    let framing = try option("framing").map { try RecordingFile.read(from: URL(fileURLWithPath: $0)) }
    let speed = try option("speed").map { text in
        if let spec = PaceSpec(text) {
            let drawn = (
                width: try value("width") ?? Double(preset.width),
                height: try value("height") ?? Double(preset.height)
            )
            return try pacedTrack(
                spec, name: text, folder: folder, loaded: loaded, look: look, capturedRate: capturedRate,
                framing: framing, aspect: drawn.height / drawn.width, slow: option("slow"), csv: nil)
        }
        return try timeTrack(text, recording: loaded.recording, capturedRate: capturedRate)
    }
    // `--flight <name | file>` (#295): a camera path of its own, `flights/<name>.flight.json`
    // in the scene folder, over its own time.
    let flightURL = option("flight").map { folder.flight($0) }
    let flight = try flightURL.map { try FlightFile.decoded(from: Data(contentsOf: $0)) }
    if flight != nil, speed != nil {
        throw SceneFolder.ExportError.badValue("speed", "a flight keeps its own time, without --speed")
    }
    let export = try TakeExport(
        take: loaded, look: look, capturedRate: capturedRate, framing: framing, track: speed?.track,
        flight: flight)
    let flightName = flightURL.map {
        $0.lastPathComponent.replacingOccurrences(of: ".\(FlightFile.fileExtension)", with: "")
    }
    if let flight, let flightName {
        print(
            String(
                format:
                    "flight     %@: %d keys over %.1f s; the look's %@ camera is ignored but for look keys",
                flightName, flight.keys.count, flight.seconds, look.camera.mode.rawValue))
    }
    // `--overlay all|title,clock,scale,captions|<file>.json` (#317), over the scene's overlay.json
    // and the look's; `--no-overlay` draws none.
    if !options.contains("--no-overlay") {
        export.overlay = try folder.overlayRequest(look: look, asked: option("overlay"))
    }
    let start = try value("start") ?? 0
    // `--flight-keys <dir>`: the frame at every key of the flight as a PNG, and no video;
    // `--flight-at <s,...>` draws those seconds of the flight instead of its keys.
    if let directory = option("flight-keys") {
        guard flight != nil else {
            throw SceneFolder.ExportError.badValue("flight-keys", "it goes with --flight")
        }
        let moments = try option("flight-at").map { text in
            try text.split(separator: ",").map { part in
                guard let seconds = Double(part), seconds >= 0 else {
                    throw SceneFolder.ExportError.badValue("flight-at", text)
                }
                return seconds
            }
        }
        let width = Int(try value("width") ?? Double(preset.width))
        let height = Int(try value("height") ?? Double(preset.height))
        let out = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let started = Date()
        let keys = try export.flightKeys(width: width, height: height, at: moments)
        for (index, key) in keys.enumerated() {
            let url = out.appendingPathComponent(String(format: "key-%02d-%06.2fs.png", index, key.seconds))
            try PNGWriter.write(
                PNGWriter.image(key.rgba, width: width, height: height), maximumWidth: nil, to: url)
            print(String(format: "key        %@  %.0f ms", url.path, key.milliseconds))
        }
        if let inside = export.inside { print("inside     \(inside.summary)") }
        print(String(format: "flight     keys drawn in %.1f s", Date().timeIntervalSince(started)))
        return 0
    }
    if let name = option("format") {
        guard let format = AnimatedImage.Format(rawValue: name.lowercased()) else {
            throw SceneFolder.ExportError.badValue("format", name)
        }
        return try previewStage(
            folder, export: export, format: format, preset: options.contains("--preset") ? preset : nil,
            start: start, speed: speed, reporter: reporter, option: option, value: value)
    }

    // H.264 wants even sides.
    let width = Int(try value("width") ?? Double(preset.width)) / 2 * 2
    let height = Int(try value("height") ?? Double(preset.height)) / 2 * 2
    let fps = Int(try value("fps") ?? Double(capturedRate))
    guard width >= 16, height >= 16, fps >= 1 else {
        throw SceneFolder.ExportError.badValue("width, height or fps", "\(width)x\(height) at \(fps)")
    }
    let quality = try value("quality")
    if let quality, quality > 1 {
        throw SceneFolder.ExportError.badValue("quality", option("quality") ?? "")
    }
    let asked = try value("bitrate").map { Int($0 * 1e6) }
    if !codec.hasRateControl && (asked != nil || quality != nil) {
        throw SceneFolder.ExportError.noRateControl(codec)
    }
    let out =
        option("out").map { URL(fileURLWithPath: $0) }
        ?? folder.export(
            preset: flightName.map { "\($0)-\(preset.name)" } ?? preset.name,
            codec: codec == preset.defaultCodec ? nil : codec)
    try FileManager.default.createDirectory(
        at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
    let partial = SceneFolder.partial(out)

    let duration = try value("duration")
    let frames = export.positions(framesPerSecond: fps, start: start, duration: duration).count
    var bitRate = asked
    if bitRate == nil { bitRate = try preset.bitRate(forSeconds: Double(frames) / Double(fps)) }
    let rate = bitRate ?? codec.defaultBitRate(width: width, height: height)
    let steering =
        quality.map { String(format: "quality %.2f", $0) }
        ?? rate.map {
            String(
                format: "%.1f Mbit/s, about %.0f MB", Double($0) / 1e6,
                Double($0) * Double(frames) / Double(fps) / 8e6)
        } ?? "ProRes 422 HQ"
    print(
        String(
            format: "export     %@ %@ %dx%d at %d fps, %d frames (%.1f s from %.1f s of a %.1f s %@),"
                + " look %@, %@",
            preset.name, codec.rawValue, width, height, fps, frames, Double(frames) / Double(fps),
            start, export.videoSeconds, speed == nil ? "take" : "video", look.name, steering))
    if let speed { print(trackLine(speed, export: export, start: start, frames: frames, fps: fps)) }
    var reported = 0
    reporter.start(detail: "frame 0/\(frames)")
    // `--stills <dir> --still-frames 12,300`: those frames of the video as PNGs, as the encoder
    // took them.
    let stillsDirectory = option("stills").map { URL(fileURLWithPath: $0, isDirectory: true) }
    let stillFrames = Set(option("still-frames")?.split(separator: ",").compactMap { Int($0) } ?? [])
    if let stillsDirectory {
        try FileManager.default.createDirectory(at: stillsDirectory, withIntermediateDirectories: true)
    }
    // `--dump-targets <dir> --dump-targets-frames 12:wide,19:pericentre` (#276): for those frames
    // of the video, what the particle passes left in their targets before any post-processing
    // and what they drew from, with the take and the look, for the CUDA renderer
    // (docs/notes/cuda-engine.md). Each export adds its look to the folder. Draws nothing more.
    let dumpDirectory = option("dump-targets").map { URL(fileURLWithPath: $0, isDirectory: true) }
    var dumpFrames: [Int: String] = [:]
    for entry in option("dump-targets-frames")?.split(separator: ",") ?? [] {
        let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
        guard let index = Int(parts[0]), index >= 0 else {
            throw SceneFolder.ExportError.badValue("dump-targets-frames", String(entry))
        }
        dumpFrames[index] = parts.count > 1 ? parts[1] : String(format: "frame-%05d", index)
    }
    guard (dumpDirectory == nil) == dumpFrames.isEmpty else {
        throw SceneFolder.ExportError.badValue("dump-targets", "it goes with --dump-targets-frames")
    }
    var manifest: RenderTargetManifest?
    let lookFile = "looks/\(look.name).look.json"
    if let dumpDirectory {
        let files = FileManager.default
        let takeFile = "take/\(takeURL.lastPathComponent)"
        for file in [takeFile, lookFile] {
            let url = dumpDirectory.appendingPathComponent(file)
            try files.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? files.removeItem(at: url)
        }
        try files.copyItem(at: takeURL, to: dumpDirectory.appendingPathComponent(takeFile))
        try look.encoded().write(to: dumpDirectory.appendingPathComponent(lookFile))
        let visible = loaded.particles.visibleCount
        let take = RenderTargetManifest.Take(
            file: takeFile, scene: folder.sceneID, particles: loaded.particles.count,
            drawn: visible > 0 ? visible : loaded.particles.count,
            capturedFrames: export.capturedFrames, capturedRate: capturedRate)
        var held =
            RenderTargetManifest.read(from: dumpDirectory).flatMap {
                $0.width == width && $0.height == height && $0.take.scene == take.scene ? $0 : nil
            }
            ?? RenderTargetManifest(
                commit: "", device: "", system: "", width: width, height: height, take: take)
        held.commit = TracerWalkDump.sourceCommit()
        held.device = export.gpuName
        held.system = ProcessInfo.processInfo.operatingSystemVersionString
        held.take = take
        manifest = held
    }
    let report = try export.write(
        to: partial, width: width, height: height, framesPerSecond: fps, start: start,
        duration: duration, codec: codec, bitsPerSecond: bitRate, quality: quality,
        metadata: VideoMetadata(sceneID: folder.sceneID),
        stills: stillsDirectory == nil ? [] : stillFrames,
        still: { frame, image in
            guard let stillsDirectory else { return }
            try PNGWriter.write(
                image, maximumWidth: nil,
                to: stillsDirectory.appendingPathComponent(
                    String(format: "%@-%04d.png", preset.name, frame)))
        },
        dumps: Set(dumpFrames.keys),
        dump: { frame, capture in
            guard let dumpDirectory, let name = dumpFrames[frame] else { return }
            try manifest?.add(
                capture, look: look.name, lookFile: lookFile, name: name,
                megayearsPerUnit: Physics.megayearsPerTimeUnit, to: dumpDirectory)
            print(
                String(
                    format: "targets    frame %d (%@, %@), look %@: %@", frame, name,
                    capture.shot ?? "no plan", look.name,
                    dumpDirectory.appendingPathComponent("targets/\(look.name)/\(name)").path))
        },
        progress: { done, total in
            reporter.update(
                progress: Double(done) / Double(max(total, 1)), detail: "frame \(done)/\(total)")
            let tenth = done * 10 / max(total, 1)
            if tenth > reported {
                reported = tenth
                print("export     \(done)/\(total)")
            }
        })
    try SceneFolder.commit(out)
    if let speed { try writeTrack(speed.file, beside: out) }
    let bytes =
        (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
    for line in report.overlay { print("overlay    \(line)") }
    if let exposure = report.exposure { print("exposure   \(exposure.summary)") }
    if let inside = report.inside { print("inside     \(inside.summary)") }
    print(
        String(
            format: "export     %d frames in %.1f s, %.1f frames a second, %.2fx real time, %.1f MB",
            report.frames, report.seconds, report.renderedPerSecond, report.speed,
            Double(bytes) / 1e6))
    print("video      \(out.path)")
    var done = RunEvent(RunEvent.Kind.exportDone)
    done.preset = preset.name
    done.style = look.name
    done.setPalette(look.paletteRecipe)
    done.codec = codec.rawValue
    done.frames = report.frames
    done.megabytes = Double(bytes) / 1e6
    done.seconds = report.seconds
    done.path = out.path
    reporter.record(done)
    if let limit = preset.maxBytes, bytes > limit {
        print("warning    \(bytes / 1_000_000) MB, over the \(limit / 1_000_000) MB aimed for")
    }
    if preset.caption {
        let captionURL = out.deletingPathExtension().appendingPathExtension("txt")
        try VideoMetadata(sceneID: folder.sceneID).caption.write(
            to: captionURL, atomically: true, encoding: .utf8)
        print("caption    \(captionURL.path)")
    }
    return 0
}

/// `--speed <x>` or `--speed <file>` (#305): the whole take at one speed, from 0.25 to 16, or a
/// time track kept in a `.time.json`.
func timeTrack(_ text: String, recording: Recording, capturedRate: Int) throws -> (
    file: TimeTrackFile, track: TimeTrack, name: String
) {
    let file: TimeTrackFile
    let name: String
    if let speed = Double(text) {
        file = TimeTrackFile(speed: speed)
        name = String(format: "%gx", speed)
    } else {
        let url = URL(fileURLWithPath: text)
        guard let data = try? Data(contentsOf: url) else {
            throw SceneFolder.ExportError.badValue("speed", text)
        }
        file = try TimeTrackFile.decoded(from: data)
        name = url.lastPathComponent
    }
    let track = try file.track(
        megayears: TimeTrack.megayears(of: recording), capturedRate: capturedRate)
    return (file, track, name)
}

/// `--speed story[:pace[:top]]` or `--speed visual[:top[:busiest]]` (#309): the speed of every
/// captured frame read off the take's curves or off the take drawn small, and `--slow
/// <from>:<to>:<speed>` holds a stretch, in Myr of the take, to at most that speed. The visual pace
/// draws the take at 256 wide with the export's camera before the export starts.
func pacedTrack(
    _ spec: PaceSpec, name: String, folder: SceneFolder, loaded: RecordingFile.Loaded, look: LookFile,
    capturedRate: Int, framing: RecordingFile.Loaded?, aspect: Double, slow: String?, csv: URL?,
    drawings: (directory: URL, from: Double, to: Double, only: Bool)? = nil
) throws -> (file: TimeTrackFile, track: TimeTrack, name: String) {
    let megayears = TimeTrack.megayears(of: loaded.recording)
    var made: PaceTrack.Made
    switch spec {
    case .story:
        let read = try PaceTrack.fromCurves(
            spec, folder: folder, scene: loaded.scene, megayears: megayears)
        made = read.made
        print(
            String(
                format: "pace       %@ from %@: first pass %@ Myr, engaged until %@ Myr", name,
                read.curves.lastPathComponent, made.firstPassMyr.map { String(format: "%.0f", $0) } ?? "none",
                made.engagedUntilMyr.map { String(format: "%.0f", $0) } ?? "never"))
    case .visual(let settings):
        let started = Date()
        let drawn = try TakeExport(
            take: loaded, look: look.forVisualPace(), capturedRate: capturedRate, framing: framing
        )
        .visualChanges(
            width: 256, height: max(Int((256 * aspect).rounded()), 16),
            only: drawings.flatMap { $0.only ? $0.from...$0.to : nil },
            drawing: { myr, rgba in
                guard let drawings, myr >= drawings.from, myr <= drawings.to else { return }
                try FileManager.default.createDirectory(
                    at: drawings.directory, withIntermediateDirectories: true)
                try PNGWriter.write(
                    PNGWriter.image(rgba, width: 256, height: max(Int((256 * aspect).rounded()), 16)),
                    to: drawings.directory.appendingPathComponent(String(format: "%.2f.png", myr)))
            })
        made = PaceTrack.visual(settings, times: drawn.times, changes: drawn.changes, megayears: megayears)
        print(
            String(
                format: "pace       %@: %d drawings in %.1f s", name, drawn.times.count,
                Date().timeIntervalSince(started)))
    }
    if let slow {
        let parts = slow.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 3, parts[2] > 0 else { throw SceneFolder.ExportError.badValue("slow", slow) }
        made.speeds = PaceSpec.slowed(
            made.speeds, megayears: megayears, from: parts[0], to: parts[1], speed: parts[2])
    }
    let file = TimeTrackFile(speeds: made.speeds)
    let track = try file.track(megayears: megayears, capturedRate: capturedRate)
    if let csv {
        try made.traceCSV.write(
            to: csv.deletingPathExtension().appendingPathExtension("trace.csv"), atomically: true,
            encoding: .utf8)
        try PaceTrack.videoCSV(track, megayears: megayears, framesPerSecond: capturedRate).write(
            to: csv, atomically: true, encoding: .utf8)
    }
    return (file, track, slow.map { "\(name) slowed \($0)" } ?? name)
}

/// The video's length and the take's span, for an export along a time track.
func trackLine(
    _ speed: (file: TimeTrackFile, track: TimeTrack, name: String), export: TakeExport,
    start: Double, frames: Int, fps: Int
) -> String {
    let shown = export.videoFrames(
        framesPerSecond: fps, start: start, duration: Double(frames) / Double(fps))
    let megayears = TimeTrack.megayears(of: export.take.recording)
    func myr(_ position: Double) -> Double {
        let index = min(max(Int(position), 0), megayears.count - 1)
        let next = min(index + 1, megayears.count - 1)
        return megayears[index] + (megayears[next] - megayears[index]) * (position - Double(index))
    }
    return String(
        format: "speed      %@: %.1f s of video for %.1f to %.1f Myr of the take (frames %.1f to %.1f),"
            + " a %.1f s video of a %.1f s take",
        speed.name, Double(shown.count) / Double(fps), myr(shown.first?.captured ?? 0),
        myr(shown.last?.captured ?? 0), shown.first?.captured ?? 0, shown.last?.captured ?? 0,
        export.videoSeconds, export.takeSeconds)
}

/// The track an export drew along, beside it as `<name>.time.json`.
func writeTrack(_ file: TimeTrackFile, beside out: URL) throws {
    let url = out.deletingPathExtension().appendingPathExtension(TimeTrackFile.fileExtension)
    try file.encoded().write(to: url)
    print("track      \(url.path)")
}

/// `export <scene folder> --format webp|gif`: a looping preview, 960 wide at 16 fps for eight
/// seconds unless told otherwise.
func previewStage(
    _ folder: SceneFolder, export: TakeExport, format: AnimatedImage.Format, preset: VideoPreset?,
    start: Double, speed: (file: TimeTrackFile, track: TimeTrack, name: String)?,
    reporter: StageReporter, option: (String) -> String?,
    value: (String) throws -> Double?
) throws -> Int32 {
    let width = Int(try value("width") ?? 960)
    let aspect = preset.map { Double($0.height) / Double($0.width) } ?? 9.0 / 16
    let height = Int(try value("height") ?? (Double(width) * aspect).rounded())
    let fps = Int(try value("fps") ?? 16)
    let duration = try value("duration") ?? 8
    // From 0 to 1 as for a video.
    let quality = try value("quality") ?? 0.8
    guard width >= 16, height >= 16, fps >= 1, quality <= 1 else {
        throw SceneFolder.ExportError.badValue(
            "width, height, fps or quality", "\(width)x\(height) at \(fps)")
    }
    let maximum = try option("max-size").map {
        guard let bytes = AnimatedImage.bytes($0) else {
            throw SceneFolder.ExportError.badValue("max-size", $0)
        }
        return bytes
    }
    let out =
        option("out").map { URL(fileURLWithPath: $0) }
        ?? folder.preview(preset?.name ?? "preview", extension: format.rawValue)
    try FileManager.default.createDirectory(
        at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
    print(
        String(
            format: "export     %@ %dx%d at %d fps, %.1f s from %.1f s of a %.1f s %@, look %@%@",
            format.rawValue, width, height, fps, duration, start, export.videoSeconds,
            speed == nil ? "take" : "video", export.look.name,
            maximum.map { String(format: ", at most %.1f MB", Double($0) / 1e6) } ?? ""))
    if let speed {
        let frames = export.positions(framesPerSecond: fps, start: start, duration: duration).count
        print(trackLine(speed, export: export, start: start, frames: frames, fps: fps))
    }
    reporter.start(detail: "\(format.rawValue) preview")
    let report = try export.writePreview(
        to: SceneFolder.partial(out), format: format, width: width, height: height,
        framesPerSecond: fps, start: start, duration: duration, maximumBytes: maximum,
        quality: Int((quality * 100).rounded()))
    try SceneFolder.commit(out)
    if let speed { try writeTrack(speed.file, beside: out) }
    for attempt in report.attempts.dropLast() {
        print(
            String(
                format: "export     %d wide at %d fps: %.1f MB, too big", attempt.width,
                attempt.framesPerSecond, Double(attempt.bytes) / 1e6))
    }
    print(
        String(
            format: "export     %dx%d, %d frames at %.1f fps, %.1f MB in %.1f s",
            report.width, report.height, report.frames,
            AnimatedImage.playedRate(report.framesPerSecond, format: format),
            Double(report.bytes) / 1e6, report.seconds))
    if let maximum, report.bytes > maximum {
        print(
            "export     still over \(maximum / 1_000_000) MB at the smallest size tried: shorten it with --duration"
        )
    }
    print("preview    \(out.path)")
    var done = RunEvent(RunEvent.Kind.exportDone)
    done.preset = preset?.name
    done.style = export.look.name
    done.setPalette(export.look.paletteRecipe)
    done.codec = format.rawValue
    done.frames = report.frames
    done.megabytes = Double(report.bytes) / 1e6
    done.seconds = report.seconds
    done.path = out.path
    reporter.record(done)
    return 0
}
