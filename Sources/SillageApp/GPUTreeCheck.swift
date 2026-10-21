import Foundation
import Metal
import SillageCore
import SillageRender

/// `--gputree [simulated particles...] [take <path>]` builds the same tree on the CPU and on
/// the GPU, over a merger at t = 0 or the last frame of a take, checks that the two agree to
/// the bit, and times every phase of both. Spike for #38. Writes `/tmp/sillage-gputree.log`.
enum GPUTreeCheck {
    @MainActor
    static func run() {
        guard let flag = CommandLine.arguments.firstIndex(of: "--gputree") else { return }
        let arguments = Array(CommandLine.arguments[(flag + 1)...])
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue()
        else {
            FileHandle.standardError.write(Data("gputree: no Metal device\n".utf8))
            exit(1)
        }
        var lines: [String] = []
        func report(_ line: String) {
            print(line)
            lines.append(line)
        }

        if arguments.first == "run" {
            compareRuns(
                visible: arguments.count > 1 ? Int(arguments[1]) ?? 200_000 : 200_000,
                steps: arguments.count > 2 ? Int(arguments[2]) ?? 100 : 100)
        }
        var counts = arguments.prefix { $0 != "take" }.compactMap { Int($0) }
        let take = arguments.firstIndex(of: "take").flatMap {
            $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
        }
        if counts.isEmpty && take == nil { counts = [2_000_000, 5_000_000, 10_000_000] }
        var sets: [() -> (String, [SIMD3<Float>], [Float])] = counts.map { simulated in
            {
                var scene = SceneConfig.merger(particleCount: Int(Double(simulated) / 2.5), seed: 1)
                scene.solver = .barnesHut
                for index in scene.galaxies.indices { scene.galaxies[index].haloParticleRatio = 1.5 }
                scene.retune()
                let particles = RestrictedSolver.sampleParticles(for: scene)
                return ("merger at t = 0", particles.positions, particles.mass)
            }
        }
        if let take {
            sets.append {
                guard let loaded = try? RecordingFile.read(from: URL(fileURLWithPath: take)) else {
                    FileHandle.standardError.write(Data("gputree: cannot read \(take)\n".utf8))
                    exit(1)
                }
                let last = loaded.recording.count - 1
                let positions = loaded.recording.positions(at: last)
                let time = loaded.recording.frames[last].time * Float(Physics.megayearsPerTimeUnit)
                return (
                    "\(URL(fileURLWithPath: take).lastPathComponent) at \(Int(time)) Myr", positions,
                    [Float](repeating: 1, count: positions.count)
                )
            }
        }

        let runs = 6
        let leafCapacity = MetalBarnesHutSolver.leafCapacity
        let depth = MetalBarnesHutSolver.maximumTreeDepth
        for make in sets {
            let (name, positions, mass) = make()
            let count = positions.count

            // On a queue of the solver's own class, as the tree queue builds it.
            let tree = BarnesHutTree(leafCapacity: leafCapacity, maximumDepth: depth)
            let work = DispatchQueue(label: "dev.pierregc.sillage.gputree", qos: .userInitiated)
            let build = CPUBuild(tree: tree)
            var cpu: [String: [Double]] = [:]
            for _ in 0..<runs {
                let group = DispatchGroup()
                work.async(group: group) {
                    let clock = Date()
                    positions.withUnsafeBufferPointer { build.tree.build(positions: $0, mass: mass) }
                    build.phases = build.tree.phaseMilliseconds
                    build.phases["whole"] = Date().timeIntervalSince(clock) * 1000
                }
                group.wait()
                for (phase, spent) in build.phases { cpu[phase, default: []].append(spent) }
            }
            let nodeLength = tree.nodes.count * MemoryLayout<BHNode>.stride
            guard
                let nodeBuffer = device.makeBuffer(length: max(nodeLength, 16), options: .storageModeShared),
                let orderBuffer = device.makeBuffer(length: count * 4, options: .storageModeShared),
                let positionBuffer = device.makeBuffer(
                    bytes: positions, length: count * MemoryLayout<SIMD3<Float>>.stride,
                    options: .storageModeShared),
                let massBuffer = device.makeBuffer(
                    bytes: mass, length: count * 4, options: .storageModeShared),
                let sorted = device.makeBuffer(length: count * 16, options: .storageModePrivate),
                let builder = try? GPUTreeBuilder(
                    device: device, count: count, leafCapacity: leafCapacity, maximumDepth: depth)
            else {
                FileHandle.standardError.write(Data("gputree: allocation failed\n".utf8))
                exit(1)
            }
            for _ in 0..<runs {
                let clock = Date()
                tree.nodes.withUnsafeBytes {
                    nodeBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count)
                }
                tree.order.withUnsafeBytes {
                    orderBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count)
                }
                cpu["upload", default: []].append(Date().timeIntervalSince(clock) * 1000)
            }

