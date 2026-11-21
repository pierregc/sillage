import Foundation
import SillageCore
import SillageRender

/// `sillage-cuda export <scene folder | take> [--flight <name | file>]`: a take's video drawn on
/// CUDA, the frames the Mac's `export` draws, encoded by ffmpeg: along a flight (#382,
/// `FlightFrames`), or with the look's camera along a time track (#429, `TakeFrames`). The video
/// is drawn in segments of whole files, each kept as soon as it is drawn, so that a run that
/// stops, a box taken back or a device out of memory, loses one segment at most: `--resume` draws
/// the ones missing and joins them all without encoding them again. The exposure of the whole
/// video is measured once and kept beside the segments, so that every piece, whenever and wherever
/// it is drawn, is drawn under it. `--part k/n` draws one segment in n, for several GPUs or boxes
/// on one video. docs/notes/flights.md, docs/notes/cuda-engine.md.
public enum CUDAExport {
    public enum Failure: Error, CustomStringConvertible {
        case usage(String)
        case overlay
        case otherExport(folder: URL, differs: [String])
        case outOfMemory(String)

        public var description: String {
            switch self {
            case .usage(let why): why
            case .overlay:
                "this engine draws no overlay (#317): its words are set with Core Text, which Linux"
                    + " does not have. --no-overlay draws the video without them"
            case .otherExport(let folder, let differs):
                "the segments in \(folder.path) are another export's (\(differs.joined(separator: ", "))"
                    + " differ): without --resume and --part the export starts again"
            case .outOfMemory(let why): why
            }
        }
    }

    public struct Report: Sendable {
        /// Where the video is, or will be once every segment is drawn.
        public var out: URL
        /// The frames of the whole video, and the ones this run drew.
        public var frames = 0
        public var drawn = 0
        public var segments = 0
        public var segmentsDone = 0
        /// Whether the video is whole and in place.
        public var joined = false
        /// Seconds this run spent drawing and encoding.
        public var seconds = 0.0
        public var inside = FlightFrames.Report()
        public var exposure: FlightFrames.Exposure?
        /// A digest of the frames of each segment done, as drawn, before the encoder.
        public var pixels: [String] = []
        /// The stills of `--flight-keys`.
        public var keys: [URL] = []
    }

    // MARK: - What is kept beside the segments

    /// What a segment must have been drawn from and for to belong to an export.
    struct Identity: Codable, Equatable {
        var take: String
        var takeBytes: Int
        var particles: Int
        var capturedFrames: Int
        var framing: String?
        var framingBytes: Int?
        var look: String
        var flight: String?
        var track: String?
        var capturedRate: Int
        var width: Int
        var height: Int
        var framesPerSecond: Int
        var start: Double
        var duration: Double?
        var frames: Int
        var segmentFrames: Int
        var codec: String
        var bitsPerSecond: Int?
        var laceTexels: Int
        var engine: String

        func differences(from other: Identity) -> [String] {
            let (mine, theirs) = (Mirror(reflecting: self).children, Mirror(reflecting: other).children)
            return zip(mine, theirs).compactMap { a, b in
                String(describing: a.value) == String(describing: b.value) ? nil : a.label
            }
        }
    }

    /// The exposure of the whole flight, to the bit: a float's decimal may not read back as it
    /// was written.
    struct Plan: Codable, Equatable {
        var version = 1
        var identity: Identity
        var scale: [UInt32]?
        var target: UInt32
        var trimStep: Double?
        var trimEase: Double?
        var trimStops: [UInt64]?
        var trimStill: [[UInt64]]?
        /// For a person reading the file.
        var summary: String
        var measuredIn: Double
        var device: String

        init(
            identity: Identity, exposure: FlightFrames.Exposure, summary: String, seconds: Double,
            device: String
        ) {
            self.identity = identity
            scale = exposure.scale.map { [$0.brightness.bitPattern, $0.stretch.bitPattern] }
            target = exposure.target.bitPattern
            if let trims = exposure.trims {
                trimStep = trims.step
                trimEase = trims.ease
                trimStops = trims.stops.map(\.bitPattern)
                trimStill = trims.still.map { [$0.lowerBound.bitPattern, $0.upperBound.bitPattern] }
            }
            self.summary = summary
            measuredIn = seconds
            self.device = device
        }

