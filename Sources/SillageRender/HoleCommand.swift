import Foundation
import Metal
import SillageCore
import simd

/// `sillage-render black-hole`, the spike of #314 (docs/notes/black-hole-close-up.md):
///
///     black-hole run <folder> [scene options] [--video <file> --elevation <deg> --distance <r>]
///     black-hole still <frame> <png> [view options]
///     black-hole orbit <frame> <video> [view options] [--seconds 10] [--turns 1] [--scene <json>]
///
/// `run` writes the scene, then a take: a frame every `--frame-interval` under `frames/`.
/// `orbit` goes round the frame's disk, at its elevation and distance, frozen, or with
/// `--scene` stepping the run on from the frame, one step a video frame.
public enum HoleCommand {
    public static func main(_ arguments: [String]) -> Int32 {
        guard let verb = arguments.first else { return usage() }
        let options = Options(Array(arguments.dropFirst()))
        do {
            switch verb {
            case "run": try run(options)
            case "still": try still(options)
            case "orbit": try orbit(options)
            default: return usage()
            }
        } catch {
            FileHandle.standardError.write(Data("black-hole: \(error)\n".utf8))
            return 1
        }
        return 0
    }

    static func usage() -> Int32 {
        FileHandle.standardError.write(
            Data(
                """
                usage: sillage-render black-hole run <folder> [--tracers N] [--pericentre r] [--cloud r]
                           [--release r] [--stickiness x] [--viscous-orbits x] [--cooling-time t]
                           [--duration t] [--frame-interval t] [--step t] [--seed n]
                           [--video file --elevation deg --distance r --azimuth deg --reference frame]
                       sillage-render black-hole still <frame> <png> [view options]
                       sillage-render black-hole orbit <frame> <video> [view options] [--seconds s]
                           [--turns n] [--scene scene.json]
                view options: --elevation deg --azimuth deg --distance r --fov deg --width w
                       --height h --straight --images n --temperature radius|crossing --hottest K
                       --beaming x --exposure x --ambient x --stars n --size r --stretch x
                       --bloom x --white x --reference frame

                """.utf8))
        return 2
    }

    struct Options {
        var words: [String] = []
        var values: [String: String] = [:]
        var flags: Set<String> = []

        init(_ arguments: [String]) {
            var index = 0
            while index < arguments.count {
                let word = arguments[index]
                if word.hasPrefix("--") {
                    let name = String(word.dropFirst(2))
                    if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                        values[name] = arguments[index + 1]
                        index += 2
                        continue
                    }
                    flags.insert(name)
                } else {
                    words.append(word)
                }
                index += 1
            }
        }

        func float(_ name: String) -> Float? { values[name].flatMap(Float.init) }
        func int(_ name: String) -> Int? { values[name].flatMap(Int.init) }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func scene(_ options: Options, base: TidalDisruption = TidalDisruption()) -> TidalDisruption {
        var scene = base
        if let value = options.int("tracers") { scene.tracers = value }
        if let value = options.int("seed") { scene.seed = UInt64(value) }
        if let value = options.float("pericentre") { scene.pericentre = value }
        if let value = options.float("cloud") { scene.cloudRadius = value }
        if let value = options.float("release") { scene.release = value }
        if let value = options.float("stickiness") { scene.stickiness = value }
        if let value = options.float("crossing-speed") { scene.crossingSpeed = value }
        if let value = options.float("viscous-orbits") { scene.viscousOrbits = value }
        if let value = options.float("cooling-time") { scene.coolingTime = value }
        if let value = options.float("swallow") { scene.swallow = value }
        if let value = options.float("step") { scene.timeStep = value }
        if let value = options.float("duration") { scene.duration = value }
        if let value = options.float("frame-interval") { scene.frameInterval = value }
        return scene
    }

    static func look(_ options: Options) -> HoleLook {
        var look = HoleLook()
        if options.flags.contains("straight") { look.lensed = false }
        if let value = options.int("images") { look.images = value }
        if let value = options.values["temperature"].flatMap(HoleLook.Temperature.init) {
            look.temperature = value
        }
        if let value = options.float("hottest") { look.hottest = value }
        if let value = options.float("beaming") { look.beaming = value }
        if let value = options.float("exposure") { look.exposure = value }
        if let value = options.float("size") { look.particleSize = value }
        if let value = options.float("ambient") { look.ambient = value }
        if let value = options.int("stars") { look.stars = value }
        if let value = options.float("star-brightness") { look.starBrightness = value }
        return look
    }

    static func settings(_ options: Options) -> RenderSettings {
        var settings = HoleLook.settings(
            width: options.int("width") ?? 1920, height: options.int("height") ?? 1080)
        if let value = options.float("stretch") { settings.stretch = value }
        if let value = options.float("bloom") { settings.bloomIntensity = value }
        if let value = options.float("white") { settings.whitePoint = value }
        if let value = options.float("saturation") { settings.saturation = value }
        return settings
    }

    /// The camera at `elevation` above the disk's plane and `azimuth` round it, `distance`
    /// from the hole, looking at it.
    static func camera(_ options: Options, azimuthOffset: Float = 0) -> Camera {
        let elevation = (options.float("elevation") ?? 20) * .pi / 180
        let azimuth = (options.float("azimuth") ?? 0) * .pi / 180 + azimuthOffset
        let distance = options.float("distance") ?? 40
        let eye =
            SIMD3<Float>(cos(elevation) * sin(azimuth), -cos(elevation) * cos(azimuth), sin(elevation))
            * distance
        return Camera(
            eye: eye, target: .zero, up: SIMD3<Float>(0, 0, 1),
            fieldOfView: (options.float("fov") ?? 40) * .pi / 180, near: 0.1, far: 100_000)
    }

