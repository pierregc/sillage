import AppKit
import Foundation
import SillageCore
import SillageRender

/// Where one scene spends its time: every phase of a step, what a frame costs while the solver
/// runs, and how busy the processor and the GPU were over it.
///
/// `--baseline <visible particles> [steps]` runs a merger with live halos at a fixed seed and
/// writes the report to `/tmp/sillage-baseline-<visible>.log`. `quiet` draws nothing while it
/// steps, which is the only way to read the solver's GPU passes on their own. `overlap` builds
/// each tree alongside the force pass that precedes it. `theta <angle>` replaces the scene's
/// opening angle.
///
/// Headless, before the window opens, so it runs on a machine nobody is looking at; frames are
/// drawn offscreen instead.
enum BaselineCheck {
    @MainActor
    static func run() {
        guard let flag = CommandLine.arguments.firstIndex(of: "--baseline") else { return }
        let arguments = CommandLine.arguments
        let visible = flag + 1 < arguments.count ? Int(arguments[flag + 1]) ?? 700_000 : 700_000
        let wanted = flag + 2 < arguments.count ? Int(arguments[flag + 2]) ?? 100 : 100
        // A command buffer's span counts the frames it waited behind, so the solver's own
        // passes are only clean with nothing drawn.
        let quiet = arguments.contains("quiet")
        let overlap = arguments.contains("overlap")
        MetalBarnesHutSolver.overlapTree = overlap
        let gpuTree = arguments.contains("gputree")
        // Profiling submits every pass on its own, which hands frames gaps the app never has.
        let plain = arguments.contains("plain")
        MetalBarnesHutSolver.yieldForceChunks = arguments.contains("yield") || arguments.contains("nowait")
        MetalBarnesHutSolver.yieldWithoutWaiting = arguments.contains("nowait")
        MetalBarnesHutSolver.gpuTree = gpuTree
        let theta = arguments.firstIndex(of: "theta").flatMap {
            $0 + 1 < arguments.count ? Float(arguments[$0 + 1]) : nil
        }
        guard let model = SimulationModel() else {
            FileHandle.standardError.write(Data("baseline: no Metal device\n".utf8))
            exit(1)
        }

        var draft = SceneConfig.merger(particleCount: visible, seed: 1)
        draft.solver = .barnesHut
        for index in draft.galaxies.indices { draft.galaxies[index].haloParticleRatio = 1.5 }
        if let theta { draft.openingAngle = theta }
        model.draft = draft
        model.draft.retune()
        model.setTotalParticles(visible)
        model.resize(to: CGSize(width: 2560, height: 1440))
        model.start()

        // Nothing has started `NSApplication` yet, so the run loop is turned by hand for the
        // batches that land back on the main queue.
        func pump(until done: () -> Bool, limit: TimeInterval) {
            let deadline = Date().addingTimeInterval(limit)
            while !done(), Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
        }
        let preparing = Date()
        pump(until: { !model.isPreparing && model.solver != nil }, limit: 1800)
        guard let solver = model.solver as? MetalBarnesHutSolver, let renderer = model.renderer
        else {
            FileHandle.standardError.write(Data("baseline: no Barnes-Hut solver\n".utf8))
            exit(1)
        }
        let preparation = Date().timeIntervalSince(preparing)

        // The first batches carry pipeline warm-up and the first tree allocations.
        solver.profiling = !plain
        let warm = model.solverSteps + 2
        pump(until: { model.solverSteps >= warm }, limit: 600)
        _ = solver.takeProfile()

        // A frame as the canvas draws one, offscreen, paced to 60 Hz on the main thread
        // while the solver steps on its own queue.
        func drawFrame() -> Double {
            renderer.time = solver.time
            renderer.setDiskFrames(
                DiskFrame.make(
                    scene: model.scene, centers: solver.centers, time: solver.time,
                    strength: renderer.armPersistence, disks: model.solverDisks))
            _ = renderer.render(camera: model.activeCamera)
            return renderer.lastGPUTime * 1000
        }

        let utilisation = GPUUtilisation()
        utilisation.start()
        let cpuBefore = processorSeconds()
        let ticksBefore = systemTicks()
        let started = Date()
        let firstBatch = model.solverSteps
        var gaps: [Double] = []
        var renderTimes: [Double] = []
        var last = CACurrentMediaTime()
        var next = last
        while (model.solverSteps - firstBatch) * model.stepsPerFrame < wanted {
            next += 1.0 / 60
            RunLoop.current.run(until: Date().addingTimeInterval(max(next - CACurrentMediaTime(), 0)))
            let now = CACurrentMediaTime()
            gaps.append((now - last) * 1000)
            last = now
            if next < now { next = now }
            if !quiet { renderTimes.append(drawFrame()) }
        }
        let wall = Date().timeIntervalSince(started)
        let cpu = processorSeconds() - cpuBefore
        let ticksAfter = systemTicks()
        let profile = solver.takeProfile()
        solver.profiling = false
        let gpuSamples = utilisation.stop()
        gaps.sort()
        let renderGPU = renderTimes.reduce(0, +)
        renderTimes.sort()

        // Off the clock, once the batch in flight has landed.
        model.returnToSetup()
        pump(until: { false }, limit: 3)
        var smoothingTimes: [Double] = []
        if let field = try? SmoothingField(device: model.device, particleCount: visible) {
            for _ in 0..<5 {
                field.update(from: solver)
                smoothingTimes.append(field.lastMilliseconds)
            }
        }
        var idleTimes = (0..<10).map { _ in drawFrame() }
        idleTimes.sort()

        let solverGPU = [
            "star formation", "drift", "gpu bounds", "gpu morton", "gpu sort", "gpu nodes",
            "gpu masses", "force", "kick", "dissipation",
        ].reduce(0) { $0 + (profile.milliseconds[$1] ?? 0) }
        let stepMs = profile.perStep("step")
        let gpuPerStep = solverGPU / Double(max(profile.steps, 1))
        let cpuPerStep = [
            "halo centres", "disk frames", "bounds", "morton", "sort", "nodes", "accumulate",
            "upload",
        ].reduce(0) { $0 + profile.perStep($1) }
        // Whatever the stepping queue does between batches: the take, the smoothing refresh
        // and the hop through the main actor.
        let between = wall * 1000 / Double(max(profile.steps, 1)) - stepMs
        let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
        let size = "\(renderer.settings.width)x\(renderer.settings.height)"

        let plainSteps = (model.solverSteps - firstBatch) * model.stepsPerFrame
        var lines = [
            "plain      \(plainSteps) steps in \(format(wall)) s, \(format(wall * 1000 / Double(max(plainSteps, 1)))) ms a step,"
                + " \(renderTimes.count) frames, \(format(Double(renderTimes.count) / wall)) a second",
            "baseline   merger, seed 1, theta \(solver.openingAngle), live halos 1.5"
                + (quiet ? ", no frames drawn" : "") + (overlap ? ", tree overlapped" : "")
                + (gpuTree ? ", tree built on the GPU" : ""),
            "particles  \(visible) visible, \(model.particleCount) simulated",
            "prepared   \(format(preparation)) s",
            "measured   \(profile.steps) steps, \(profile.treeBuilds) tree builds,"
                + " \(format(wall)) s, \(model.stepsPerFrame) steps a batch",
            "",
            "per step, ms (mean over \(profile.steps); GPU passes timed by the GPU clock)",
        ]
        for phase in StepProfile.phases {
            lines.append(
                "  " + phase.padding(toLength: 16, withPad: " ", startingAt: 0)
                    + String(format: "%9.2f", profile.perStep(phase)))
        }
        let accounted = StepProfile.phases.dropLast().reduce(0) { $0 + profile.perStep($1) }
        lines.append(
            "  " + "unaccounted".padding(toLength: 16, withPad: " ", startingAt: 0)
                + String(format: "%9.2f", profile.perStep("step") - accounted))
        lines += [
            "  " + "between batches".padding(toLength: 16, withPad: " ", startingAt: 0)
                + String(format: "%9.2f", between),
            "",
            "idle share of a step",
            "  GPU                \(format(max(1 - gpuPerStep / stepMs, 0) * 100)) %"
                + "  (\(format(gpuPerStep)) ms of solver passes)",
            "  CPU                \(format(max(1 - cpuPerStep / stepMs, 0) * 100)) %"
                + "  (\(format(cpuPerStep)) ms of centres, frames and build)",
            "",
            "per frame, ms (offscreen \(size), paced to 60 Hz on the main thread)",
            "  smoothing refresh  median \(format(median(smoothingTimes.sorted())))"
                + "  (solver's tree, \(visible) drawn, 5 runs)",
            "  render GPU         median \(format(median(renderTimes)))"
                + "  p95 \(format(percentile(renderTimes, 0.95)))"
                + "  (\(renderTimes.count) frames, solver stepping)",
            "  render GPU         median \(format(median(idleTimes)))  (10 frames, solver idle)",
            "  frame gap          median \(format(median(gaps)))"
                + "  p95 \(format(percentile(gaps, 0.95)))  max \(format(gaps.last ?? 0))",
            "",
            "utilisation over the run",
            "  process CPU        \(format(cpu / wall * 100 / cores)) % of \(Int(cores)) cores"
                + " (\(format(cpu / wall)) cores busy)",
            "  system CPU         \(format(busyFraction(ticksBefore, ticksAfter) * 100)) %",
            // A command buffer's span includes time spent waiting behind another queue's work,
            // so these two overlap and can sum past a hundred. The counter below is the total.
            "  GPU, buffer spans  solver \(format(solverGPU / 1000 / wall * 100)) %,"
                + " render \(format(renderGPU / 1000 / wall * 100)) %",
            "  GPU, ioreg         mean \(format(mean(gpuSamples))) %"
                + "  (\(gpuSamples.count) samples of Device Utilization)",
        ]
        let report = lines.joined(separator: "\n")
        try? report.write(
            to: URL(
                fileURLWithPath:
                    "/tmp/sillage-baseline-\(visible)\(quiet ? "-quiet" : "")\(overlap ? "-overlap" : "")"
                    + "\(gpuTree ? "-gputree" : "")"
                    + "\(theta.map { "-theta\($0)" } ?? "").log"
            ),
            atomically: true, encoding: .utf8)
        print(report)
        exit(0)
    }