        var exposure: FlightFrames.Exposure {
            var trims: InsideExposure.Track?
            if let trimStep, let trimEase, let trimStops {
                trims = InsideExposure.Track(
                    step: trimStep, stops: trimStops.map { Double(bitPattern: $0) }, ease: trimEase,
                    still: (trimStill ?? []).compactMap {
                        $0.count == 2 ? Double(bitPattern: $0[0])...Double(bitPattern: $0[1]) : nil
                    })
            }
            return FlightFrames.Exposure(
                scale: scale.flatMap {
                    $0.count == 2
                        ? ExposureScale(
                            brightness: Float(bitPattern: $0[0]), stretch: Float(bitPattern: $0[1]))
                        : nil
                }, target: Float(bitPattern: target), trims: trims)
        }
    }

    /// A segment drawn, written once its video is whole.
    struct Segment: Codable {
        var index: Int
        var first: Int
        var frames: Int
        var seconds: Double
        /// The digest of the plan it was drawn under, and of its frames as drawn.
        var plan: String
        var pixels: String
        var report: FlightFrames.Report
        var device: String
    }

    static func digest(_ data: Data) -> String {
        var hash = PortableSHA256()
        hash.update(data: data)
        return hash.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }

    /// Where the segments of the video at `out` are kept until it is whole.
    public static func segments(of out: URL) -> URL {
        out.deletingLastPathComponent().appendingPathComponent(
            ".\(out.lastPathComponent).segments", isDirectory: true)
    }

    /// The look an export of `folder`'s take is drawn with: the one asked for, or the scene's,
    /// with the scene's palette, or the take's own colours, when it names none.
    static func look(_ name: String?, folder: SceneFolder, take: RecordingFile.Loaded) throws -> LookFile {
        var look = try folder.exportLook(name, catalogue: (try? LookCatalogue.fromRepository()) ?? [])
        if look.palette.isEmpty {
            let scene = (try? Data(contentsOf: folder.look)).flatMap { try? LookFile.decoded(from: $0) }?
                .palette
            look.palette =
                scene.flatMap { $0.isEmpty ? nil : $0 } ?? take.scene.galaxies.map { GalaxyColours($0.color) }
        }
        return look
    }

    // MARK: - The command

    /// Runs the export `options` ask for. `stop`, for tests, ends the run after a segment as a
    /// kill between two segments would; `laceTexels` draws a smaller lace, for tests too.
    @discardableResult
    public static func run(
        _ target: String, options: [String], context: CUDAContext,
        threads: Int = ProcessInfo.processInfo.activeProcessorCount,
        laceTexels: Int = DustWeb.laceTexels, stop: ((_ segmentsDrawn: Int) -> Bool)? = nil
    ) throws -> Report {
        func option(_ name: String) -> String? {
            options.firstIndex(of: "--\(name)").flatMap { $0 + 1 < options.count ? options[$0 + 1] : nil }
        }
        func flag(_ name: String) -> Bool { options.contains("--\(name)") }
        func value(_ name: String) throws -> Double? {
            guard let text = option(name) else { return nil }
            guard let number = Double(text), number >= 0 else {
                throw SceneFolder.ExportError.badValue(name, text)
            }
            return number
        }
        func whole(_ name: String) throws -> Int? {
            guard let text = option(name) else { return nil }
            guard let number = Int(text), number > 0 else {
                throw SceneFolder.ExportError.badValue(name, text)
            }
            return number
        }

        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: target, isDirectory: &isDirectory) else {
            throw Failure.usage("no scene folder or take at \(target)")
        }
        let inFolder = isDirectory.boolValue
        let folder = SceneFolder(
            inFolder
                ? URL(fileURLWithPath: target, isDirectory: true)
                : URL(fileURLWithPath: target).deletingLastPathComponent())
        let takeURL =
            inFolder
            ? option("take").map { URL(fileURLWithPath: $0) } ?? folder.take : URL(fileURLWithPath: target)
        guard manager.fileExists(atPath: takeURL.path) else { throw SceneFolder.LookError.noTake(folder.url) }

