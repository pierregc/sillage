import Foundation
import Metal
import SillageCore

/// `sillage-render black-hole`, a black hole close up (#314, #332, docs/notes/black-hole-close-up.md):
///
///     black-hole new <folder> [scene options]       a scene folder holding a close up
///     black-hole run <folder> [scene options]       the same, then its run, as `hires` does
///     black-hole still <folder> <png> [--at t] [--look name] [view options]
///     black-hole still <folder> <png> --flight name --second s [--at t] [--look name]
///
/// The scene folder then goes through `hires` and `export` as a galaxy scene's does, and the
/// queue runs them alike.
public enum HoleCommand {
    public static func main(_ arguments: [String]) -> Int32 {
        guard let verb = arguments.first else { return usage() }
        let options = Options(Array(arguments.dropFirst()))
        do {
            switch verb {
            case "new": try create(options)
            case "run":
                var gas = GasGrid()
                if let value = options.int("grid-heights") { gas.heights = value }
                if let value = options.float("height-cell") { gas.heightCell = value }
                let metrics = options.values["metrics"].map {
                    HoleStage.Metrics(
                        url: URL(fileURLWithPath: $0), interval: options.float("metrics-interval") ?? 25)
                }
                try HoleStage.run(try create(options), gas: gas, metrics: metrics)
            case "still": try still(options)
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
                usage: sillage-render black-hole new|run <folder> [--tracers N] [--pericentre r]
                           [--cloud r] [--release r] [--stickiness x] [--crossing-speed x]
                           [--viscous-orbits x] [--cooling-time t] [--duration t]
                           [--frame-interval t] [--step t] [--seed n] [--name text]
                       run also takes [--metrics file.csv --metrics-interval t] and the gas's grid,
                           [--grid-heights n --height-cell h] (1 layer is the spike's plane grid)
                       sillage-render black-hole still <folder> <png> [--at t] [--look name]
                           [--elevation deg] [--azimuth deg] [--distance r] [--fov deg]
                           [--width w] [--height h] [--straight] [--images n]
                           [--temperature radius|crossing] [--hottest K] [--beaming x]
                           [--exposure x] [--stars n] [--thinning x] [--repeat n]
                           [--flight name|file --second s]: the flight's camera and moment there
                then: sillage-render hires <folder>, sillage-render export <folder> [--look film]

                """.utf8))
        return 2
    }

    typealias Options = HoleOptions

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

    /// Writes the scene; a folder that holds a scene already is refused rather than written over.
    @discardableResult
    static func create(_ options: Options) throws -> SceneFolder {
        guard let path = options.words.first else { throw Failure(description: "a folder") }
        let folder = SceneFolder(path: path)
        guard !FileManager.default.fileExists(atPath: folder.scene.path) else {
            throw Failure(description: "\(folder.scene.path) exists already")
        }
        let file = HoleSceneFile(
            name: options.values["name"] ?? folder.url.lastPathComponent, blackHole: scene(options))
        try folder.create(file)
        try HoleFlight.writeSamples(in: folder)
        print("scene      \(folder.scene.path)")
        return folder
    }

    static func look(_ options: Options, folder: SceneFolder) throws -> HoleLookFile {
        try options.look(folder: folder)
    }

    /// One moment of the take, `--at` in the hole's time units, the end of the run by default;
    /// with `--flight`, the flight's camera and moment `--second` seconds into it (#335).
    static func still(_ options: Options) throws {
        guard options.words.count == 2 else { throw Failure(description: "still needs a folder and a png") }
        let folder = SceneFolder(path: options.words[0])
        let take = try HoleTakeFile.Loaded(contentsOf: folder.take)
        let lookFile = try look(options, folder: folder)
        let replay = try HoleStage.Replay(take: take)
        let flight = try options.values["flight"].map {
            try HoleFlight.resolve(
                FlightFile.decoded(from: Data(contentsOf: folder.flight($0))), header: take.header,
                camera: lookFile.camera)
        }
        let second = options.double("second") ?? 0
        let moment = flight.map { $0.captured(atSeconds: second) }
        let step =
            options.double("at").map(replay.step(at:))
            ?? moment.map { Int($0.rounded(.down)) } ?? take.header.steps.last ?? 0
        let drift = options.double("at") == nil ? (moment ?? 0) - (moment?.rounded(.down) ?? 0) : 0
        let width = options.int("width") ?? 1920
        let height = options.int("height") ?? 1080
        let renderer = try HoleRenderer(
            settings: lookFile.settings(width: width, height: height), device: replay.run.device)
        if let at = lookFile.exposureAt {
            renderer.fixedExposure = true
            renderer.upload(replay.seek(replay.step(at: at)))
        }
        let frame = replay.seek(step)
        renderer.upload(frame, drift: Float(drift * take.header.timeStep))
        let started = Date()
        var camera = lookFile.camera.camera(progress: 0)
        var renderLook = lookFile.renderLook
        if let flight {
            let shot = flight.camera(atSeconds: second)
            camera = shot.camera
            renderLook.exposure *= Float(pow(2, shot.exposure))
        }
        // The first frame builds the lens tables and warms the GPU: the median of `--repeat`
        // more is the cost.
        var pixels = renderer.render(frame, camera: camera, look: renderLook)
        let first = renderer.lastGPUTime
        var times: [Double] = []
        for _ in 0..<max(options.int("repeat") ?? 0, 0) {
            pixels = renderer.render(frame, camera: camera, look: renderLook)
            times.append(renderer.lastGPUTime)
        }
        try PNGWriter.write(pixels, width: width, height: height, to: URL(fileURLWithPath: options.words[1]))
        let median = times.isEmpty ? first : times.sorted()[times.count / 2]
        print(
            String(
                format: "t = %.1f, %.1f ms on the GPU (%.1f ms the first frame), %.2f s in all", frame.time,
                median * 1000, first * 1000, Date().timeIntervalSince(started)))
    }
}
