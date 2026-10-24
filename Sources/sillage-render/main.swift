import Foundation
import SillageCore
import SillageRender
import simd

func fail(_ message: String, code: Int32 = 2) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

// `sillage-render <stage> <scene folder> [options]` runs one stage of the pipeline, every path
// derived from the folder. Anything else is a plain render driven by its flags.
let arguments: [String]
if CommandLine.arguments.count > 1,
    let stage = SceneFolder.Stage(rawValue: CommandLine.arguments[1])
{
    guard CommandLine.arguments.count > 2, !CommandLine.arguments[2].hasPrefix("--") else {
        fail("usage: sillage-render \(stage.rawValue) <scene folder> [options]")
    }
    if let issue = stage.pendingIssue {
        fail("\(stage.rawValue): not yet, it arrives with #\(issue)", code: 1)
    }
    let folder = SceneFolder(path: CommandLine.arguments[2])
    let (clip, options) = try folder.storedClip().updated(
        with: Array(CommandLine.arguments.dropFirst(3)))
    try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
    try clip.encoded().write(to: folder.clip)
    arguments = folder.exploreArguments(options, clip: clip)
} else {
    arguments = Array(CommandLine.arguments.dropFirst())
}

func argument(_ name: String, default fallback: String? = nil) -> String? {
    guard let index = arguments.firstIndex(of: "--\(name)"), index + 1 < arguments.count
    else { return fallback }
    return arguments[index + 1]
}

func number(_ name: String, _ fallback: Double) -> Double {
    argument(name).flatMap(Double.init) ?? fallback
}

let presetName = argument("preset", default: "merger")!
let particles = Int(number("particles", 1_000_000))
let steps = Int(number("steps", 3_000))
let frames = Int(number("frames", 1))
let width = Int(number("width", 1920))
let height = Int(number("height", 1080))
// A PNG sequence is still the default, but a run asked for a video does not need one too.
let videoPath = argument("video")
let outputPath = argument("out", default: videoPath == nil ? "out/sillage.png" : nil)

let seed = argument("seed").flatMap(UInt64.init)
let scenePath = argument("scene")
let lookPath = argument("look")

// Everything that decides the image, from the look file if one is given; each flag below
// overrides its field.
var look =
    try lookPath.map { try LookFile.decoded(from: Data(contentsOf: URL(fileURLWithPath: $0))) }
    ?? .standard
func flag(_ name: String, _ field: WritableKeyPath<LookFile, Float>) {
    if let value = argument(name).flatMap(Double.init) { look[keyPath: field] = Float(value) }
}
func flag(_ name: String, _ field: WritableKeyPath<LookFile, Float?>) {
    if let value = argument(name).flatMap(Double.init) { look[keyPath: field] = Float(value) }
}
func flag(_ name: String, _ field: WritableKeyPath<LookFile, Int>) {
    if let value = argument(name).flatMap(Double.init) { look[keyPath: field] = Int(value) }
}
flag("brightness", \.look.brightness)
flag("dust", \.look.dustStrength)
flag("star-size", \.look.starSize)
flag("smoothing", \.look.smoothingScale)
flag("min-kernel", \.look.minimumKernel)
flag("max-kernel", \.look.maximumKernel)
flag("bloom-threshold", \.look.bloomThreshold)
flag("bloom-knee", \.look.bloomSoftKnee)
flag("bloom", \.look.bloomIntensity)
flag("stretch", \.look.stretch)
flag("saturation", \.look.saturation)
flag("white-point", \.look.whitePoint)
flag("spikes", \.look.spikeArms)
flag("spike-length", \.look.spikeLength)
flag("spike-intensity", \.look.spikeIntensity)
flag("sky", \.look.skyLevel)
flag("noise", \.look.noiseLevel)
flag("tint", \.look.galaxyTint)
flag("fov", \.look.fieldOfView)
flag("stars", \.starCount)
if arguments.contains("--plain") { look.plain = true }
flag("supersample", \.supersample)
flag("bloom-levels", \.bloomLevels)
flag("arms", \.armStrength)
flag("zoom", \.camera.zoom)
flag("percentile", \.camera.percentile)
flag("radius", \.camera.radius)
flag("elevation", \.camera.elevation)
flag("elevation-end", \.camera.elevationEnd)
flag("azimuth", \.camera.azimuth)
if let orbit = argument("orbit").flatMap(Double.init) {
    look.camera.azimuthEnd = look.camera.azimuth + Float(orbit)
}
flag("azimuth-end", \.camera.azimuthEnd)
if arguments.contains("--director") {
    look.camera.mode = arguments.contains("--immersed") ? .immersed : .director
}
if let mode = argument("camera") {
    guard let parsed = LookFile.CameraPlan.Mode(rawValue: mode) else {
        FileHandle.standardError.write(Data("unknown camera: \(mode)\n".utf8))
        exit(2)
    }
    look.camera.mode = parsed
}