        let presetName = option("preset") ?? "1080p"
        guard let preset = VideoPreset.named(presetName) else {
            throw SceneFolder.ExportError.noSuchPreset(presetName)
        }
        var codec = preset.defaultCodec
        if let name = option("codec") {
            guard let named = VideoCodec(rawValue: name.lowercased()) else {
                throw SceneFolder.ExportError.noSuchCodec(name)
            }
            codec = named
        }
        if let pinned = preset.codec, pinned != codec {
            throw SceneFolder.ExportError.codecNotAllowed(preset: preset.name, codec: pinned)
        }

        let flightURL = option("flight").map { folder.flight($0) }
        let flightFile = try flightURL.map { try FlightFile.decoded(from: Data(contentsOf: $0)) }
        let flightName = flightURL.map {
            $0.lastPathComponent.replacingOccurrences(of: ".\(FlightFile.fileExtension)", with: "")
        }
        if flightFile != nil, option("speed") != nil {
            throw SceneFolder.ExportError.badValue("speed", "a flight keeps its own time, without --speed")
        }
        if flightFile == nil, option("flight-keys") != nil {
            throw SceneFolder.ExportError.badValue("flight-keys", "it goes with --flight")
        }

        let loaded = try RecordingFile.read(from: takeURL)
        let look = try look(option("look"), folder: folder, take: loaded)
        let asksOverlay =
            option("overlay") != nil || manager.fileExists(atPath: folder.overlay.path)
            || !(look.overlay?.isEmpty ?? true)
        if asksOverlay {
            guard flag("no-overlay") else { throw Failure.overlay }
            say("overlay    not drawn (--no-overlay): the words over a video are the Mac's (#317)")
        }
        guard let capturedRate = try whole("rate") ?? (try? folder.capturedRate()) else {
            throw Failure.usage(
                "the captured rate is in neither hires.json nor clip.json beside the take: give --rate")
        }
        let framingURL = option("framing").map { URL(fileURLWithPath: $0) }
        let framing = try framingURL.map { try RecordingFile.read(from: $0) }

        let width = (try whole("width") ?? preset.width) / 2 * 2
        let height = (try whole("height") ?? preset.height) / 2 * 2
        let fps = try whole("fps") ?? capturedRate
        guard width >= 16, height >= 16 else {
            throw SceneFolder.ExportError.badValue("width or height", "\(width)x\(height)")
        }
        // On a GPU the large splats go the second way unless told otherwise; the CPU target
        // draws from several host threads the first way, and gains nothing from the second.
        var largeSplats = CUDAContext.target == .gpu ? CUDATakeStills.flightLargeSplatPixels : 0
        if let text = option("large-splats") {
            guard let pixels = text == "off" ? 0 : Int(text), pixels >= 0 else {
                throw SceneFolder.ExportError.badValue("large-splats", text)
            }
            largeSplats = pixels
        }
        // The exposure of the flight and its frames are timed apart.
        let phases = flag("profile") ? PhaseTimes() : nil
        let measuring = flag("profile") ? PhaseTimes() : nil
        let engine = CUDAContext.target == .gpu ? "the GPU" : "the CPU target"

        let planned = try flightFile.map {
            try FlightFrames(
                take: loaded, look: look, capturedRate: capturedRate, width: width, height: height,
                framing: framing, flight: $0)
        }
        if let flightFile, let flightName {
            say(
                String(
                    format:
                        "flight     %@: %d keys over %.1f s; the look's %@ camera is ignored but for look keys",
                    flightName, flightFile.keys.count, flightFile.seconds, look.camera.mode.rawValue))
        }
        let speed = try option("speed").map {
            try timeTrack($0, slow: option("slow"), folder: folder, take: loaded, capturedRate: capturedRate)
        }
        if speed == nil, option("slow") != nil {
            throw SceneFolder.ExportError.badValue("slow", "it goes with --speed story")
        }
        let plain =
            planned != nil
            ? nil
            : try TakeFrames(
                take: loaded, look: look, capturedRate: capturedRate, width: width, height: height,
                framing: framing, track: speed?.track)

