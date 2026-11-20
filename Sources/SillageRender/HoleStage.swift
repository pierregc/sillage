import Foundation
import Metal
import SillageCore

extension HoleLookFile {
    /// What the renderer draws with.
    public var renderLook: HoleLook {
        var look = HoleLook()
        look.lensed = lensed
        look.images = images
        look.temperature = temperature == .radius ? .radius : .crossing
        look.hottest = Float(hottest)
        look.beaming = Float(beaming)
        look.exposure = Float(exposure)
        look.ambient = Float(ambient)
        look.particleSize = Float(particleSize)
        look.stars = stars
        look.starBrightness = Float(starBrightness)
        return look
    }

    /// The post stages at a size: `HoleLook.settings`, with the look's tone where it gives one.
    public func settings(width: Int, height: Int) -> RenderSettings {
        var settings = HoleLook.settings(width: width, height: height)
        if let stretch { settings.stretch = Float(stretch) }
        if let bloom { settings.bloomIntensity = Float(bloom) }
        if let whitePoint { settings.whitePoint = Float(whitePoint) }
        if let saturation { settings.saturation = Float(saturation) }
        return settings
    }
}

/// A black hole close up through the stages of a scene folder (#332): `hires` runs it into
/// `take.sillage`, `export` draws the take into `exports/`, as for galaxies, and the queue and
/// a night call them alike.
public enum HoleStage {
    /// Runs the folder's scene from the release to its end, keeping a frame every
    /// `frameInterval` in the take. Written beside it until whole.
    @discardableResult
    public static func run(
        _ folder: SceneFolder, device: MTLDevice? = nil, reporter: StageReporter? = nil,
        gas: GasGrid = GasGrid(), metrics: Metrics? = nil, say: (String) -> Void = { print($0) }
    ) throws -> HoleTakeFile.Header {
        let file = try folder.holeScene()
        let scene = file.blackHole
        let started = Date()
        let run = try TidalRun(scene: scene, gas: gas, device: device)
        let rows = try metrics.map { try MetricsWriter(run: run, metrics: $0, say: say) }
        let (total, kept) = HoleTakeFile.Header.planned(scene, releaseTime: run.releaseTime)
        let header = HoleTakeFile.Header(
            scene: file, tracers: scene.tracers, releaseTime: run.releaseTime, steps: kept)
        say(
            String(
                format: "hires      black hole, %d tracers, released at t = %.1f, %d steps to t = %.0f,"
                    + " %d frames kept", scene.tracers, run.releaseTime, total, header.time(step: total),
                kept.count))
        reporter?.start(detail: "step 0/\(total)")
        let partial = SceneFolder.partial(folder.take)
        let writer = try HoleTakeFile.Writer(header: header, to: partial)
        for step in kept {
            // Steps in pieces of a few hundred, so the progress moves and no command buffer runs long.
            while run.stepsTaken < step {
                let next = min(step - run.stepsTaken, 400)
                run.step(rows.map { min(next, $0.stepsToNextRow(run.stepsTaken)) } ?? next)
                try rows?.record(run)
                reporter?.update(
                    progress: Double(run.stepsTaken) / Double(max(total, 1)),
                    detail: "step \(run.stepsTaken)/\(total)")
            }
            let frame = run.frame
            try writer.append(frame)
            let left = frame.velocities.reduce(0) { $0 + ($1.w >= 0 ? 1 : 0) }
            say(
                String(
                    format: "frame      %d at t = %.1f, %d tracers left", writer.written - 1, frame.time, left
                ))
        }
        try writer.finish()
        try SceneFolder.commit(folder.take)
        var done = RunEvent(RunEvent.Kind.hiresDone)
        done.subject = SceneKind.blackHole.rawValue
        done.particles = scene.tracers
        done.steps = total
        done.seconds = Date().timeIntervalSince(started)
        done.path = folder.take.path
        reporter?.record(done)
        say(String(format: "take       %@, %.1f s", folder.take.path, Date().timeIntervalSince(started)))
        return header
    }

    /// A row of `TidalMeasure` every `interval` time units into a CSV, beside the take (#334).
    public struct Metrics {
        public var url: URL
        public var interval: Float

        public init(url: URL, interval: Float = 25) {
            self.url = url
            self.interval = interval
        }
    }

    final class MetricsWriter {
        let measure: TidalMeasure
        let file: FileHandle
        let every: Int

        init(run: TidalRun, metrics: Metrics, say: (String) -> Void) throws {
            FileManager.default.createFile(atPath: metrics.url.path, contents: nil)
            file = try FileHandle(forWritingTo: metrics.url)
            measure = run.measure()
            every = max(Int((metrics.interval / run.scene.timeStep).rounded()), 1)
            say(
                String(
                    format: "metrics    P* %.0f, circular radius %.2f, of the bound's mean momentum %.2f",
                    measure.period, measure.circularRadius, measure.boundRing))
            try file.write(contentsOf: Data((TidalMeasure.Row.header + "\n").utf8))
            try record(run)
        }

        func stepsToNextRow(_ taken: Int) -> Int { every - taken % every }

        func record(_ run: TidalRun) throws {
            guard run.stepsTaken % every == 0 else { return }
            try file.write(contentsOf: Data((run.row(measure).line + "\n").utf8))
        }
    }

    /// The run of a take, ready to go on from any of its moments, and the frame it holds.
    public final class Replay {
        public let take: HoleTakeFile.Loaded
        public let run: TidalRun
        public private(set) var frame: TidalFrame