// Every scene runs from its scene file, so the file written beside the output replays exactly
// what ran. Read from disk, a scene keeps its own values unless a flag is given.
var file: SceneFile
var palette: [SIMD3<Float>] = []
// A generated scene's pericentres are drawn for a default stretch of time and moved into the
// clip once its step is known.
var generatedHaste: Float?
if let scenePath {
    file = try SceneFile.decoded(from: Data(contentsOf: URL(fileURLWithPath: scenePath)))
} else {
    let preset: SceneConfig
    switch presetName {
    case "merger": preset = .merger(particleCount: particles)
    case "encounter": preset = .encounter(particleCount: particles)
    case "flyby": preset = .flyby(particleCount: particles)
    case "disk": preset = .isolatedDisk(particleCount: particles)
    // Drawn from the seed and nothing else, which is what a library of scenes wants: the seed
    // is the whole description, so a scene worth keeping can be rendered again from one integer.
    case "contemplation":
        preset = .contemplation(
            particleCount: particles, seed: seed ?? 1, haste: Float(number("haste", 0)),
            galaxies: argument("galaxies").flatMap(Int.init),
            lookSeed: argument("look-seed").flatMap(UInt64.init))
        generatedHaste = Float(number("haste", 0))
    default:
        FileHandle.standardError.write(Data("unknown preset: \(presetName)\n".utf8))
        exit(2)
    }
    file = SceneFile(preset)
    palette = preset.galaxies.map(\.color)
    file.openingAngle = 0.6
}
if let seed { file.seed = seed }
let placedFor = (file.solver, file.galaxies.map(\.haloParticleRatio))
let backend = argument(
    "solver", default: scenePath == nil || file.solver == .restricted ? "restricted" : "barnes-hut")!
// The presets are self-gravitating by default, so the flag has to set the solver both ways.
switch backend {
case "barnes-hut":
    file.solver = .barnesHut
    if let ratio = argument("halo").flatMap(Float.init) ?? (scenePath == nil ? 1.5 : nil) {
        for index in file.galaxies.indices { file.galaxies[index].haloParticleRatio = ratio }
    }
case "restricted", "cpu":
    file.solver = .restricted
default:
    FileHandle.standardError.write(Data("unknown solver: \(backend)\n".utf8))
    exit(2)
}
// Softening and step follow from the counts and the solver unless overridden below. Only an
// explicit flag overrides the scale, because a generated scene picks its own.
if let scale = argument("dt-scale").flatMap(Float.init) { file.timeStepScale = scale }
if let dissipation = argument("dissipation").flatMap(Float.init) {
    for index in file.galaxies.indices { file.galaxies[index].dissipationTime = dissipation }
}
if let dt = argument("dt").flatMap(Float.init) { file.timeStep = dt }
if let theta = argument("theta").flatMap(Float.init) { file.openingAngle = theta }
if let value = argument("softening").flatMap(Float.init) { file.softening = value }
for (index, colour) in look.palette.enumerated() {
    if index < palette.count { palette[index] = colour } else { palette.append(colour) }
}
var scene = file.scene(particleCount: particles, palette: palette)
// Encounters are placed for a solver and a halo; a flag that changes either places them again.
if !scene.encounters.isEmpty,
    generatedHaste != nil || placedFor.0 != file.solver
        || placedFor.1 != file.galaxies.map(\.haloParticleRatio)
{
    if let generatedHaste {
        scene.retimeEncounters(
            from: SceneConfig.contemplationWindow(haste: generatedHaste),
            to: scene.clipWindow(
                settleSteps: Int(number("settle", 0)), steps: Int(number("steps", 3_000))))
    }
    scene.placeEncountersGivingWay()
    let kept = file
    file = SceneFile(scene)
    file.softening = kept.softening
    file.timeStep = kept.timeStep
}
for encounter in scene.encounters {
    print(
        String(
            format: "encounter  %d-%d, pericentre %.1f kpc at %.0f Myr, e %.2f (%@), mass ratio %.2f",
            encounter.primary, encounter.secondary, encounter.pericentre,
            encounter.pericentreTime, encounter.eccentricity, encounter.orbit.rawValue,
            encounter.massRatio))
}
// A generated scene is judged from its centres before any particle is drawn, so one that would
// show nothing costs a moment rather than a night's slot. A scene read from a file was judged
// when it was drawn; `--check` judges it again and `--no-check` spares a generated one.
// `--check-only` stops here with the numbers.
if generatedHaste != nil && !arguments.contains("--no-check")
    || arguments.contains("--check") || arguments.contains("--check-only")
{
    let checkStart = Date()
    let verdict = scene.sanityCheck(
        settleSteps: Int(number("settle", 0)), steps: Int(number("steps", 3_000)))
    if arguments.contains("--check-only") {
        print(
            String(
                format: "check      closest %@, Toomre %@, start clearance %@, frame %.1f, %.0f ms",
                verdict.closestApproach.map { String(format: "%.1f kpc at %.0f Myr", $0.distance, $0.time) }
                    ?? "none",
                verdict.toomre.map { String(format: "%.2f-%.2f", $0.lowerBound, $0.upperBound) } ?? "none",
                verdict.startClearance.map { String(format: "%.2f", $0) } ?? "none",
                verdict.fieldRatio, Date().timeIntervalSince(checkStart) * 1000))
    }
    if !verdict.accepted {
        print("rejected   " + verdict.reasons.map(\.description).joined(separator: "; "))
        exit(3)
    }
    if arguments.contains("--check-only") { exit(0) }
}
// The colours the scene was drawn with, so the look file written beside it replays it exactly.
look.palette = scene.galaxies.map(\.color)