        var stills: CUDATakeStills?
        func drawing() throws -> CUDATakeStills {
            if let stills { return stills }
            do {
                let made = try CUDATakeStills(
                    context: context, take: loaded, look: look, capturedRate: capturedRate, width: width,
                    height: height, framing: framing, laceTexels: laceTexels, flight: flightFile,
                    largeSplatPixels: largeSplats)
                made.threads = threads
                made.phases = phases
                stills = made
                return made
            } catch let error as CUDAError where error.code == .outOfMemory {
                throw Failure.outOfMemory(memoryAdvice(error, context: context))
            }
        }

        // `--flight-keys <dir>`: the frame at every key of the flight as a PNG, each at its own
        // exposure, and no video; `--flight-at <s,...>` draws those seconds instead of the keys.
        if let directory = option("flight-keys"), let planned {
            let moments = try option("flight-at").map { text in
                try text.split(separator: ",").map { part in
                    guard let seconds = Double(part), seconds >= 0 else {
                        throw SceneFolder.ExportError.badValue("flight-at", text)
                    }
                    return seconds
                }
            }
            let out = URL(fileURLWithPath: directory, isDirectory: true)
            try manager.createDirectory(at: out, withIntermediateDirectories: true)
            let started = Date()
            let drawn = try drawing()
            var report = Report(out: out)
            for (index, seconds) in (moments ?? planned.flight.keySeconds).enumerated() {
                let at = min(max(seconds, 0), planned.flight.seconds)
                let began = Date()
                let pixels = try drawn.flightStill(
                    atSeconds: at, frame: Int((at * Double(fps)).rounded()), format: .rgb, threads: threads)
                let url = out.appendingPathComponent(String(format: "key-%02d-%06.2fs.png", index, at))
                try PNG.write(
                    PNG.Image(width: width, height: height, channels: 3, bytes: [UInt8](pixels)), to: url)
                say(
                    String(format: "key        %@  %.0f ms", url.path, Date().timeIntervalSince(began) * 1000)
                )
                report.keys.append(url)
            }
            if let inside = drawn.flightFrames?.report {
                report.inside = inside
                say("inside     \(inside.summary)")
            }
            report.seconds = Date().timeIntervalSince(started)
            say(
                String(
                    format: "flight     keys drawn in %.1f s on %@ (%@)", report.seconds, engine, context.name
                ))
            return report
        }

