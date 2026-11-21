import Foundation
import SillageCore
import SillageRender
import simd

/// The measuring options of a take pass on Metal (#376), which no take needs and only the Mac
/// runs: `--sf-leaves`, `--dump-walk`, `--dump-targets`, `--take-v6`, `--take-massive` and
/// `--density`, each at the moment of the frame it always ran at.
final class MetalMeasures: TakePassMeasures {
    private var engine: MetalTakePassEngine!
    // `--sf-leaves <path>` (#306): what the star formation pass reads on the leaves, summed, after
    // each frame's steps.
    private var formationLeaves: FileHandle?
    // `--dump-walk <dir> --dump-walk-frames 0,57:pericentre` (#271): at the end of the steps of
    // each listed frame, every buffer the tracers' walk reads and Metal's answers on that state,
    // for the CUDA spike (docs/notes/cuda-walk-spike.md). Moves nothing.
    private var walkDirectory: URL?
    private var walkDumps: [Int: String] = [:]
    private var walkScene = ""
    private var walkCommit = ""
    // `--dump-targets <dir> --dump-targets-frames 4:close` (#276): as `export --dump-targets`, of
    // the frames this run draws itself, with the light tracers it draws. Moves nothing.
    private var targetDirectory: URL?
    private var targetDumps: [Int: String] = [:]
    private var targetLookFile = ""
    private var targetManifest: RenderTargetManifest?
    // `--take-v6 path`: the same take at 16 bits an axis, as version 6 wrote it, for comparing.
    private var takeV6: Recording?
    // `--take-massive path`: the same run drawn with its massive particles only, for comparing.
    private var massiveTake: Recording?
    // `--density path` counts the stars on a fixed grid at `--density-frames` instants, the same
    // grid at every particle count, so runs of one scene compare without a camera in between.
    private var densityURL: URL?
    private var density: DensityMap?
    // With tracers, the same maps of the tracers alone and of the massive particles alone.
    private var tracerDensity: DensityMap?
    private var massiveDensity: DensityMap?

    func started(_ run: TakePassRun) throws {
        guard let engine = run.engine as? MetalTakePassEngine else { return }
        self.engine = engine
        let massiveDrawn =
            engine.massive.visibleCount > 0 ? engine.massive.visibleCount : engine.massive.count
        let drawnCount = engine.tracerCount + massiveDrawn
        takeV6 = run.argument("take-v6").map { _ in run.reel(drawnCount, bitsPerAxis: 16) }
        massiveTake = run.argument("take-massive").map { _ in run.reel(massiveDrawn) }
        formationLeaves = try run.argument("sf-leaves").map { path in
            let url = try TakePassRun.prepared(path)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.write(contentsOf: Data((StarFormationLeaves.csvHeader + "\n").utf8))
            return handle
        }
        densityURL = try run.argument("density").map(TakePassRun.prepared)
        density = densityURL.map { _ in
            DensityMap(
                frames: run.frames, count: Int(run.number("density-frames", 8)),
                extent: Float(run.number("density-extent", 60)))
        }
        tracerDensity = engine.tracerCount > 0 ? density : nil
        massiveDensity = engine.tracerCount > 0 ? density : nil

        walkDirectory = run.argument("dump-walk").map { URL(fileURLWithPath: $0, isDirectory: true) }
        for entry in run.argument("dump-walk-frames")?.split(separator: ",") ?? [] {
            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            guard let index = Int(parts[0]), index >= 0 else {
                fail("--dump-walk-frames: no frame \"\(entry)\"")
            }
            walkDumps[index] = parts.count > 1 ? parts[1] : "frame \(index)"
        }
        if walkDirectory != nil || !walkDumps.isEmpty {
            guard walkDirectory != nil, !walkDumps.isEmpty else {
                fail("--dump-walk and --dump-walk-frames go together")
            }
            guard engine.tracerSolver != nil else {
                fail("--dump-walk: no light tracers to dump (--massive)")
            }
        }
        walkScene =
            run.argument("scene").map { path -> String in
                let url = URL(fileURLWithPath: path)
                return url.lastPathComponent == "scene.json"
                    ? url.deletingLastPathComponent().pathComponents.suffix(2).joined(separator: "/")
                    : url.deletingPathExtension().lastPathComponent
            } ?? run.built.presetName
        walkCommit = walkDirectory.map { _ in TracerWalkDump.sourceCommit() } ?? ""

        targetDirectory = run.argument("dump-targets").map { URL(fileURLWithPath: $0, isDirectory: true) }
        for entry in run.argument("dump-targets-frames")?.split(separator: ",") ?? [] {
            let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
            guard let index = Int(parts[0]), index >= 0 else {
                fail("--dump-targets-frames: no frame \"\(entry)\"")
            }
            targetDumps[index] = parts.count > 1 ? parts[1] : String(format: "frame-%05d", index)
        }
        guard (targetDirectory == nil) == targetDumps.isEmpty else {
            fail("--dump-targets and --dump-targets-frames go together")
        }
        let look = run.look
        targetLookFile = "looks/\(look.name).look.json"
        targetManifest = try targetDirectory.map { directory -> RenderTargetManifest in
            let url = directory.appendingPathComponent(targetLookFile)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try look.encoded().write(to: url)
            let particles = engine.solver.particles
            let visible = particles.visibleCount
            let take = RenderTargetManifest.Take(
                file: "", scene: walkScene, particles: particles.count,
                drawn: visible > 0 ? visible : particles.count, capturedFrames: run.frames,
                capturedRate: run.framesPerSecond)
            var held =
                RenderTargetManifest.read(from: directory).flatMap {
                    $0.width == run.width && $0.height == run.height && $0.take.scene == take.scene ? $0 : nil
                }
                ?? RenderTargetManifest(
                    commit: "", device: "", system: "", width: run.width, height: run.height, take: take)
            held.source = "Metal, sillage-render hires --dump-targets"
            held.commit = TracerWalkDump.sourceCommit()
            held.device = engine.renderer.gpuName
            held.system = ProcessInfo.processInfo.operatingSystemVersionString
            held.take = take
            return held
        }
    }