let settings = RenderSettings(
    width: width,
    height: height,
    supersample: look.supersample,
    brightness: look.look.brightness,
    dustStrength: look.look.dustStrength,
    starCount: look.starCount,
    starSize: look.look.starSize,
    smoothingScale: look.look.smoothingScale,
    minimumKernel: look.look.minimumKernel,
    maximumKernel: look.look.maximumKernel,
    bloomThreshold: look.look.bloomThreshold,
    bloomSoftKnee: look.look.bloomSoftKnee,
    bloomIntensity: look.look.bloomIntensity,
    bloomLevels: look.bloomLevels,
    stretch: look.look.stretch,
    saturation: look.look.saturation,
    whitePoint: look.look.whitePoint,
    spikeArms: look.look.spikeArms,
    spikeLength: look.look.spikeLength,
    spikeIntensity: look.look.spikeIntensity,
    skyLevel: look.look.skyLevel,
    noiseLevel: look.look.noiseLevel,
    galaxyTint: look.look.galaxyTint, plain: look.plain)

print(
    "scene      \(scene.name), \(scene.totalParticleCount) visible"
        + (scene.hasLiveHalos
            ? ", \(scene.simulatedParticleCount - scene.totalParticleCount) halo" : ""))

let seeded = RestrictedSolver.sampleParticles(for: scene)
let gpuSolver: (any GPUSolver)? =
    backend == "cpu" ? nil : try GPUSolverFactory.make(scene: scene, particles: seeded)
let solver: any Solver = gpuSolver ?? RestrictedSolver(scene: scene, particles: seeded)
let renderer = try Renderer(
    particles: seeded, settings: settings, externalPositions: gpuSolver?.positions,
    externalFormation: gpuSolver?.formation)
// Each particle's kernel spans its own local interparticle spacing, so the surface stays
// continuous instead of resolving the sampling.
let drawnCount = seeded.visibleCount > 0 ? seeded.visibleCount : seeded.count
let smoothing = try SmoothingField(device: renderer.device, particleCount: drawnCount)
renderer.setSmoothing(smoothing.buffer)
print("solver     \(backend) (\(scene.solver.rawValue))")
print("gpu        \(renderer.gpuName)")

/// Radius holding a given fraction of the particles, so a few escapers do not shrink the frame.
func framingRadius(_ positions: [SIMD3<Float>], percentile: Float) -> Float {
    var radii = positions.map { simd_length($0) }
    radii.sort()
    return radii[min(Int(Float(radii.count) * percentile), radii.count - 1)]
}

func prepared(_ path: String) throws -> URL {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    return url
}

let outputURL = try outputPath.map(prepared)
// One still, small enough for a grid of a few hundred scenes, from the middle of the clip
// unless a frame is named.
let thumbnailURL = try argument("thumbnail").map(prepared)
let thumbnailFrame = min(Int(number("thumbnail-frame", Double(frames / 2))), frames - 1)