    private static func format(_ value: Double) -> String { String(format: "%.1f", value) }

    private static func median(_ sorted: [Double]) -> Double {
        sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        sorted.isEmpty ? 0 : sorted[min(Int(Double(sorted.count) * fraction), sorted.count - 1)]
    }

    private static func mean(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    private static func processorSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        return user + system
    }

    /// User, system, idle and nice ticks summed over every core.
    private static func systemTicks() -> [UInt32] {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return [0, 0, 0, 0] }
        let ticks = info.cpu_ticks
        return [ticks.0, ticks.1, ticks.2, ticks.3]
    }

    private static func busyFraction(_ before: [UInt32], _ after: [UInt32]) -> Double {
        let delta = zip(after, before).map { Double($0 &- $1) }
        let total = delta.reduce(0, +)
        return total > 0 ? 1 - delta[Int(CPU_STATE_IDLE)] / total : 0
    }
}

/// Samples the GPU's own utilisation counter from the IOAccelerator registry twice a second.
/// It needs no privileges, unlike powermetrics, and counts every process on the GPU.
private final class GPUUtilisation: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Double] = []
    private var running = true

    func start() {
        Thread.detachNewThread { [self] in
            while isRunning {
                if let value = Self.read() {
                    lock.lock()
                    samples.append(value)
                    lock.unlock()
                }
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
    }

    func stop() -> [Double] {
        lock.lock()
        defer { lock.unlock() }
        running = false
        return samples
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private static func read() -> Double? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
        process.arguments = ["-r", "-d", "1", "-c", "IOAccelerator"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard let range = text.range(of: "\"Device Utilization %\"=") else { return nil }
        return Double(text[range.upperBound...].prefix { $0.isNumber })
    }
}