        let asked = try value("bitrate").map { Int($0 * 1e6) }
        if !codec.hasRateControl, asked != nil { throw SceneFolder.ExportError.noRateControl(codec) }
        let out =
            option("out").map { URL(fileURLWithPath: $0) }
            ?? folder.export(
                preset: flightName.map { "\($0)-\(preset.name)" } ?? preset.name,
                codec: codec == preset.defaultCodec ? nil : codec)
        try manager.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)

        let start = try value("start") ?? 0
        let duration = try value("duration")
        let frames =
            planned?.videoFrames(framesPerSecond: fps, start: start, duration: duration)
            ?? plain?.videoFrames(framesPerSecond: fps, start: start, duration: duration) ?? []
        let videoSeconds = planned?.flight.seconds ?? plain?.videoSeconds ?? 0
        let showing = planned != nil ? "flight" : speed != nil ? "video" : "take"
        guard !frames.isEmpty else {
            throw Failure.usage("no frame to draw from \(start) s of the \(showing)")
        }
        var bitRate = asked
        if bitRate == nil { bitRate = try preset.bitRate(forSeconds: Double(frames.count) / Double(fps)) }
        let rate = bitRate ?? codec.defaultBitRate(width: width, height: height)
        let steering =
            rate.map {
                String(
                    format: "%.1f Mbit/s, about %.0f MB", Double($0) / 1e6,
                    Double($0) * Double(frames.count) / Double(fps) / 8e6)
            } ?? "ProRes 422 HQ"
        // A second of video a segment: what a run that stops draws again at most.
        let segmentFrames = try whole("segment-frames") ?? fps
        let segmentCount = (frames.count + segmentFrames - 1) / segmentFrames
        var part: (index: Int, of: Int)?
        if let text = option("part") {
            let numbers = text.split(separator: "/").compactMap { Int($0) }
            guard numbers.count == 2, numbers[1] >= 1, (1...numbers[1]).contains(numbers[0]) else {
                throw SceneFolder.ExportError.badValue("part", text)
            }
            part = (numbers[0], numbers[1])
        }
        say(
            String(
                format: "export     %@ %@ %dx%d at %d fps, %d frames (%.1f s from %.1f s of a %.1f s %@),"
                    + " look %@, %@, %d segments of %d frames%@, on %@ (%@)",
                preset.name, codec.rawValue, width, height, fps, frames.count,
                Double(frames.count) / Double(fps), start, videoSeconds, showing, look.name, steering,
                segmentCount, segmentFrames, part.map { ", part \($0.index) of \($0.of)" } ?? "", engine,
                context.name))
        if let speed {
            let megayears = TimeTrack.megayears(of: loaded.recording)
            func myr(_ position: Double) -> Double {
                let index = min(max(Int(position), 0), megayears.count - 1)
                let next = min(index + 1, megayears.count - 1)
                return megayears[index] + (megayears[next] - megayears[index]) * (position - Double(index))
            }
            say(
                String(
                    format: "speed      %@: %.1f s of video for %.1f to %.1f Myr of the take", speed.name,
                    Double(frames.count) / Double(fps), myr(frames.first?.captured ?? 0),
                    myr(frames.last?.captured ?? 0)))
        }

        func size(_ url: URL?) -> Int? {
            url.flatMap { (try? manager.attributesOfItem(atPath: $0.path)[.size] as? Int) ?? nil }
        }
        func modified(_ url: URL) -> Date? {
            (try? manager.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? nil
        }
        let identity = Identity(
            take: takeURL.lastPathComponent, takeBytes: size(takeURL) ?? 0,
            particles: loaded.recording.particleCount, capturedFrames: loaded.recording.capturedFrames,
            framing: framingURL?.lastPathComponent, framingBytes: size(framingURL),
            look: digest(try look.encoded()), flight: try flightFile.map { digest(try $0.encoded()) },
            track: try speed.map { digest(try $0.file.encoded()) }, capturedRate: capturedRate, width: width,
            height: height, framesPerSecond: fps, start: start,
            duration: duration, frames: frames.count, segmentFrames: segmentFrames, codec: codec.rawValue,
            bitsPerSecond: bitRate, laceTexels: laceTexels,
            engine: CUDAContext.target == .gpu ? "cuda gpu" : "cuda cpu")

        // The segments so far are kept by --resume and --part; any other run starts again.
        let work = segments(of: out)
        let planURL = work.appendingPathComponent("plan.json")
        let keeps = flag("resume") || part != nil
        if manager.fileExists(atPath: work.path) {
            let held = (try? Data(contentsOf: planURL)).flatMap {
                try? JSONDecoder().decode(Plan.self, from: $0)
            }
            if !keeps {
                try manager.removeItem(at: work)
            } else if let held, held.identity != identity {
                throw Failure.otherExport(folder: work, differs: held.identity.differences(from: identity))
            }
        } else if keeps, let made = modified(out) {
            // The line that draws a video runs again when its box restarts: a video that is
            // whole, and no older than what it is drawn from, is left as it is.
            let lookURL = option("look").flatMap { $0.hasSuffix(".json") ? URL(fileURLWithPath: $0) : nil }
            let trackURL = option("speed").flatMap {
                Double($0) == nil && PaceSpec($0) == nil ? URL(fileURLWithPath: $0) : nil
            }
            let sources = [takeURL, flightURL, framingURL, trackURL, lookURL ?? folder.look].compactMap { $0 }
            if sources.allSatisfy({ (modified($0) ?? .distantPast) <= made }) {
                say(
                    "export     \(out.path) is whole and no older than what it is drawn from:"
                        + " nothing to draw (without --resume it is drawn again)")
                var report = Report(out: out, frames: frames.count, segments: segmentCount)
                report.segmentsDone = segmentCount
                report.joined = true
                return report
            }
        }
        try manager.createDirectory(at: work, withIntermediateDirectories: true)

        let reporter = inFolder ? StageReporter(stage: "export", folder: folder) : nil
        reporter?.start(detail: "frame 0/\(frames.count)")
        defer { reporter?.finish() }
        let started = Date()

        // The exposure of the whole video, measured once: the first run to finish it writes
        // it, and every run draws under what is written.
        if !manager.fileExists(atPath: planURL.path) {
            let began = Date()
            let drawn = try drawing()
            var tenth = 0
            drawn.phases = measuring
            defer { drawn.phases = phases }
            let measured: (exposure: FlightFrames.Exposure, clip: ClipExposure?)
            if let flightFrames = drawn.flightFrames {
                measured = try guarded(context) {
                    try flightFrames.measure(on: drawn) { done, total in
                        reporter?.update(progress: 0, detail: "exposure \(done)/\(total)")
                        if done * 10 / max(total, 1) > tenth {
                            tenth = done * 10 / max(total, 1)
                            say("exposure   \(done)/\(total) moments")
                        }
                    }
                }
            } else if let plain {
                let clip = try guarded(context) { try plain.measureScale(on: drawn, frames: frames) }
                measured = (FlightFrames.Exposure(scale: clip?.scale, target: 0), clip)
            } else {
                throw Failure.usage("nothing to draw")
            }
            let seconds = Date().timeIntervalSince(began)
            var summary =
                measured.clip.map { "\($0.summary); " } ?? (look.exposure == nil ? "the look's own; " : "")
            if let trims = measured.exposure.trims {
                summary += String(
                    format: "held under a mean of %.3f, trimmed by up to %.1f stops over %d moments",
                    measured.exposure.target, trims.deepest, trims.stops.count)
            } else {
                summary += "no automatic exposure"
            }
            let plan = Plan(
                identity: identity, exposure: measured.exposure, summary: summary, seconds: seconds,
                device: context.name)
            let scratch = work.appendingPathComponent(
                "plan-\(ProcessInfo.processInfo.processIdentifier).json")
            try encoded(plan).write(to: scratch)
            // A link fails when the plan is there: another part wrote it first, and its is kept.
            _ = link(scratch.path, planURL.path)
            try? manager.removeItem(at: scratch)
            say(String(format: "exposure   %@, measured in %.1f s", summary, seconds))
            if let measuring {
                say(String(format: "profile    the exposure of the %@, %.1f s", showing, seconds))
                for line in measuring.lines(total: seconds) { say("profile      \(line)") }
            }
        }
        let planData = try Data(contentsOf: planURL)
        let plan = try JSONDecoder().decode(Plan.self, from: planData)
        guard plan.identity == identity else {
            throw Failure.otherExport(folder: work, differs: plan.identity.differences(from: identity))
        }
        let planDigest = digest(planData)
        let exposure = plan.exposure

        func video(_ index: Int) -> URL {
            work.appendingPathComponent(String(format: "segment-%05d.%@", index, codec.fileExtension))
        }
        func record(_ index: Int) -> URL {
            work.appendingPathComponent(String(format: "segment-%05d.json", index))
        }
        func done(_ index: Int) -> Segment? {
            guard manager.fileExists(atPath: video(index).path),
                let segment = (try? Data(contentsOf: record(index))).flatMap({
                    try? JSONDecoder().decode(Segment.self, from: $0)
                }), segment.plan == planDigest
            else { return nil }
            return segment
        }

        let stillsDirectory = option("stills").map { URL(fileURLWithPath: $0, isDirectory: true) }
        let stillFrames = Set(option("still-frames")?.split(separator: ",").compactMap { Int($0) } ?? [])
        if let stillsDirectory {
            try manager.createDirectory(at: stillsDirectory, withIntermediateDirectories: true)
        }

        var report = Report(out: out, frames: frames.count, segments: segmentCount, exposure: exposure)
        let interval = 1 / Double(max(fps, 1))
        let metadata = inFolder ? VideoMetadata(sceneID: folder.sceneID) : nil
        var stopped = false
        var segmentsDrawn = 0
        var spent = 0.0
        for index in 0..<segmentCount where !stopped {
            if let part, index % part.of != part.index - 1 { continue }
            if done(index) != nil { continue }
            let range = (index * segmentFrames)..<min((index + 1) * segmentFrames, frames.count)
            let began = Date()
            let drawn = try drawing()
            let flightFrames = drawn.flightFrames
            flightFrames?.resetReport()
            if range.lowerBound > 0 { flightFrames?.follow(frames[range.lowerBound - 1]) }
            // A file of this run's own: a run killed here may have left an encoder closing its.
            let partial = work.appendingPathComponent(
                String(
                    format: "drawing-%05d-%d.%@", index, ProcessInfo.processInfo.processIdentifier,
                    codec.fileExtension))
            try? manager.removeItem(at: partial)
            let writer = try FFmpegVideoWriter(
                url: partial, width: width, height: height, framesPerSecond: fps, codec: codec,
                bitsPerSecond: bitRate, metadata: metadata)
            var hash = PortableSHA256()
            for frame in range {
                let pixels = try guarded(context) {
                    if let plain {
                        return try drawn.takeFrame(
                            frames[frame], of: plain, index: frame, exposure: exposure.scale)
                    }
                    return try drawn.flightFrame(
                        frames[frame], index: frame, interval: interval, exposure: exposure)
                }
                hash.update(bytes: pixels)
                if let phases {
                    try phases.time("encode", on: nil) { try writer.append(pixels) }
                } else {
                    try writer.append(pixels)
                }
                if let stillsDirectory, stillFrames.contains(frame) {
                    try PNG.write(
                        PNG.Image(width: width, height: height, channels: 3, bytes: [UInt8](pixels)),
                        to: stillsDirectory.appendingPathComponent(
                            String(format: "%@-%04d.png", preset.name, frame)))
                }
                report.drawn += 1
                reporter?.update(
                    progress: Double(frame + 1) / Double(frames.count),
                    detail: "frame \(frame + 1)/\(frames.count)")
            }
            try writer.finish()
            try? manager.removeItem(at: video(index))
            try manager.moveItem(at: partial, to: video(index))
            let seconds = Date().timeIntervalSince(began)
            let segment = Segment(
                index: index, first: range.lowerBound, frames: range.count, seconds: seconds,
                plan: planDigest,
                pixels: hash.finalize().prefix(16).map { String(format: "%02x", $0) }.joined(),
                report: flightFrames?.report ?? FlightFrames.Report(), device: context.name)
            try encoded(segment).write(to: record(index), options: .atomic)
            say(
                String(
                    format: "segment    %d/%d, frames %d to %d in %.1f s, %.2f s a frame%@", index + 1,
                    segmentCount, range.lowerBound, range.upperBound - 1, seconds,
                    seconds / Double(range.count),
                    drawn.lastFlightFrame.map {
                        String(
                            format: "; the last %.3f kpc from matter, %d renders, %d point stars",
                            $0.nearness,
                            $0.renders, $0.stars)
                    } ?? ""))
            if segmentsDrawn == 0, let held = context.freeMemory {
                let peak = context.memoryHeld.peak
                say(
                    String(
                        format: "memory     %.1f GB held on the device at most, %.1f GB free of %.1f GB:"
                            + " %d more of this export fit beside it",
                        Double(peak) / 1e9, Double(held.free) / 1e9, Double(held.total) / 1e9,
                        peak > 0 ? held.free / peak : 0))
            }
            segmentsDrawn += 1
            spent += seconds
            if stop?(segmentsDrawn) == true { stopped = true }
        }
        report.seconds = Date().timeIntervalSince(started)

        var total = 0.0
        var whole: [Segment] = []
        for index in 0..<segmentCount {
            guard let segment = done(index) else { continue }
            whole.append(segment)
            report.inside.merge(segment.report)
            report.pixels.append(segment.pixels)
            total += segment.seconds
        }
        report.segmentsDone = whole.count
        if let phases, segmentsDrawn > 0 {
            say(String(format: "profile    %d frames, %.1f s", report.drawn, spent))
            for line in phases.lines(total: spent) { say("profile      \(line)") }
        }
        guard whole.count == segmentCount, !stopped else {
            say(
                "export     \(whole.count) of \(segmentCount) segments drawn in \(work.path):"
                    + " --resume draws the rest and joins them")
            return report
        }
        // One run joins: of several parts ending together, the first to take the lock.
        let lock = work.appendingPathComponent("joining")
        if part != nil, mkdir(lock.path, 0o755) != 0 {
            say("export     every segment is drawn: another part joins them")
            return report
        }
        let joined = out.deletingLastPathComponent().appendingPathComponent(
            ".joining-\(ProcessInfo.processInfo.processIdentifier)-\(out.lastPathComponent)")
        defer { try? manager.removeItem(at: joined) }
        try FFmpegVideo.join(
            (0..<segmentCount).map(video), into: joined, frames: frames.count, framesPerSecond: fps,
            metadata: metadata)
        guard rename(joined.path, out.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try? manager.removeItem(at: work)
        report.joined = true
        let bytes = size(out) ?? 0
        say("exposure   \(plan.summary)")
        if planned != nil { say("inside     \(report.inside.summary)") }
        if let speed {
            let url = out.deletingPathExtension().appendingPathExtension(TimeTrackFile.fileExtension)
            try speed.file.encoded().write(to: url)
            say("track      \(url.path)")
        }
        say(
            String(
                format: "export     %d frames drawn in %.1f s, %.2f s a frame, %.1f MB", frames.count, total,
                total / Double(max(frames.count, 1)), Double(bytes) / 1e6))
        say("video      \(out.path)")
        return report
    }

    /// `--speed <x | file | story[:pace[:top]]>` (#305, #309): the whole take at one speed, a time
    /// track kept in a `.time.json`, or the speeds read off the scene's curves, a stretch of which
    /// `--slow <from>:<to>:<speed>` holds, as the Mac's `export --speed` has them. The visual pace
    /// draws the take small with Metal first: its track, written beside the Mac's video, is given
    /// as a file instead.
    static func timeTrack(
        _ text: String, slow: String?, folder: SceneFolder, take: RecordingFile.Loaded, capturedRate: Int
    ) throws -> (file: TimeTrackFile, track: TimeTrack, name: String) {
        let megayears = TimeTrack.megayears(of: take.recording)
        var file: TimeTrackFile
        var name = text
        if let spec = PaceSpec(text) {
            guard case .story = spec else {
                throw SceneFolder.ExportError.badValue(
                    "speed",
                    "the visual pace draws the take with Metal: give the .time.json the Mac's export wrote")
            }
            var made = try PaceTrack.fromCurves(spec, folder: folder, scene: take.scene, megayears: megayears)
                .made
            if let slow {
                let parts = slow.split(separator: ":").compactMap { Double($0) }
                guard parts.count == 3, parts[2] > 0 else {
                    throw SceneFolder.ExportError.badValue("slow", slow)
                }
                made.speeds = PaceSpec.slowed(
                    made.speeds, megayears: megayears, from: parts[0], to: parts[1], speed: parts[2])
                name += " slowed \(slow)"
            }
            file = TimeTrackFile(speeds: made.speeds)
        } else if slow != nil {
            throw SceneFolder.ExportError.badValue("slow", "it goes with --speed story")
        } else if let speed = Double(text) {
            file = TimeTrackFile(speed: speed)
            name = String(format: "%gx", speed)
        } else {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: text)) else {
                throw SceneFolder.ExportError.badValue("speed", text)
            }
            file = try TimeTrackFile.decoded(from: data)
            name = URL(fileURLWithPath: text).lastPathComponent
        }
        return (file, try file.track(megayears: megayears, capturedRate: capturedRate), name)
    }

    /// A line of the log as it comes, even into a file: a long export started detached is
    /// followed there.
    private static func say(_ line: String) {
        print(line)
        fflush(nil)
    }

    /// Runs `work`, and says what a device out of memory means for an export.
    private static func guarded<T>(_ context: CUDAContext, _ work: () throws -> T) throws -> T {
        do {
            return try work()
        } catch let error as CUDAError where error.code == .outOfMemory {
            throw Failure.outOfMemory(memoryAdvice(error, context: context))
        }
    }

    private static func memoryAdvice(_ error: CUDAError, context: CUDAContext) -> String {
        var text = "\(error)"
        if let memory = context.freeMemory {
            text += String(
                format: ": %.1f GB free of the device's %.1f GB, %.1f GB held here",
                Double(memory.free) / 1e9,
                Double(memory.total) / 1e9, Double(context.memoryHeld.now) / 1e9)
        }
        return text
            + ". An export wants a device to itself: several on one GPU slow one another and run out of"
            + " its memory. The segments drawn are kept: --resume goes on from them, and --part k/n with"
            + " --device draws on several GPUs"
    }
}