        public init(take: HoleTakeFile.Loaded, device: MTLDevice? = nil) throws {
            self.take = take
            run = try TidalRun(scene: take.header.scene.blackHole, device: device)
            guard run.releaseTime == take.header.releaseTime else {
                throw HoleTakeFile.Failure.wrongFrame("the scene releases at another time than the take's")
            }
            frame = take.frame(0)
            run.resume(from: frame, step: 0)
        }

        /// Steps on to `step`, from the frame the take kept before it when that is nearer or
        /// `step` lies behind; the frame there, as the run had it.
        @discardableResult
        public func seek(_ step: Int) -> TidalFrame {
            let index = take.frameIndex(before: step)
            let kept = take.header.steps[index]
            if step < run.stepsTaken || kept > run.stepsTaken {
                frame = take.frame(index)
                run.resume(from: frame, step: kept)
            }
            if step > run.stepsTaken {
                run.step(step - run.stepsTaken)
                frame = run.frame
            }
            return frame
        }

        public func step(at time: Double) -> Int {
            let header = take.header
            return min(
                max(Int(((time - header.releaseTime) / header.timeStep).rounded()), 0), header.steps.last ?? 0
            )
        }
    }

    public struct ExportReport {
        public var url: URL
        public var frames: Int
        public var seconds: Double
        public var bytes: Int
    }

    /// Draws the folder's take with its look, or the one asked, into `exports/<preset>.mp4`, or
    /// `<look>-<preset>` for a look other than the scene's.
    public static func export(
        _ folder: SceneFolder, options: HoleExportOptions, device: MTLDevice? = nil,
        reporter: StageReporter? = nil, say: (String) -> Void = { print($0) }
    ) throws -> ExportReport {
        guard HoleTakeFile.isHoleTake(folder.take) else { throw SceneFolder.HoleError.noTake(folder.url) }
        let take = try HoleTakeFile.Loaded(contentsOf: folder.take)
        let lookFile = try folder.holeLook(options.look)
        let look = lookFile.renderLook
        let codec = options.codec ?? options.preset.defaultCodec
        let width = (options.width ?? options.preset.width) / 2 * 2
        let height = (options.height ?? options.preset.height) / 2 * 2
        let plan = try HolePlan(
            header: take.header, from: options.from, to: options.to, seconds: options.seconds,
            framesPerSecond: options.framesPerSecond)
        let name = options.look == nil ? options.preset.name : "\(lookFile.name)-\(options.preset.name)"
        let out =
            options.out
            ?? folder.export(preset: name, codec: codec == options.preset.defaultCodec ? nil : codec)
        try FileManager.default.createDirectory(
            at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let stills = options.stills {
            try FileManager.default.createDirectory(at: stills, withIntermediateDirectories: true)
        }
        let started = Date()
        let replay = try Replay(take: take, device: device)
        let renderer = try HoleRenderer(
            settings: lookFile.settings(width: width, height: height), device: replay.run.device)
        if let at = lookFile.exposureAt {
            renderer.fixedExposure = true
            renderer.upload(replay.seek(replay.step(at: at)))
        } else {
            renderer.exposureEasing = 0.9
        }
        let seconds = Double(plan.frames) / Double(plan.framesPerSecond)
        let bitRate =
            try options.preset.bitRate(forSeconds: seconds)
            ?? codec.defaultBitRate(width: width, height: height)
        say(
            String(
                format: "export     black hole %@ %@ %dx%d at %d fps, %d frames, t %.0f to %.0f, look %@",
                options.preset.name, codec.rawValue, width, height, plan.framesPerSecond, plan.frames,
                take.header.time(step: plan.steps.first ?? 0), take.header.time(step: plan.steps.last ?? 0),
                lookFile.name))
        reporter?.start(detail: "frame 0/\(plan.frames)")
        let partial = SceneFolder.partial(out)
        let writer = try VideoWriter(
            width: width, height: height, framesPerSecond: Int32(plan.framesPerSecond), codec: codec,
            bitsPerSecond: bitRate, metadata: VideoMetadata(sceneID: folder.sceneID), to: partial)
        for (index, step) in plan.steps.enumerated() {
            let frame = replay.seek(step)
            renderer.upload(frame)
            let camera = lookFile.camera.camera(progress: plan.progress(index))
            if let stills = options.stills, index % max(plan.frames / 8, 1) == 0 {
                let pixels = renderer.render(frame, camera: camera, look: look)
                try PNGWriter.write(
                    pixels, width: width, height: height,
                    to: stills.appendingPathComponent(String(format: "%@-%04d.png", name, index)))
            }
            try writer.append(on: replay.run.device) { target, buffer in
                _ = renderer.render(frame, camera: camera, look: look, present: target, into: buffer)
            }
            reporter?.update(
                progress: Double(index + 1) / Double(plan.frames), detail: "frame \(index + 1)/\(plan.frames)"
            )
        }
        try writer.finish()
        try SceneFolder.commit(out)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
        let took = Date().timeIntervalSince(started)
        var done = RunEvent(RunEvent.Kind.exportDone)
        done.subject = SceneKind.blackHole.rawValue
        done.preset = options.preset.name
        done.style = lookFile.name
        done.codec = codec.rawValue
        done.frames = plan.frames
        done.megabytes = Double(bytes) / 1e6
        done.seconds = took
        done.path = out.path
        reporter?.record(done)
        say(String(format: "export     %d frames in %.1f s, %.1f MB", plan.frames, took, Double(bytes) / 1e6))
        say("video      \(out.path)")
        return ExportReport(url: out, frames: plan.frames, seconds: took, bytes: bytes)
    }
}
