import Foundation
import Metal
import SillageCore
import SillageRender

// The Metal side of #274's solver check: samples a scene's massive particles to `massive.bin`
// (#240) and runs `MetalBarnesHutSolver` over them, writing the curves, density maps,
// checkpoints and accelerations the CUDA solver is compared with.
//
//   solver-check sample <scene.json> <particles> <folder>
//   solver-check run <scene.json> <folder holding massive.bin> <out> [--steps 2000]
//       [--every 10] [--maps-every 250] [--snapshots 1,10,100,1000,2000] [--nudge <index>|all]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

let words = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let at = words.firstIndex(of: "--" + name), at + 1 < words.count else { return nil }
    return words[at + 1]
}
func number(_ name: String, _ fallback: Int) -> Int { option(name).flatMap(Int.init) ?? fallback }

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
encoder.nonConformingFloatEncodingStrategy = .convertToString(
    positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")

func bits(_ value: Float) -> String { String(format: "0x%08x", value.bitPattern) }

/// The scene as `sillage-render` builds it from a scene file for the Barnes-Hut solver.
func scene(at path: String, particles: Int) throws -> SceneConfig {
    var file = try SceneFile.decoded(from: Data(contentsOf: URL(fileURLWithPath: path)))
    file.solver = .barnesHut
    return file.scene(particleCount: particles)
}

guard words.count >= 4 else { fail("usage: solver-check sample|run <scene.json> ...") }

switch words[0] {
case "sample":
    guard let particles = Int(words[2]) else { fail("sample: the particle count") }
    let config = try scene(at: words[1], particles: particles)
    let system = RestrictedSolver.sampleParticles(for: config)
    let folder = URL(fileURLWithPath: words[3], isDirectory: true)
    try RunCheckpoint(directory: folder).saveMassive(system)
    try encoder.encode(config).write(to: folder.appendingPathComponent("scene-config.json"))
    struct Sample: Codable {
        var particles: Int
        var count: Int
        var visible: Int
        var timeStep: Float
        var timeStepBits: String
        var softening: Float
        var softeningBits: String
        var openingAngle: Float
        var openingAngleBits: String
        var centerSoftening: Float
        var megayearsPerStep: Double
        var forceChunk: Int
        var leafCapacity: Int
        var maximumTreeDepth: Int
        var treeReuse: Int
        var quadrupole: Bool
        var frameSample: Int
        var tidalFloor: Float
        var tidalCeiling: Float
    }
    let sample = Sample(
        particles: particles, count: system.count, visible: system.visibleCount,
        timeStep: config.timeStep, timeStepBits: bits(config.timeStep),
        softening: config.softening, softeningBits: bits(config.softening),
        openingAngle: config.openingAngle, openingAngleBits: bits(config.openingAngle),
        centerSoftening: config.centerSoftening,
        megayearsPerStep: Double(config.timeStep) * Physics.megayearsPerTimeUnit,
        forceChunk: MetalBarnesHutSolver.forceChunk, leafCapacity: MetalBarnesHutSolver.leafCapacity,
        maximumTreeDepth: MetalBarnesHutSolver.maximumTreeDepth,
        treeReuse: MetalBarnesHutSolver.treeReuse, quadrupole: MetalBarnesHutSolver.quadrupole,
        frameSample: MetalBarnesHutSolver.frameSample, tidalFloor: MetalBarnesHutSolver.tidalFloor,
        tidalCeiling: MetalBarnesHutSolver.tidalCeiling)
    try encoder.encode(sample).write(to: folder.appendingPathComponent("sample.json"))
    print("sample     \(system.visibleCount) visible, \(system.count - system.visibleCount) halo")

case "run":
    let folder = URL(fileURLWithPath: words[2], isDirectory: true)
    let out = URL(fileURLWithPath: words[3], isDirectory: true)
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    var system = try RunCheckpoint(directory: folder).massiveSet()
    let config = try scene(at: words[1], particles: system.visibleCount)
    let steps = number("steps", 2_000)
    let every = number("every", 10)
    let mapsEvery = number("maps-every", 250)
    let snapshots = Set(
        (option("snapshots") ?? "").split(separator: ",").compactMap { Int($0) })
    if option("nudge") == "all" {
        for index in system.positions.indices {
            system.positions[index].x = system.positions[index].x.nextUp
        }
        print("nudge      every particle's x to the next float up")
    } else if let nudge = option("nudge").flatMap(Int.init) {
        let before = system.positions[nudge].x
        system.positions[nudge].x = before.nextUp
        print("nudge      particle \(nudge) x \(bits(before)) -> \(bits(before.nextUp))")
    }
    let sampled = system.formation
    let solver = try MetalBarnesHutSolver(scene: config, massive: system, tracers: nil)
    let count = system.count

    var curves = SolverCurves.header(galaxies: config.galaxies.count)
    var maps = SolverCurves.maps(instants: steps / mapsEvery + 1)
    for step in 0...steps {
        if step > 0 { solver.step() }
        if step % every == 0 {
            curves += SolverCurves.line(
                step: step, time: solver.time, particles: solver.particles, sampled: sampled,
                centers: solver.centers, disks: solver.diskFrames)
        }
        if step % mapsEvery == 0 {
            maps.add(
                solver.positions.contents().bindMemory(to: SIMD3<Float>.self, capacity: count),
                count: system.visibleCount)
        }
        if snapshots.contains(step) || (step == 0 && !snapshots.isEmpty) {
            if step > 0 {
                let url = out.appendingPathComponent("particles-\(step).bin")
                FileManager.default.createFile(atPath: url.path, contents: nil)
                let handle = try FileHandle(forWritingTo: url)
                try solver.writeParticles(to: handle)
                try handle.close()
                try encoder.encode(solver.state).write(
                    to: out.appendingPathComponent("state-\(step).json"))
            }
            // Three floats a particle, the fourth zeroed: the buffer's own is not the force.
            var packed = [Float](repeating: 0, count: count * 4)
            for (index, value) in solver.accelerations.enumerated() {
                packed[index * 4] = value.x
                packed[index * 4 + 1] = value.y
                packed[index * 4 + 2] = value.z
            }
            try packed.withUnsafeBufferPointer { Data(buffer: $0) }.write(
                to: out.appendingPathComponent("accelerations-\(step).bin"))
        }
    }
    try Data(curves.utf8).write(to: out.appendingPathComponent("curves.csv"))
    try maps.npy().write(to: out.appendingPathComponent("density.npy"))
    print(
        String(
            format: "run        %d steps to t = %.9g (%.2f Myr), %d particles", steps, solver.time,
            Double(solver.time) * Physics.megayearsPerTimeUnit, count))

default:
    fail("unknown command \(words[0])")
}