    func afterSteps(_ run: TakePassRun, frame: Int) throws {
        guard let engine else { return }
        let solver = engine.solver
        if let formationLeaves, let barnesHut = engine.gpuSolver as? MetalBarnesHutSolver {
            let line = barnesHut.formationLeaves().csvLine(
                frame: frame, timeMyr: Double(solver.time) * Physics.megayearsPerTimeUnit,
                stepMyr: Double(run.built.scene.timeStep) * Physics.megayearsPerTimeUnit)
            try formationLeaves.write(contentsOf: Data((line + "\n").utf8))
        }
        if let walkDirectory, let label = walkDumps[frame], let tracerSolver = engine.tracerSolver {
            guard let dump = tracerSolver.walkDump() else { fail("--dump-walk: frame \(frame) not captured") }
            let timeMyr = Double(solver.time) * Physics.megayearsPerTimeUnit
            let written = try dump.write(
                to: walkDirectory,
                run: TracerWalkDump.Run(
                    scene: walkScene, label: label, frame: frame,
                    step: run.settle + (frame + 1) * run.stepsPerFrame, timeMyr: timeMyr,
                    dtScale: run.built.file.timeStepScale, commit: walkCommit, device: engine.renderer.gpuName
                ))
            print(
                String(
                    format: "walk dump  frame %d (%@), t=%.2f Myr: %@", frame, label, timeMyr, written.path))
        }
    }

    func afterDrawing(_ run: TakePassRun, frame: Int, camera: Camera, drew: Bool) throws {
        guard let engine, let targetDirectory, let name = targetDumps[frame] else { return }
        let renderer = engine.renderer
        if !drew { _ = renderer.render(camera: camera) }
        guard let targets = renderer.particleTargets() else {
            fail("--dump-targets: frame \(frame) not captured")
        }
        try targetManifest?.add(
            RenderTargetManifest.Capture(
                captured: Double(frame), time: engine.solver.time, shot: nil, camera: camera, targets: targets
            ),
            look: run.look.name, lookFile: targetLookFile, name: name,
            megayearsPerUnit: Physics.megayearsPerTimeUnit, to: targetDirectory)
        print(
            String(
                format: "targets    frame %d (%@), %d massive and %d tracers, look %@: %@", frame,
                name, targets.drawn, targets.tracers, run.look.name,
                targetDirectory.appendingPathComponent("targets/\(run.look.name)/\(name)").path))
    }

