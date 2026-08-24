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
let outputPath = argument("out", default: "out/sillage.png")!
let backend = argument("solver", default: "restricted")!

var scene: SceneConfig
switch presetName {
case "merger": scene = .merger(particleCount: particles)
case "flyby": scene = .flyby(particleCount: particles)
case "disk": scene = .isolatedDisk(particleCount: particles)
default:
    FileHandle.standardError.write(Data("unknown preset: \(presetName)\n".utf8))
    exit(2)
}
if let seed = argument("seed").flatMap(UInt64.init) { scene.seed = seed }
if backend == "barnes-hut" {
    scene.solver = .barnesHut
    // Self-gravity needs a far smaller step than tracers in a rigid potential.
    scene.timeStep = 0.006
}
if let dt = argument("dt").flatMap(Float.init) { scene.timeStep = dt }
scene.openingAngle = Float(number("theta", 0.6))
scene.softening = Float(number("softening", 0.12))

let settings = RenderSettings(
    width: width,
    height: height,
    supersample: Int(number("supersample", 2)),
    pointSize: Float(number("point-size", 1.7)),
    exposure: Float(number("exposure", 1.0)),
    brightness: Float(number("brightness", 0.15)),
    dustStrength: Float(number("dust", 0.16)),
    starCount: Int(number("stars", 2600)),
    starSize: Float(number("star-size", 2.2)),
    bloomThreshold: Float(number("bloom-threshold", 0.55)),
    bloomSoftKnee: Float(number("bloom-knee", 0.6)),
    bloomIntensity: Float(number("bloom", 0.45)),
    bloomLevels: Int(number("bloom-levels", 6)),
    stretch: Float(number("stretch", 18)),
    saturation: Float(number("saturation", 1.8)),
    spikeArms: Int(number("spikes", 6)),
    spikeLength: Float(number("spike-length", 72)),
    spikeIntensity: Float(number("spike-intensity", 0.38)),
    skyLevel: Float(number("sky", 0.0018)),
    noiseLevel: Float(number("noise", 0.0016)))

print("scene      \(scene.name), \(scene.totalParticleCount) particles")

let seeded = RestrictedSolver.sampleParticles(for: scene)
let gpuSolver: (any GPUSolver)? =
    backend == "cpu" ? nil : try GPUSolverFactory.make(scene: scene, particles: seeded)
let solver: any Solver = gpuSolver ?? RestrictedSolver(scene: scene, particles: seeded)
let renderer = try Renderer(
    particles: seeded, settings: settings, externalPositions: gpuSolver?.positions)
// Each particle's kernel spans its own local interparticle spacing, so the surface stays
// continuous instead of resolving the sampling.
let smoothing = try SmoothingField(device: renderer.device, particleCount: seeded.count)
smoothing.scale = Float(number("smoothing", 1.0))
smoothing.neighbours = Float(number("neighbours", 64))
renderer.setSmoothing(smoothing.buffer)
print("solver     \(backend) (\(scene.solver.rawValue))")
print("gpu        \(renderer.gpuName)")

/// Radius holding a given fraction of the particles, so a few escapers do not shrink the frame.
func framingRadius(_ positions: [SIMD3<Float>], percentile: Float) -> Float {
    var radii = positions.map { simd_length($0) }
    radii.sort()
    return radii[min(Int(Float(radii.count) * percentile), radii.count - 1)]
}

let outputURL = URL(fileURLWithPath: outputPath)
try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

let stepsPerFrame = max(steps / max(frames, 1), 1)
let zoom = Float(number("zoom", 1))
let percentile = Float(number("percentile", 0.98))
let elevation = Float(number("elevation", 1.15))
let clock = Date()

// Framing is fixed once so the camera does not drift as the tails grow.
var frozenRadius = Float(number("radius", 0))

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

    smoothing.update(positions: solver.particles.positions)
    renderer.setDiskFrames(
        DiskFrame.make(
            scene: scene, centers: solver.centers, time: solver.time,
            strength: Float(number("arms", 1))))
    let camera = Camera.framing(radius: frozenRadius, elevation: elevation)
    let renderStart = Date()
    let pixels = renderer.render(camera: camera)
    let renderMs = Date().timeIntervalSince(renderStart) * 1000

    let url =
        frames == 1
        ? outputURL
        : outputURL.deletingPathExtension().appendingPathExtension(
            String(format: "%04d.png", frame))
    try PNGWriter.write(pixels, width: width, height: height, to: url)

    print(
        String(
            format: "frame %04d  t=%.1f Myr  sim %7.1f ms (%.3f ms/step)  render %5.1f ms  %@",
            frame, Double(solver.time) * Physics.megayearsPerTimeUnit, simulationMs,
            simulationMs / Double(stepsPerFrame), renderMs, url.lastPathComponent))
}

print(String(format: "done in %.1f s", Date().timeIntervalSince(clock)))
