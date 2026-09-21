import Foundation
import SillageCore
import SillageRender
import simd

func argument(_ name: String, default fallback: String? = nil) -> String? {
    guard let index = CommandLine.arguments.firstIndex(of: "--\(name)"),
        index + 1 < CommandLine.arguments.count
    else { return fallback }
    return CommandLine.arguments[index + 1]
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
let backend = argument("solver", default: "restricted")!

let seed = argument("seed").flatMap(UInt64.init)

var scene: SceneConfig
switch presetName {
case "merger": scene = .merger(particleCount: particles)
case "encounter": scene = .encounter(particleCount: particles)
case "flyby": scene = .flyby(particleCount: particles)
case "disk": scene = .isolatedDisk(particleCount: particles)
// Drawn from the seed and nothing else, which is what a library of scenes wants: the seed is
// the whole description, so a scene worth keeping can be rendered again from one integer.
case "contemplation":
    scene = .contemplation(
        particleCount: particles, seed: seed ?? 1, haste: Float(number("haste", 0)),
        galaxies: argument("galaxies").flatMap(Int.init))
default:
    FileHandle.standardError.write(Data("unknown preset: \(presetName)\n".utf8))
    exit(2)
}
if let seed { scene.seed = seed }
// The presets are self-gravitating by default, so the flag has to set the solver both ways.
switch backend {
case "barnes-hut":
    scene.solver = .barnesHut
    let ratio = Float(number("halo", 1.5))
    for index in scene.galaxies.indices { scene.galaxies[index].haloParticleRatio = ratio }
case "restricted", "cpu":
    scene.solver = .restricted
default:
    FileHandle.standardError.write(Data("unknown solver: \(backend)\n".utf8))
    exit(2)
}
// Softening and step follow from the counts and the solver unless overridden below. Only an
// explicit flag overrides the scale, because a generated scene picks its own.
if let scale = argument("dt-scale").flatMap(Float.init) { scene.timeStepScale = scale }
if let dissipation = argument("dissipation").flatMap(Float.init) {
    for index in scene.galaxies.indices { scene.galaxies[index].dissipationTime = dissipation }
}
scene.retune()
if let dt = argument("dt").flatMap(Float.init) { scene.timeStep = dt }
scene.openingAngle = Float(number("theta", 0.6))
if let value = argument("softening").flatMap(Float.init) { scene.softening = value }

let settings = RenderSettings(
    width: width,
    height: height,
    supersample: Int(number("supersample", 2)),
    brightness: Float(number("brightness", 0.15)),
    dustStrength: Float(number("dust", 0.35)),
    starCount: Int(number("stars", 9000)),
    starSize: Float(number("star-size", 2.2)),
    smoothingScale: Float(number("smoothing", 1.9)),
    bloomThreshold: Float(number("bloom-threshold", 0.55)),
    bloomSoftKnee: Float(number("bloom-knee", 0.6)),
    bloomIntensity: Float(number("bloom", 0.22)),
    bloomLevels: Int(number("bloom-levels", 6)),
    stretch: Float(number("stretch", 18)),
    saturation: Float(number("saturation", 2.8)),
    spikeArms: Int(number("spikes", 6)),
    spikeLength: Float(number("spike-length", 72)),
    spikeIntensity: Float(number("spike-intensity", 0.38)),
    skyLevel: Float(number("sky", 0.0018)),
    noiseLevel: Float(number("noise", 0.0016)),
    galaxyTint: Float(number("tint", 0.35)))

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
let smoothing = try SmoothingField(device: renderer.device, particleCount: seeded.count)
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

let stepsPerFrame = max(steps / max(frames, 1), 1)
let zoom = Float(number("zoom", 1))
let percentile = Float(number("percentile", 0.98))
let elevation = Float(number("elevation", 1.15))
// The camera sweeps from its start angle to its end angle over the sequence, which is how a
// still frame and a moving shot come out of the same command.
let elevationEnd = Float(number("elevation-end", Double(elevation)))
let azimuth = Float(number("azimuth", 0))
let azimuthEnd = Float(number("azimuth-end", Double(azimuth) + number("orbit", 0)))
let clock = Date()

// Framing is fixed once so the camera does not drift as the tails grow.
var frozenRadius = Float(number("radius", 0))

let framesPerSecond = Int32(number("fps", 30))

// The director places the camera and lights the scene on its own. Without it a hundred
// generated scenes come out framed identically, which is the thing that makes a library dull.
let director: Cinematographer? =
    CommandLine.arguments.contains("--director") ? Cinematographer(seed: seed ?? 1) : nil
// One scene in three is seen from inside the disk rather than from outside it.
director?.beginScene(
    seed: seed ?? 1, immersed: CommandLine.arguments.contains("--immersed"))

let videoWriter = try videoPath.map {
    try FrameVideoWriter(
        width: width, height: height, framesPerSecond: framesPerSecond, to: prepared($0))
}

// A take holds the run rather than the picture, so a scene can be rendered again at another
// size, another exposure or another camera without simulating it a second time.
let drawnCount = seeded.visibleCount > 0 ? seeded.visibleCount : seeded.count
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
    if frozenRadius <= 0 {
        frozenRadius = framingRadius(solver.particles.positions, percentile: percentile) / zoom
    }

    // Straight from the buffer on the GPU path, for the same reason as the extent below.
    if let gpuSolver {
        smoothing.update(from: gpuSolver.positions)
    } else {
        smoothing.update(positions: solver.particles.positions)
    }
    renderer.time = solver.time
    renderer.setDiskFrames(
        DiskFrame.make(
            scene: scene, centers: solver.centers, time: solver.time,
            strength: Float(number("arms", 1))))
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
        camera = Camera.framing(
            radius: frozenRadius,
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
            format: "frame %04d  t=%.1f Myr  sim %7.1f ms (%.3f ms/step)  render %5.1f ms",
            frame, Double(solver.time) * Physics.megayearsPerTimeUnit, simulationMs,
            simulationMs / Double(stepsPerFrame), renderMs))
}

try videoWriter?.finish()
try curves?.close()
if let take, let path = argument("take") {
    try RecordingFile.write(take, scene: scene, particles: seeded, to: prepared(path))
}

print(String(format: "done in %.1f s", Date().timeIntervalSince(clock)))