    func afterTake(_ run: TakePassRun, frame: Int) throws {
        guard let engine else { return }
        let solver = engine.solver
        let tracerCount = engine.tracerCount
        if let massiveTake {
            engine.withPositions { positions in
                massiveTake.offer(
                    positions: positions + tracerCount, time: solver.time, centers: solver.centers,
                    disks: engine.diskFrames, budget: run.takeBudget)
            }
        }
        if let takeV6 {
            engine.withPositions { positions in
                takeV6.offer(
                    positions: positions, time: solver.time, centers: solver.centers,
                    disks: engine.diskFrames,
                    budget: run.takeBudget)
            }
        }
        guard density?.wants(frame: frame) == true else { return }
        let massive = engine.massive
        let massiveDrawn = massive.visibleCount > 0 ? massive.visibleCount : massive.count
        let drawnCount = tracerCount + massiveDrawn
        guard engine.gpuSolver != nil else {
            engine.withPositions { density?.add($0, count: drawnCount) }
            return
        }
        engine.withPositions { positions in
            density?.add(positions, count: drawnCount)
            guard tracerCount > 0 else { return }
            tracerDensity?.add(positions, count: tracerCount)
            massiveDensity?.add(positions + tracerCount, count: massiveDrawn)
            // Whether the light leaves the mass: the share in tails and bridges, and the spread,
            // of each set alike.
            let centres = solver.centers
            let tidalReach = run.tidalReach
            let reach = run.reach
            func spread(_ range: Range<Int>) -> (tidal: Double, extent: Double) {
                var tidal = 0
                var sum = 0.0
                var counted = 0
                outer: for index in stride(from: range.lowerBound, to: range.upperBound, by: 16) {
                    let position = positions[index]
                    sum += Double(simd_length_squared(position))
                    counted += 1
                    for (centre, limit) in zip(centres, tidalReach)
                    where simd_length_squared(position - centre) < limit * limit {
                        continue outer
                    }
                    tidal += 1
                }
                let samples = Double(max(counted, 1))
                return (Double(tidal) / samples, (sum / samples).squareRoot())
            }
            // And how thick each disk is, off the plane it turns in: heating shows there.
            let tracerSolver = engine.tracerSolver
            let disks = tracerSolver?.diskFrames ?? []
            func heights(_ range: Range<Int>) -> [Double] {
                var sums = [Double](repeating: 0, count: disks.count)
                var counted = [Int](repeating: 0, count: disks.count)
                for index in stride(from: range.lowerBound, to: range.upperBound, by: 16) {
                    let word = index < tracerCount ? tracerSolver?.tracerWord(index) : nil
                    let galaxy = Int(word?.galaxy ?? massive.galaxyIndex[index - tracerCount])
                    let kind = word?.component ?? massive.component[index - tracerCount]
                    guard galaxy < disks.count, galaxy < centres.count,
                        kind < ParticleComponent.halo.rawValue
                    else { continue }
                    let offset = positions[index] - centres[galaxy]
                    let height = simd_dot(offset, disks[galaxy].axis)
                    guard simd_length(offset - disks[galaxy].axis * height) < reach[galaxy] else {
                        continue
                    }
                    sums[galaxy] += Double(height * height)
                    counted[galaxy] += 1
                }
                return zip(sums, counted).map { $1 > 0 ? ($0 / Double($1)).squareRoot() : 0 }
            }
            let light = spread(0..<tracerCount)
            let heavy = spread(tracerCount..<drawnCount)
            let thickness = zip(heights(0..<tracerCount), heights(tracerCount..<drawnCount)).map {
                String(format: "%.3f/%.3f", $0, $1)
            }
            print(
                String(
                    format: "drift      frame %d t=%.1f Myr: tails %.3f %% light, %.3f %% massive;"
                        + " rms extent %.3f kpc light, %.3f massive; disk rms height light/massive ",
                    frame, Double(solver.time) * Physics.megayearsPerTimeUnit, light.tidal * 100,
                    heavy.tidal * 100, light.extent, heavy.extent)
                    + thickness.joined(separator: ", ") + " kpc")
        }
    }

    func finish(_ run: TakePassRun) throws {
        guard let engine else { return }
        try formationLeaves?.close()
        if let density, let densityURL {
            try density.npy().write(to: densityURL)
            print("density    \(density.instants.count) maps, \(densityURL.path)")
            for (name, maps) in [("tracers", tracerDensity), ("massive", massiveDensity)] {
                guard let maps else { continue }
                let url = densityURL.deletingPathExtension().appendingPathExtension("\(name).npy")
                try maps.npy().write(to: url)
                print("density    \(name) \(url.path)")
            }
        }
        if let takeV6, let path = run.argument("take-v6") {
            try RecordingFile.write(
                takeV6, scene: run.drawnScene, particles: engine.capturedParticles(),
                to: TakePassRun.prepared(path))
        }
        if let massiveTake, let path = run.argument("take-massive") {
            let captured = engine.gpuSolver?.capturedParticles(from: engine.massive) ?? engine.massive
            try RecordingFile.write(
                massiveTake, scene: run.built.scene, particles: captured, to: TakePassRun.prepared(path))
        }
    }
}
