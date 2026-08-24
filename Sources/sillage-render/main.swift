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
let steps = Int(number("steps", 1_200))
let frames = Int(number("frames", 1))
let width = Int(number("width", 1920))
let height = Int(number("height", 1080))
let outputPath = argument("out", default: "out/sillage.png")!

var scene: SceneConfig
switch presetName {
case "merger": scene = .merger(particleCount: particles)
case "flyby": scene = .flyby(particleCount: particles)
case "disk": scene = .isolatedDisk(particleCount: particles)
default:
    FileHandle.standardError.write(Data("unknown preset: \(presetName)\n".utf8))
    exit(2)
}

let settings = RenderSettings(
    width: width,
    height: height,
    pointSize: Float(number("point-size", 2.4)),
    exposure: Float(number("exposure", 1.0)),
    brightness: Float(number("brightness", 0.016)))

print("scene      \(scene.name), \(scene.totalParticleCount) particles, solver \(scene.solver.rawValue)")

let solver = try SolverFactory.make(scene)
let renderer = try Renderer(particles: solver.particles, settings: settings)
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
let elevation = Float(number("elevation", 0.45))
let clock = Date()

// Framing is fixed once so the camera does not drift as the tails grow.
var frozenRadius = Float(number("radius", 0))

for frame in 0..<frames {
    let simulationStart = Date()
    solver.step(count: stepsPerFrame)
    let simulationMs = Date().timeIntervalSince(simulationStart) * 1000

    renderer.upload(positions: solver.particles.positions)
    if frozenRadius <= 0 {
        frozenRadius = framingRadius(solver.particles.positions, percentile: percentile) / zoom
    }
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
            format: "frame %04d  t=%.1f Myr  sim %6.1f ms  render %5.1f ms  %@",
            frame, Double(solver.time) * Physics.megayearsPerTimeUnit, simulationMs, renderMs,
            url.lastPathComponent))
}

print(String(format: "done in %.1f s", Date().timeIntervalSince(clock)))