            var gpu: [String: [Double]] = [:]
            for _ in 0..<runs {
                for phase in GPUTreeBuilder.Phase.allCases {
                    guard let buffer = queue.makeCommandBuffer() else { continue }
                    builder.encode(
                        phase, into: buffer, positions: positionBuffer, mass: massBuffer, sorted: sorted)
                    buffer.commit()
                    buffer.waitUntilCompleted()
                    gpu[phase.rawValue, default: []].append((buffer.gpuEndTime - buffer.gpuStartTime) * 1000)
                }
                guard let buffer = queue.makeCommandBuffer() else { continue }
                builder.encode(into: buffer, positions: positionBuffer, mass: massBuffer, sorted: sorted)
                let clock = Date()
                buffer.commit()
                buffer.waitUntilCompleted()
                gpu["whole", default: []].append((buffer.gpuEndTime - buffer.gpuStartTime) * 1000)
                gpu["wall", default: []].append(Date().timeIntervalSince(clock) * 1000)
            }
            let comparison = builder.compare(with: tree)
            let levels = builder.levelStarts
            let deepest = (0..<(levels.count - 1)).last { levels[$0 + 1] > levels[$0] } ?? 0

            func median(_ values: [Double]?) -> Double {
                guard let values, !values.isEmpty else { return 0 }
                return values.dropFirst().sorted()[(values.count - 1) / 2]
            }
            func cell(_ value: Double) -> String { String(format: "%8.2f", value) }
            let pairs: [(String, String, String)] = [
                ("bounds", "bounds", "gpu bounds"), ("morton", "morton", "gpu morton"),
                ("sort", "sort", "gpu sort"), ("nodes", "nodes", "gpu nodes"),
                ("masses", "accumulate", "gpu masses"), ("upload", "upload", ""),
            ]
            report(
                "\(name): \(count) particles, \(tree.nodes.count) nodes, deepest level \(deepest),"
                    + " median of \(runs - 1) after one warm-up")
            report("  phase        CPU ms   GPU ms")
            for (label, cpuPhase, gpuPhase) in pairs {
                report(
                    "  " + label.padding(toLength: 10, withPad: " ", startingAt: 0)
                        + cell(median(cpu[cpuPhase]))
                        + (gpuPhase.isEmpty ? "        -" : cell(median(gpu[gpuPhase]))))
            }
            report(
                "  whole     " + cell(median(cpu["whole"]) + median(cpu["upload"]))
                    + cell(median(gpu["whole"]))
                    + "   (GPU in one command buffer, \(String(format: "%.2f", median(gpu["wall"]))) ms wall)"
            )
            report(
                "  same tree: order \(comparison.orderMatches ? "identical" : "DIFFERENT"),"
                    + " \(comparison.nodes.gpu) against \(comparison.nodes.cpu) nodes,"
                    + " \(comparison.firstDifference.map { "cells differ: \($0)" } ?? "cells identical"),"
                    + " \(comparison.massesDiffering) of \(comparison.massesCompared) masses differ"
                    + " (largest relative gap \(comparison.largestRelativeGap))")
            report("")
        }
        try? lines.joined(separator: "\n").write(
            to: URL(fileURLWithPath: "/tmp/sillage-gputree.log"), atomically: true, encoding: .utf8)
        exit(0)
    }
}

extension GPUTreeCheck {
    /// The same merger stepped with each build: the trees are the same to the bit, so the runs
    /// should be too.
    @MainActor
    static func compareRuns(visible: Int, steps: Int) {
        var scene = SceneConfig.merger(particleCount: visible, seed: 1)
        scene.solver = .barnesHut
        for index in scene.galaxies.indices { scene.galaxies[index].haloParticleRatio = 1.5 }
        scene.retune()
        let particles = RestrictedSolver.sampleParticles(for: scene)
        var runs: [ParticleSystem] = []
        for gpu in [false, true] {
            MetalBarnesHutSolver.gpuTree = gpu
            guard let solver = try? MetalBarnesHutSolver(scene: scene, particles: particles) else { exit(1) }
            solver.step(count: steps)
            print(
                "gpu \(gpu): last CPU build \(solver.lastTreeOnlyMilliseconds) ms, \(solver.nodeCount) nodes")
            runs.append(solver.particles)
        }
        MetalBarnesHutSolver.gpuTree = false
        func bits(_ values: [SIMD3<Float>]) -> [UInt32] {
            values.flatMap { [$0.x.bitPattern, $0.y.bitPattern, $0.z.bitPattern] }
        }
        let positions = zip(bits(runs[0].positions), bits(runs[1].positions)).filter { $0 != $1 }.count
        let velocities = zip(bits(runs[0].velocities), bits(runs[1].velocities)).filter { $0 != $1 }.count
        let formed = zip(runs[0].formation, runs[1].formation).filter { $0.bitPattern != $1.bitPattern }.count
        let line =
            "\(particles.count) particles, \(steps) steps: \(positions) position, \(velocities) velocity"
            + " and \(formed) formation values differ between the CPU and the GPU build"
        print(line)
        try? line.write(
            to: URL(fileURLWithPath: "/tmp/sillage-gputree-run.log"), atomically: true, encoding: .utf8)
        exit(0)
    }
}

/// Handed to the build queue and read back once the group is done.
private final class CPUBuild: @unchecked Sendable {
    let tree: BarnesHutTree
    var phases: [String: Double] = [:]

    init(tree: BarnesHutTree) { self.tree = tree }
}