// Named after the main output, so `x.mov` and `x.sillage` both get `x.scene.json` and
// `x.look.json`.
func beside(_ suffix: String) -> String? {
    [argument("take"), videoPath, outputPath].compactMap { $0 }.first.map { path in
        let url = URL(fileURLWithPath: path)
        let stem = url.lastPathComponent.split(separator: ".").first.map(String.init) ?? "scene"
        return url.deletingLastPathComponent().appendingPathComponent(stem + suffix).path
    }
}
if let sceneOutPath = argument("scene-out") ?? beside(".scene.json") {
    try file.encoded().write(to: prepared(sceneOutPath))
    print("scene file \(sceneOutPath)")
}

let stepsPerFrame = max(steps / max(frames, 1), 1)
let zoom = look.camera.zoom
let percentile = look.camera.percentile
let elevation = look.camera.elevation
// The camera sweeps from its start angle to its end angle over the sequence, which is how a
// still frame and a moving shot come out of the same command.
let elevationEnd = look.camera.elevationEnd ?? elevation
let azimuth = look.camera.azimuth
let azimuthEnd = look.camera.azimuthEnd ?? azimuth
let clock = Date()

// Framing is fixed once so the camera does not drift as the tails grow.
var frozenRadius = look.camera.radius

let framesPerSecond = Int32(number("fps", 30))

// The director re-applies a look every frame, so it is handed this one to build on; without
// it, it would pick one of its own named looks and every look flag would be silently ignored.
renderer.apply(look.look)

// The director places the camera and lights the scene on its own. Without it a hundred
// generated scenes come out framed identically, which is the thing that makes a library dull.
let directed = look.camera.mode == .director || look.camera.mode == .immersed
let director: Cinematographer? = directed ? Cinematographer(seed: scene.seed) : nil
var autoCamera = AutoCamera()
let reach = scene.galaxies.map { max($0.diskScaleLength * $0.diskTruncation, 0.1) }
director?.beginScene(seed: scene.seed, base: look.look, immersed: look.camera.mode == .immersed)

if let lookOutPath = argument("look-out") ?? beside(".look.json") {
    try (director?.lookFile(look) ?? look).encoded().write(to: prepared(lookOutPath))
    print("look file  \(lookOutPath)")
}

let videoWriter = try videoPath.map {
    try FrameVideoWriter(
        width: width, height: height, framesPerSecond: framesPerSecond, to: prepared($0))
}

// A take holds the run rather than the picture, so a scene can be rendered again at another
// size, another exposure or another camera without simulating it a second time.
let take: Recording? = argument("take").map { _ in
    let reel = Recording(particleCount: drawnCount, galaxyCount: scene.galaxies.count)
    reel.reserve(frames: frames)
    return reel
}

/// Per frame scalars, written for whoever scores the result later: a curve to drive a filter
/// with is worth more than a picture of one.
let curves: FileHandle? = try argument("curves").map { path in
    let url = try prepared(path)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.write(
        contentsOf: Data("frame,time_myr,separation_kpc,extent_kpc,formed\n".utf8))
    return handle
}
var previousTime = solver.time

// Steps run before the first frame is written. A sampled disk is not born in equilibrium and
// settles over its first few hundred megayears, which is worth simulating and not worth
// watching.
let settle = Int(number("settle", 0))
if settle > 0 {
    let settleStart = Date()
    solver.step(count: settle)
    print(
        String(
            format: "settle     %d steps, t=%.1f Myr, %.1f s", settle,
            Double(solver.time) * Physics.megayearsPerTimeUnit,
            Date().timeIntervalSince(settleStart)))
}