    /// `--reference <frame>` sets the exposure and the temperatures from that frame and keeps
    /// them, so that a video's light rises and falls with the run's instead of being made even.
    static func fixExposure(_ renderer: HoleRenderer, _ options: Options) throws {
        guard let path = options.values["reference"] else { return }
        renderer.fixedExposure = true
        renderer.upload(try TidalFrame(contentsOf: URL(fileURLWithPath: path)))
    }

    static func run(_ options: Options) throws {
        guard let path = options.words.first else { throw Failure(description: "run needs a folder") }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let frames = folder.appendingPathComponent("frames", isDirectory: true)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        let scene = scene(options)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(scene).write(to: folder.appendingPathComponent("scene.json"))

        let started = Date()
        let run = try TidalRun(scene: scene)
        print(String(format: "released at t = %.1f, %d tracers", run.releaseTime, scene.tracers))
        var video: (writer: VideoWriter, renderer: HoleRenderer, look: HoleLook, every: Int)?
        if let file = options.values["video"] {
            let settings = settings(options)
            let renderer = try HoleRenderer(settings: settings, device: run.device)
            renderer.exposureEasing = 0.9
            try fixExposure(renderer, options)
            let writer = try VideoWriter(
                width: settings.width, height: settings.height, framesPerSecond: 30, codec: .h264,
                quality: 0.8, to: URL(fileURLWithPath: file))
            let every = max(Int(((options.float("video-interval") ?? 2) / scene.timeStep).rounded()), 1)
            video = (writer, renderer, look(options), every)
        }
        let camera = camera(options)
        let stepsPerFrame = max(Int((scene.frameInterval / scene.timeStep).rounded()), 1)
        let totalSteps = Int(((Double(scene.duration) - run.releaseTime) / Double(scene.timeStep)).rounded())
        var done = 0
        var kept = 0
        var stepping = 0.0
        func keep() throws {
            let frame = run.frame
            try frame.write(to: frames.appendingPathComponent(String(format: "frame-%04d.bin", kept)))
            let alive = frame.velocities.filter { $0.w >= 0 }.count
            print(
                String(
                    format: "frame %d at t = %.1f: %d tracers left, %.1f s of steps", kept, frame.time,
                    alive, stepping))
            kept += 1
        }
        try keep()
        while done < totalSteps {
            let chunk = min(
                video?.every ?? stepsPerFrame, stepsPerFrame - done % stepsPerFrame, totalSteps - done)
            let before = Date()
            run.step(chunk)
            stepping += Date().timeIntervalSince(before)
            done += chunk
            if let video {
                let frame = run.frame
                video.renderer.upload(frame)
                try video.writer.append(on: run.device) { target, buffer in
                    _ = video.renderer.render(
                        frame, camera: camera, look: video.look, present: target, into: buffer)
                }
            }
            if done % stepsPerFrame == 0 { try keep() }
        }
        try video?.writer.finish()
        print(
            String(
                format: "%d steps in %.1f s, %.1f s stepping", done, Date().timeIntervalSince(started),
                stepping))
    }

    static func still(_ options: Options) throws {
        guard options.words.count == 2 else { throw Failure(description: "still needs a frame and a png") }
        let frame = try TidalFrame(contentsOf: URL(fileURLWithPath: options.words[0]))
        let renderer = try HoleRenderer(settings: settings(options))
        renderer.upload(frame)
        let started = Date()
        let pixels = renderer.render(frame, camera: camera(options), look: look(options))
        try PNGWriter.write(
            pixels, width: renderer.settings.width, height: renderer.settings.height,
            to: URL(fileURLWithPath: options.words[1]))
        print(
            String(
                format: "t = %.1f, %.1f ms on the GPU, %.2f s in all", frame.time,
                renderer.lastGPUTime * 1000,
                Date().timeIntervalSince(started)))
    }

    static func orbit(_ options: Options) throws {
        guard options.words.count == 2 else { throw Failure(description: "orbit needs a frame and a video") }
        var frame = try TidalFrame(contentsOf: URL(fileURLWithPath: options.words[0]))
        let settings = settings(options)
        let renderer = try HoleRenderer(settings: settings)
        let seconds = options.float("seconds") ?? 10
        let fps = options.int("fps") ?? 30
        let turns = options.float("turns") ?? 1
        let count = Int(seconds * Float(fps))
        var run: TidalRun?
        if let path = options.values["scene"] {
            let scene = try JSONDecoder().decode(
                TidalDisruption.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            run = try TidalRun(scene: scene, frame: frame)
        }
        let writer = try VideoWriter(
            width: settings.width, height: settings.height, framesPerSecond: Int32(fps), codec: .h264,
            quality: 0.85, to: URL(fileURLWithPath: options.words[1]))
        let look = look(options)
        renderer.fixedExposure = true
        try fixExposure(renderer, options)
        renderer.upload(frame)
        let started = Date()
        for index in 0..<count {
            if let run {
                run.step(options.int("steps-per-frame") ?? 1)
                frame = run.frame
                renderer.upload(frame)
            }
            let turn = Float(index) / Float(count) * turns * 2 * .pi
            let camera = camera(options, azimuthOffset: turn)
            try writer.append(on: renderer.renderer.device) { target, buffer in
                _ = renderer.render(frame, camera: camera, look: look, present: target, into: buffer)
            }
        }
        try writer.finish()
        print(String(format: "%d frames in %.1f s", count, Date().timeIntervalSince(started)))
    }
}

extension TidalRun {
    /// A run that goes on from a frame of a take, with the scene that made it.
    public convenience init(scene: TidalDisruption, frame: TidalFrame, device: MTLDevice? = nil) throws {
        try self.init(scene: scene, device: device)
        resume(from: frame)
    }
}