for frame in 0..<frames {
    let simulationStart = Date()
    solver.step(count: stepsPerFrame)
    let simulationMs = Date().timeIntervalSince(simulationStart) * 1000

    if gpuSolver == nil {
        renderer.upload(positions: solver.particles.positions)
    }
    if frozenRadius <= 0 && look.camera.mode != .auto {
        frozenRadius = framingRadius(solver.particles.positions, percentile: percentile) / zoom
    }

    let smoothingStart = Date()
    // Plain points have no kernel to size.
    if !look.plain {
        if let gpuSolver {
            smoothing.update(from: gpuSolver)
        } else {
            smoothing.update(positions: solver.particles.positions)
        }
    }
    let smoothingMs = Date().timeIntervalSince(smoothingStart) * 1000
    renderer.time = solver.time
    renderer.setDiskFrames(
        DiskFrame.make(
            scene: scene, centers: solver.centers, time: solver.time,
            strength: look.armStrength))
    let camera: Camera
    if let director {
        // Advanced by one frame of playback rather than by wall clock, so the move reads the
        // same however long the frame took to compute.
        director.advance(
            seconds: 1 / Double(framesPerSecond),
            of: Subject(centres: solver.centers, radius: frozenRadius))
        renderer.apply(director.look)
        camera = director.camera
    } else {
        // Smoothstep rather than linear, so the move eases in and out instead of starting and
        // stopping dead.
        let span = Float(max(frames - 1, 1))
        let t = Float(frame) / span
        let eased = t * t * (3 - 2 * t)
        var framed = (center: SIMD3<Float>.zero, radius: frozenRadius)
        if look.camera.mode == .auto {
            framed = autoCamera.frame(centres: solver.centers, margins: reach)
            framed.radius /= zoom
        }
        camera = Camera.framing(
            radius: framed.radius, center: framed.center, fieldOfView: look.look.fieldOfView,
            elevation: elevation + (elevationEnd - elevation) * eased,
            azimuth: azimuth + (azimuthEnd - azimuth) * eased)
    }
    let renderStart = Date()
    let pixels = renderer.render(camera: camera)
    let renderMs = Date().timeIntervalSince(renderStart) * 1000

    if let outputURL {
        let url =
            frames == 1
            ? outputURL
            : outputURL.deletingPathExtension().appendingPathExtension(
                String(format: "%04d.png", frame))
        try PNGWriter.write(pixels, width: width, height: height, to: url)
    }
    try videoWriter?.append(pixels)
    if let thumbnailURL, frame == thumbnailFrame {
        try PNGWriter.write(pixels, width: width, height: height, maximumWidth: 480, to: thumbnailURL)
        print("thumbnail  \(thumbnailURL.path)")
    }

    if let take {
        if let gpuSolver {
            take.append(
                positions: gpuSolver.positions.contents().bindMemory(
                    to: SIMD3<Float>.self, capacity: seeded.count),
                time: solver.time, centers: solver.centers)
        } else {
            solver.particles.positions.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                take.append(positions: base, time: solver.time, centers: solver.centers)
            }
        }
    }

    if let curves {
        let centres = solver.centers
        let separation =
            centres.count >= 2 ? simd_length(centres[1] - centres[0]) : Float(0)
        // Root mean square radius over a subsample: a smooth measure of how far the thing has
        // spread, for a fraction of the cost of sorting every radius. Read straight out of the
        // position buffer: `particles` on a GPU solver rebuilds the whole system on every
        // access, and calling it once per sample made each frame nine seconds slower.
        var sum: Float = 0
        var counted = 0
        if let gpuSolver {
            let positions = gpuSolver.positions.contents().bindMemory(
                to: SIMD3<Float>.self, capacity: seeded.count)
            for index in stride(from: 0, to: drawnCount, by: 64) {
                sum += simd_length_squared(positions[index])
                counted += 1
            }
        } else {
            let positions = solver.particles.positions
            for index in stride(from: 0, to: drawnCount, by: 64) {
                sum += simd_length_squared(positions[index])
                counted += 1
            }
        }
        let extent = counted > 0 ? (sum / Float(counted)).squareRoot() : 0
        var formed = 0
        if let gpuSolver {
            let times = gpuSolver.formation.contents().bindMemory(
                to: Float.self, capacity: seeded.count)
            for index in 0..<drawnCount
            where times[index] > previousTime && times[index] <= solver.time {
                formed += 1
            }
        }
        let myr = Double(solver.time) * Physics.megayearsPerTimeUnit
        try curves.write(
            contentsOf: Data(
                String(
                    format: "%d,%.3f,%.4f,%.4f,%d\n", frame, myr, separation, extent, formed
                ).utf8))
    }
    previousTime = solver.time

    print(
        String(
            format:
                "frame %04d  t=%.1f Myr  sim %7.1f ms (%.3f ms/step)  smoothing %6.1f ms"
                + "  render %5.1f ms (gpu %5.2f)",
            frame, Double(solver.time) * Physics.megayearsPerTimeUnit, simulationMs,
            simulationMs / Double(stepsPerFrame), smoothingMs, renderMs,
            renderer.lastGPUTime * 1000))
}

try videoWriter?.finish()
try curves?.close()
if let take, let path = argument("take") {
    try RecordingFile.write(take, scene: scene, particles: seeded, to: prepared(path))
}

print(String(format: "done in %.1f s", Date().timeIntervalSince(clock)))
