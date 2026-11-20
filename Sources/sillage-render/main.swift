import CoreGraphics
import Foundation
import SillageCore
import SillageRender
import simd

// `sillage-render <stage> <scene folder> [options]` runs one stage of the pipeline, every path
// derived from the folder. Anything else is a plain render driven by its flags.
let started = Date()
let arguments: [String]
switch RenderCommands.check(Array(CommandLine.arguments.dropFirst())) {
case .run:
    break
case .help(let text):
    print(text)
    exit(0)
case .refused(let message):
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "event" {
    exit(eventCommand(Array(CommandLine.arguments.dropFirst(2))))
}
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "queue" {
    exit(
        QueueCommand.main(
            Array(CommandLine.arguments.dropFirst(2)), executable: Spawn.currentExecutable))
}
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "night" {
    exit(
        NightCommand.main(
            Array(CommandLine.arguments.dropFirst(2)), executable: Spawn.currentExecutable))
}
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "status" {
    exit(StatusCommand.main(Array(CommandLine.arguments.dropFirst(2))))
}
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "pace" {
    exit(paceCommand(Array(CommandLine.arguments.dropFirst(2))))
}
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "story" {
    exit(storyCommand(Array(CommandLine.arguments.dropFirst(2))))
}
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "flight" {
    exit(flightCommand(Array(CommandLine.arguments.dropFirst(2))))
}
// `fixtures <directory>`: Metal writes the reference outputs both engines must give (#281).
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "fixtures" {
    guard CommandLine.arguments.count == 3 else { fail("usage: sillage-render fixtures <directory>") }
    do {
        try EngineFixtures.write(
            into: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true),
            executable: Spawn.currentExecutable)
    } catch {
        fail("fixtures: \(error)")
    }
    exit(0)
}
// `hole-fixtures <directory>`: the black hole close up's reference outputs (#336).
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "hole-fixtures" {
    guard CommandLine.arguments.count == 3 else { fail("usage: sillage-render hole-fixtures <directory>") }
    do {
        try HoleFixtures.write(into: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
    } catch {
        fail("hole-fixtures: \(error)")
    }
    exit(0)
}
var hiresRun: (folder: SceneFolder, record: SceneFolder.Hires)?
/// The second of a hires's two passes, which draws the videos rather than a take (#239).
var fullPass = false
var exploreRun: SceneFolder?
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "probe-disk" {
    exit(probeDiskCommand(Array(CommandLine.arguments.dropFirst(2))))
}
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "black-hole" {
    exit(HoleCommand.main(Array(CommandLine.arguments.dropFirst(2))))
}
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "match" {
    exit(PhotoMatchCommand.main(Array(CommandLine.arguments.dropFirst(2))))
}
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "costs" {
    exit(costsCommand(Array(CommandLine.arguments.dropFirst(2))))
}
if CommandLine.arguments.count > 1,
    let stage = SceneFolder.Stage(rawValue: CommandLine.arguments[1])
{
    guard CommandLine.arguments.count > 2, !CommandLine.arguments[2].hasPrefix("--") else {
        fail("usage: sillage-render \(stage.rawValue) <scene folder> [options]")
    }
    let folder = SceneFolder(path: CommandLine.arguments[2])
    let options = Array(CommandLine.arguments.dropFirst(3))
    // A black hole close up (#332) runs and draws through stages of its own.
    if folder.isBlackHole {
        let run = StageReporter(stage: stage.rawValue, folder: folder)
        do {
            switch stage {
            case .hires:
                guard options.isEmpty else {
                    fail("hires: a black hole close up runs as its scene.json says, without options")
                }
                try HoleStage.run(folder, reporter: run)
            case .export:
                _ = try HoleStage.export(folder, options: HoleExportOptions(options), reporter: run)
            default:
                throw SceneFolder.HoleError.galaxyStage(stage.rawValue)
            }
        } catch {
            run.finish()
            fail("\(stage.rawValue): \(error)")
        }
        run.finish()
        exit(0)
    }
    switch stage {
    case .look:
        do {
            exit(try lookStage(folder, options: options))
        } catch {
            fail("look: \(error)")
        }
    case .palettes:
        do {
            exit(try paletteStage(folder, options: options))
        } catch {
            fail("palettes: \(error)")
        }
    case .export:
        let run = StageReporter(stage: stage.rawValue, folder: folder)
        reporter = run
        do {
            let code = try exportStage(folder, options: options, reporter: run)
            run.finish()
            if code == 0 { refreshCosts(folder) }
            exit(code)
        } catch {
            fail("export: \(error)")
        }
    case .hires:
        if !folder.isExplored && FileManager.default.fileExists(atPath: folder.url.path) {
            exit(hiresBatch(folder.url, options: options))
        }
        do {
            let plan = try folder.hiresArguments(
                options, maximumParticles: SceneFolder.maximumParticles())
            arguments = plan.arguments
            hiresRun = (folder, plan.record)
            let record = plan.record
            fullPass = SceneFolder.pass(in: options) == "full"
            let run = StageReporter(stage: stage.rawValue, folder: folder)
            reporter = run
            run.start(detail: fullPass ? "full pass, starting" : "starting")
            var begun = RunEvent(RunEvent.Kind.hiresStart)
            begun.particles = record.particles
            begun.massive = record.massive
            begun.steps = record.steps
            begun.pass = fullPass ? "full" : record.pass?.rawValue
            run.record(begun)
            let costs = CostModel.current(library: folder.library)
            let steps = record.stepsToRun
            var seconds = costs.hiresSeconds(
                particles: record.particles, massive: record.massive, steps: steps)
            if fullPass, let index = plan.arguments.firstIndex(of: "--draw") {
                seconds = costs.fullPassSeconds(
                    particles: record.particles, massive: record.massive, steps: steps,
                    frames: record.frames,
                    presets: plan.arguments[index + 1].split(separator: ",").map(String.init))
            } else if record.pass == .massive {
                seconds = costs.hiresSeconds(particles: record.massiveParticles, steps: steps)
            }
            print(
                String(
                    format: "hires      %d particles%@ (preview %d), step %.5f Myr (preview %.5f),"
                        + " settle %d, %d steps, clip %.1f to %.1f Myr, about %.1f h%@",
                    record.particles, record.massive.map { " from \($0) massive" } ?? "",
                    record.previewParticles, record.timeStepMyr, record.previewTimeStepMyr,
                    record.settle, record.steps, record.clipStartMyr, record.clipEndMyr,
                    seconds / 3600,
                    fullPass ? ", full pass" : record.pass == .massive ? ", massive pass" : ""))
            if let schedule = record.stepSchedule, !fullPass {
                print(
                    "schedule   \(schedule), \(record.stepsToRun) steps planned for \(record.settle + record.steps)"
                        + (schedule.margin.map {
                            String(format: ", judged on the run's own centres with a margin of %g Myr", $0)
                        } ?? ""))
            } else if fullPass, let switches = record.stepSwitches, !switches.isEmpty {
                print("schedule   the massive pass's switches, \(StepSwitches(switches))")
            }
        } catch {
            fail("hires: \(error)")
        }
    default:
        var (clip, rest) = try folder.exploreStart(options)
        // Written again once the run has followed the story to its end.
        clip.story = nil
        try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
        try clip.encoded().write(to: folder.clip)
        arguments = folder.exploreArguments(rest, clip: clip)
        exploreRun = folder
        let run = StageReporter(stage: stage.rawValue, folder: folder)
        reporter = run
        run.start(detail: "starting")
        exploreRun = folder
    }
} else {
    // A plain render takes flags only: a word here is a command this binary does not have,
    // and must not start a render of a million particles.
    if let word = CommandLine.arguments.dropFirst().first, !word.hasPrefix("--") {
        fail("sillage-render: no command \"\(word)\"")
    }
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

// A full pass (#239) runs through the flow the Mac and the CUDA engine share (#278).
if arguments.contains("--draw") {
    if arguments.contains("--dt-schedule") {
        fail("--dt-schedule: a full pass follows the steps its massive pass took, --dt-switches (#312)")
    }
    do {
        try FullPassRun(
            arguments: arguments, engine: MetalFullPassMaker(), started: started, reporter: reporter,
            hires: fullPass ? hiresRun : nil
        ).run()
    } catch {
        fail("full pass: \(error)")
    }
    reporter?.finish()
    if let (folder, _) = hiresRun { refreshCosts(folder) }
    print(String(format: "done in %.1f s", Date().timeIntervalSince(started)))
    exit(0)
}

let presetName = argument("preset", default: "merger")!
let particles = Int(number("particles", 1_000_000))
var steps = Int(number("steps", 3_000))
let frames = Int(number("frames", 1))
let width = Int(number("width", 1920))
let height = Int(number("height", 1080))
// A PNG sequence is still the default, but a run asked for a video does not need one too, nor
// a run that draws its videos with `--draw`.
let videoPath = argument("video")
let outputPath = argument(
    "out", default: videoPath == nil && argument("draw") == nil ? "out/sillage.png" : nil)

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
flag("column", \.look.columnSmoothing)
flag("glint", \.look.glint)
flag("dust-web", \.look.dustWeb)
flag("old-width", \.look.oldWidth)
flag("bulge-width", \.look.bulgeWidth)
flag("young-width", \.look.youngWidth)
flag("knot-width", \.look.knotWidth)
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
if let aim = argument("center") {
    let parts = aim.split(separator: ",").compactMap { Float($0) }
    guard parts.count == 3 else {
        FileHandle.standardError.write(Data("--center is x,y,z in kiloparsecs\n".utf8))
        exit(2)
    }
    look.camera.center = SIMD3(parts[0], parts[1], parts[2])
}
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
    // The scene at `--index` in the batch `--seed` draws, archetypes mixed in at `--archetypes`
    // and pairs at `--pair-share`, `off` for a batch drawn before the share (#176). The seed is
    // the batch's here, and the scene's own follows from it and the index.
    case "free":
        preset = BatchDraw(
            batchSeed: seed ?? 1,
            archetypeShare: Float(number("archetypes", Double(BatchDraw.defaultArchetypeShare))),
            pairShare: argument("pair-share") == "off"
                ? nil : Float(number("pair-share", Double(BatchDraw.defaultPairShare))),
            spacing: Float(number("spacing", Double(FreeDraw.defaultSpacing))),
            haste: Float(number("haste", 0))
        ).scene(at: Int(number("index", 0)), particleCount: particles)
        generatedHaste = Float(number("haste", 0))
    // An archetype alone: its scene number `--index` in batch `--seed`, the same one the batch
    // draws when that archetype comes round for that time.
    default:
        guard let archetype = Archetype(rawValue: presetName) else {
            FileHandle.standardError.write(Data("unknown preset: \(presetName)\n".utf8))
            exit(2)
        }
        preset = archetype.scene(
            batchSeed: seed ?? 1, occurrence: Int(number("index", 0)), particleCount: particles,
            haste: Float(number("haste", 0)))
        generatedHaste = Float(number("haste", 0))
    }
    file = SceneFile(preset)
    palette = preset.galaxies.map(\.color)
    file.openingAngle = 0.9
}
// A scene described before the calm disk (#167) replays as it was written; `--calm` moves
// every galaxy onto it, and the scene file written beside the output records the change.
if arguments.contains("--calm") {
    for index in file.galaxies.indices { file.galaxies[index].adoptCalmDisk() }
}
let batchSeeded = presetName == "free" || Archetype(rawValue: presetName) != nil
if let seed, scenePath != nil || !batchSeeded { file.seed = seed }
let placedFor = (file.solver, file.galaxies.map(\.haloParticleRatio))
let backend = argument(
    "solver", default: scenePath == nil || file.solver == .restricted ? "restricted" : "barnes-hut")!
// The presets are self-gravitating by default, so the flag has to set the solver both ways.
switch backend {
case "barnes-hut":
    file.solver = .barnesHut
    if let ratio = argument("halo").flatMap(Float.init) ?? (scenePath == nil ? 1.5 : nil) {
        for index in file.galaxies.indices where file.galaxies[index].kind != .blackHole {
            file.galaxies[index].haloParticleRatio = ratio
        }
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
for (index, entry) in look.palette.enumerated() {
    if index < palette.count { palette[index] = entry.colour } else { palette.append(entry.colour) }
}
var scene = file.scene(particleCount: particles, palette: palette)
// `--span Myr` runs as many steps as cover it at the step this scene has, a whole number a frame.
if let span = argument("span").flatMap(Double.init) {
    steps = SceneFolder.Clip.steps(
        spanMyr: span, stepMyr: Double(scene.timeStep) * Physics.megayearsPerTimeUnit, frames: frames)
}
// Encounters are placed for a solver and a halo; a flag that changes either places them again.
if !scene.encounters.isEmpty,
    generatedHaste != nil || placedFor.0 != file.solver
        || placedFor.1 != file.galaxies.map(\.haloParticleRatio)
{
    if let generatedHaste {
        scene.retimeEncounters(
            from: SceneConfig.contemplationWindow(haste: generatedHaste),
            to: scene.encounterWindow(
                settleSteps: Int(number("settle", 0)), steps: steps))
    }
    scene.placeEncountersGivingWay()
    let kept = file
    file = SceneFile(scene)
    file.softening = kept.softening
    file.timeStep = kept.timeStep
}
if let draw = scene.draw {
    print(
        "draw       \(draw.generator), batch \(draw.batchSeed) scene \(draw.index) (point \(draw.point)): "
            + draw.families.map(\.rawValue).joined(separator: ", "))
}
for encounter in scene.encounters {
    // How fast the pair would be far apart, or for a bound one, the speed its binding is worth.
    let mass =
        scene.galaxies[encounter.primary].potential.mass + scene.galaxies[encounter.secondary].potential.mass
    let speed =
        (abs(encounter.eccentricity - 1) * mass / encounter.pericentre).squareRoot()
        * Float(Physics.kilometersPerSecondPerVelocityUnit)
    print(
        String(
            format:
                "encounter  %d-%d, pericentre %.1f kpc at %.0f Myr, e %.2f (%@, %@ %.0f km/s), mass ratio %.2f",
            encounter.primary, encounter.secondary, encounter.pericentre,
            encounter.pericentreTime, encounter.eccentricity, encounter.orbit.rawValue,
            encounter.eccentricity < 1 ? "binding" : "far out", speed, encounter.massRatio))
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
        settleSteps: Int(number("settle", 0)), steps: steps)
    if arguments.contains("--check-only") {
        print(
            String(
                format: "check      closest %@, Toomre %@, start clearance %@, frame %.1f, "
                    + "step %.5f Myr, %.0f ms",
                verdict.closestApproach.map { String(format: "%.1f kpc at %.0f Myr", $0.distance, $0.time) }
                    ?? "none",
                verdict.toomre.map { String(format: "%.2f-%.2f", $0.lowerBound, $0.upperBound) } ?? "none",
                verdict.startClearance.map { String(format: "%.2f", $0) } ?? "none",
                verdict.fieldRatio, Double(scene.timeStep) * Physics.megayearsPerTimeUnit,
                Date().timeIntervalSince(checkStart) * 1000))
    }
    if !verdict.accepted {
        print("rejected   " + verdict.reasons.map(\.description).joined(separator: "; "))
        reporter?.finish()
        exit(3)
    }
    if arguments.contains("--check-only") { exit(0) }
}
// The colours the scene was drawn with, so the look file written beside it replays it exactly.
look.palette = scene.galaxies.enumerated().map { index, galaxy in
    index < look.palette.count ? look.palette[index] : GalaxyColours(galaxy.color)
}

let settings = look.renderSettings(width: width, height: height)

// `--massive M` (#187): the scene is drawn at `--particles`, and only about M of the visible
// particles carry the mass, with dark matter drawn for M (#211). The softening and the step are
// the massive count's; the others are light tracers in their field.
let massiveCount = SceneFolder.massive(in: arguments).map { min($0, particles) }
var drawnScene = scene
if let massiveCount {
    guard backend == "barnes-hut" else { fail("--massive needs the Barnes-Hut solver") }
    scene = file.scene(particleCount: massiveCount, palette: palette)
    // A disk drawn for its response answers at the massive particles' softening (#181).
    drawnScene.solveToomreQ(softening: scene.softening)
}
// With tracers, the halo is the massive count's.
print(
    "scene      \(scene.name), \(drawnScene.totalParticleCount) visible"
        + (scene.hasLiveHalos
            ? ", \(scene.simulatedParticleCount - scene.totalParticleCount) halo" : ""))
// Only the full pass checkpoints (#240), and it runs above.
if arguments.contains("--checkpoint") { fail("--checkpoint: only the full pass checkpoints, with --draw") }
// With tracers `seeded` is the massive set alone: the tracers go straight into the solver's
// buffers as they are sampled, 32 bytes each (#238).
var seeded: ParticleSystem
var tracerCount = 0
var tracerStore: LightTracerStore?
// `--massive-only` (#239): the massive particles of that draw run alone, which the same draw
// with its tracers repeats to the bit, so the shots planned on this run frame that one. The
// tracers are drawn to pick the same massive particles, then dropped as they come.
let massiveOnly = arguments.contains("--massive-only")
if massiveCount != nil {
    let splitStart = Date()
    if massiveOnly {
        let kept = ParticleSystem.streamingLightTracers(drawn: drawnScene, massive: scene) { _ in }
        (seeded, tracerCount) = (kept.massive, kept.tracers)
    } else {
        let split = try MetalBarnesHutSolver.lightTracers(drawn: drawnScene, massive: scene)
        (tracerStore, seeded, tracerCount) = (split.tracers, split.massive, split.tracers.count)
    }
    print(
        String(
            format: "tracers    %d light, %d massive visible, %d halo, softening %.4f, step %.5f,"
                + " angle %.2f, %.1f s",
            tracerCount, seeded.visibleCount, seeded.count - seeded.visibleCount,
            scene.softening, scene.timeStep,
            argument("theta-tracers").flatMap(Float.init) ?? scene.openingAngle,
            Date().timeIntervalSince(splitStart)))
} else {
    seeded = RestrictedSolver.sampleParticles(for: drawnScene)
}
if massiveOnly, tracerCount > 0 {
    tracerCount = 0
    drawnScene = scene
    print("massive    \(seeded.visibleCount) visible run alone, without the tracers")
}
// `--massive-set <path>` (#278): the massive set as sampled, which a full pass on another
// machine reads rather than sampling it again.
if let path = argument("massive-set") {
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let saved = try RunCheckpoint.writeMassiveSet(seeded, to: url)
    print(
        String(
            format: "massive    the massive set, %.2f GB in %.2f s", Double(saved.bytes) / 1e9,
            saved.seconds))
}
// `--tracer-sort N` and `--tracer-sort-chunk N`: how often the tracers' walk order is sorted,
// and how many are sorted together, to measure them.
if let interval = argument("tracer-sort").flatMap(Int.init) {
    MetalBarnesHutSolver.tracerSortInterval = interval
}
if let chunk = argument("tracer-sort-chunk").flatMap(Int.init) {
    MetalBarnesHutSolver.tracerSortChunk = chunk
}
let gpuSolver: (any GPUSolver)? =
    backend == "cpu"
    ? nil
    : tracerCount > 0
        ? try MetalBarnesHutSolver(scene: scene, massive: seeded, tracers: tracerStore)
        : try GPUSolverFactory.make(scene: scene, particles: seeded)
tracerStore = nil
let tracerSolver = tracerCount > 0 ? gpuSolver as? MetalBarnesHutSolver : nil
if let theta = argument("theta-tracers").flatMap(Float.init),
    let solver = gpuSolver as? MetalBarnesHutSolver
{
    solver.tracerOpeningAngle = theta
}
// `--profile` times every pass of a step on the GPU, printed with each frame.
let profiled = arguments.contains("--profile") ? gpuSolver as? MetalBarnesHutSolver : nil
profiled?.profiling = true
let solver: any Solver = gpuSolver ?? RestrictedSolver(scene: scene, particles: seeded)
let renderer = try Renderer(
    particles: seeded, settings: settings, externalPositions: gpuSolver?.positions,
    externalFormation: gpuSolver?.formation, externalPositionOffset: tracerCount * 16)
try renderer.setTracers(tracerSolver)
// Each particle's kernel spans its own local interparticle spacing, so the surface stays
// continuous instead of resolving the sampling. A tracer reads its own off the massive tree.
let massiveDrawn = seeded.visibleCount > 0 ? seeded.visibleCount : seeded.count
let drawnCount = tracerCount + massiveDrawn
// Particles the solver's position buffer holds, tracers first.
let heldCount = tracerCount + seeded.count
let smoothing = try SmoothingField(device: renderer.device, particleCount: massiveDrawn)
renderer.setSmoothing(smoothing.buffer)
renderer.setGalaxyColours(look.palette)
print("solver     \(backend) (\(scene.solver.rawValue))")
print("gpu        \(renderer.gpuName)")

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
    guard !arguments.contains("--no-sidecars") else { return nil }
    return [argument("take"), videoPath, outputPath].compactMap { $0 }.first.map { path in
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
// `--dt-schedule 0:2,162:1` (#307, #312): a coarser step for stretches of the run, switched on
// frame boundaries; with `--dt-judge <Myr>` the run holds the fine step while its own centres
// say a pair is engaged, or was within that margin. docs/notes/variable-time.md.
let stepSchedule = try argument("dt-schedule").map(StepSchedule.init(parsing:)).map { given in
    var given = given
    given.margin = argument("dt-judge").flatMap(Double.init)
    return given
}
try stepSchedule?.check(stepsPerFrame: stepsPerFrame)
let scheduledSolver = gpuSolver as? MetalBarnesHutSolver
if stepSchedule != nil && scheduledSolver == nil { fail("--dt-schedule needs the Barnes-Hut solver") }
let ownStep = scene.timeStep
var scheduler = stepSchedule.map {
    StepScheduler(
        schedule: $0, stepMyr: Double(ownStep) * Physics.megayearsPerTimeUnit,
        story: Story(scene: scene))
}
/// Steps through `count` of the run's own steps, at the scale the schedule gives the stretch
/// starting here, and shows the run's centres to its judge. Returns how many steps that took.
@discardableResult
func advance(_ count: Int, frame: Int?) -> Int {
    guard var current = scheduler, let scheduledSolver else {
        solver.step(count: count)
        return count
    }
    let (run, switched) = current.step(count, frame: frame, on: scheduledSolver, ownStep: ownStep)
    if switched, let last = current.switches.last {
        print(
            String(
                format: "schedule   step x%d from t=%.2f Myr%@", last.scale, last.myr,
                frame.map { " (frame \($0))" } ?? ", settling"))
    }
    scheduler = current
    return run
}
let zoom = look.camera.zoom
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
    try VideoWriter(
        width: width, height: height, framesPerSecond: framesPerSecond, to: prepared($0))
}

// A take holds the run rather than the picture, so a scene can be rendered again at another
// size, another exposure or another camera without simulating it a second time.
// Past its budget it carries on in a scratch file, which is what lets a take of tens of
// gigabytes be captured on a machine with less memory than that.
let takeBudget = Int(
    number("take-memory", Double(ProcessInfo.processInfo.physicalMemory / 4) / 1e6) * 1e6)
// `--take-interval n` keeps one frame in n, and whatever draws the take again interpolates
// the rest.
let takeInterval = max(Int(number("take-interval", 1)), 1)
func takeReel(_ particles: Int, bitsPerAxis: Int = Recording.defaultBitsPerAxis) -> Recording {
    let reel = Recording(
        particleCount: particles, galaxyCount: scene.galaxies.count, interval: takeInterval,
        bitsPerAxis: bitsPerAxis)
    reel.reserve(frames: min(frames / takeInterval + 1, takeBudget / reel.frameBytes + 1))
    return reel
}
let take: Recording? = argument("take").map { _ in takeReel(drawnCount) }
// `--take-v6 path`: the same take at 16 bits an axis, as version 6 wrote it, for comparing.
let takeV6: Recording? = argument("take-v6").map { _ in takeReel(drawnCount, bitsPerAxis: 16) }
// `--take-massive path`: the same run drawn with its massive particles only, for comparing.
let massiveTake: Recording? = argument("take-massive").map { _ in takeReel(massiveDrawn) }

/// Per frame scalars, written for whoever scores the result later: a curve to drive a filter
/// with is worth more than a picture of one.
let curvesHeader =
    "frame,time_myr,separation_kpc,extent_kpc,formed,closest_kpc,tidal_fraction"
    + scene.galaxies.indices.map { ",disruption_\($0)" }.joined()
    + scene.galaxies.indices.map { ",x_\($0),y_\($0),z_\($0)" }.joined()
    + scene.galaxies.indices.map { ",torn_\($0)" }.joined() + "\n"
let curves: FileHandle? = try argument("curves").map { path in
    let url = try prepared(path)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.write(contentsOf: Data(curvesHeader.utf8))
    return handle
}
// `--story-cap <Myr>` keeps capturing past the planned frames while the story goes on, up to
// that much simulated time; `explore` asks for it. It reads the curves as written, so judging
// the file again afterwards gives the same answer.
let storyCap = argument("story-cap").flatMap(Double.init) ?? 0
// Frames kept after the story ends, to see that nothing happens next. For measuring only.
let storyAfter = number("story-after", 0)
var storySettings = Story.Settings()
storySettings.horizon = storyCap
var story =
    storyCap > 0 && curves != nil
    ? Story.Tracker(story: Story(scene: scene, settings: storySettings)) : nil
// `--sf-leaves <path>` (#306): what the star formation pass reads on the leaves, summed, after
// each frame's steps.
let formationLeaves: FileHandle? = try argument("sf-leaves").map { path in
    let url = try prepared(path)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try handle.write(contentsOf: Data((StarFormationLeaves.csvHeader + "\n").utf8))
    return handle
}
var previousTime = solver.time
var curvesSeconds: Double = 0
var takeSeconds: Double = 0
// `--density path` counts the stars on a fixed grid at `--density-frames` instants, the same
// grid at every particle count, so runs of one scene compare without a camera in between.
let densityURL = try argument("density").map(prepared)
var density = densityURL.map { _ in
    DensityMap(
        frames: frames, count: Int(number("density-frames", 8)),
        extent: Float(number("density-extent", 60)))
}
// With tracers, the same maps of the tracers alone and of the massive particles alone.
var tracerDensity = tracerCount > 0 ? density : nil
var massiveDensity = tracerCount > 0 ? density : nil
// A sampled star farther than this from every centre is in a tail or a bridge, not a disk. A
// black hole holds no disk, so the stars it carries off count as torn from the host.
let tidalReach = zip(reach, scene.galaxies).map { $1.kind == .blackHole ? 0 : $0 * 1.5 }

// Steps run before the first frame is written. A sampled disk is not born in equilibrium and
// settles over its first few hundred megayears, which is worth simulating and not worth
// watching.
let settle = Int(number("settle", 0))
// The cost of a step is flat (#19), so what has been done so far says what is left: while
// settling, from the pace of the steps; once frames come, from the pace of the frames, which
// the drawing of each one is part of.
let totalSteps = settle + stepsPerFrame * frames
/// The run's steps done and left once `ownDone` of its own are done: a schedule's coarser steps
/// cover more of its time, which the progress and the estimated end count.
func runSteps(ownDone: Int) -> (done: Int, left: Int) {
    guard let scheduler, let stepSchedule else { return (ownDone, max(totalSteps - ownDone, 0)) }
    let left = stepSchedule.steps(
        settle: settle, frames: frames, perFrame: stepsPerFrame, stepMyr: scheduler.stepMyr, from: ownDone)
    return (scheduler.stepsRun, left)
}
if settle > 0 {
    let settleStart = Date()
    // In chunks, so a settle of minutes still reports; a schedule's in frames, the last one
    // ending where the first frame starts.
    let chunk = stepSchedule == nil ? max(settle / 50, 1) : stepsPerFrame
    var settled = 0
    while settled < settle {
        let count =
            stepSchedule == nil || settled > 0
            ? min(chunk, settle - settled) : (settle - 1) % stepsPerFrame + 1
        advance(count, frame: nil)
        settled += count
        let elapsed = Date().timeIntervalSince(settleStart)
        let (done, left) = runSteps(ownDone: settled)
        let progress = Double(done) / Double(max(done + left, 1))
        reporter?.update(
            progress: progress, detail: "settle \(settled)/\(settle)",
            eta: RunStatus.eta(elapsed: elapsed, progress: progress, now: Date()))
    }
    print(
        String(
            format: "settle     %d steps, t=%.1f Myr, %.1f s", settle,
            Double(solver.time) * Physics.megayearsPerTimeUnit,
            Date().timeIntervalSince(settleStart)))
    // Stars formed while settling are not the clip's, and would read as a burst on frame 0.
    previousTime = solver.time
}
let settleRun = scheduler?.stepsRun ?? settle

/// Past the planned frames, whether the story still wants more.
func storyGoesOn() -> Bool {
    guard let story, let last = story.samples.last, last.timeMyr < storyCap else { return false }
    guard let quiet = story.quietFrom else { return true }
    return last.timeMyr < story.samples[quiet].timeMyr + storyAfter
}

// `--dump-walk <dir> --dump-walk-frames 0,57:pericentre` (#271): at the end of the steps of each
// listed frame, every buffer the tracers' walk reads and Metal's answers on that state, for the
// CUDA spike (docs/notes/cuda-walk-spike.md). Moves nothing.
let walkDirectory = argument("dump-walk").map { URL(fileURLWithPath: $0, isDirectory: true) }
var walkDumps: [Int: String] = [:]
for entry in argument("dump-walk-frames")?.split(separator: ",") ?? [] {
    let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
    guard let index = Int(parts[0]), index >= 0 else { fail("--dump-walk-frames: no frame \"\(entry)\"") }
    walkDumps[index] = parts.count > 1 ? parts[1] : "frame \(index)"
}
if walkDirectory != nil || !walkDumps.isEmpty {
    guard walkDirectory != nil, !walkDumps.isEmpty else {
        fail("--dump-walk and --dump-walk-frames go together")
    }
    guard tracerSolver != nil else { fail("--dump-walk: no light tracers to dump (--massive)") }
}
let walkScene =
    scenePath.map { path -> String in
        let url = URL(fileURLWithPath: path)
        return url.lastPathComponent == "scene.json"
            ? url.deletingLastPathComponent().pathComponents.suffix(2).joined(separator: "/")
            : url.deletingPathExtension().lastPathComponent
    } ?? presetName
let walkCommit = walkDirectory.map { _ in TracerWalkDump.sourceCommit() } ?? ""

// `--dump-targets <dir> --dump-targets-frames 4:close` (#276): as `export --dump-targets`, of the
// frames this run draws itself, with the light tracers it draws. Moves nothing.
let targetDirectory = argument("dump-targets").map { URL(fileURLWithPath: $0, isDirectory: true) }
var targetDumps: [Int: String] = [:]
for entry in argument("dump-targets-frames")?.split(separator: ",") ?? [] {
    let parts = entry.split(separator: ":", maxSplits: 1).map(String.init)
    guard let index = Int(parts[0]), index >= 0 else {
        fail("--dump-targets-frames: no frame \"\(entry)\"")
    }
    targetDumps[index] = parts.count > 1 ? parts[1] : String(format: "frame-%05d", index)
}
guard (targetDirectory == nil) == targetDumps.isEmpty else {
    fail("--dump-targets and --dump-targets-frames go together")
}
let targetLookFile = "looks/\(look.name).look.json"
var targetManifest = try targetDirectory.map { directory -> RenderTargetManifest in
    let url = directory.appendingPathComponent(targetLookFile)
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try look.encoded().write(to: url)
    let visible = solver.particles.visibleCount
    let take = RenderTargetManifest.Take(
        file: "", scene: walkScene, particles: solver.particles.count,
        drawn: visible > 0 ? visible : solver.particles.count, capturedFrames: frames,
        capturedRate: Int(framesPerSecond))
    var held =
        RenderTargetManifest.read(from: directory).flatMap {
            $0.width == width && $0.height == height && $0.take.scene == take.scene ? $0 : nil
        }
        ?? RenderTargetManifest(
            commit: "", device: "", system: "", width: width, height: height, take: take)
    held.source = "Metal, sillage-render hires --dump-targets"
    held.commit = TracerWalkDump.sourceCommit()
    held.device = renderer.gpuName
    held.system = ProcessInfo.processInfo.operatingSystemVersionString
    held.take = take
    return held
}

let framesStart = Date()
let firstFrame = 0
var frame = firstFrame
while frame < frames || storyGoesOn() {
    defer { frame += 1 }
    let simulationStart = Date()
    let frameSteps = advance(stepsPerFrame, frame: frame)
    let simulationMs = Date().timeIntervalSince(simulationStart) * 1000
    if let formationLeaves, let barnesHut = gpuSolver as? MetalBarnesHutSolver {
        let line = barnesHut.formationLeaves().csvLine(
            frame: frame, timeMyr: Double(solver.time) * Physics.megayearsPerTimeUnit,
            stepMyr: Double(scene.timeStep) * Physics.megayearsPerTimeUnit)
        try formationLeaves.write(contentsOf: Data((line + "\n").utf8))
    }
    if let walkDirectory, let label = walkDumps[frame], let tracerSolver {
        guard let dump = tracerSolver.walkDump() else { fail("--dump-walk: frame \(frame) not captured") }
        let timeMyr = Double(solver.time) * Physics.megayearsPerTimeUnit
        let written = try dump.write(
            to: walkDirectory,
            run: TracerWalkDump.Run(
                scene: walkScene, label: label, frame: frame, step: settle + (frame + 1) * stepsPerFrame,
                timeMyr: timeMyr, dtScale: file.timeStepScale, commit: walkCommit,
                device: renderer.gpuName))
        print(String(format: "walk dump  frame %d (%@), t=%.2f Myr: %@", frame, label, timeMyr, written.path))
    }

    if gpuSolver == nil {
        renderer.upload(positions: solver.particles.positions)
    }
    if frozenRadius <= 0 && look.camera.mode != .auto {
        // Not `particles` with tracers, which would build every one of them as a particle.
        frozenRadius =
            tracerSolver.map { look.camera.framedRadius(sortedRadii: $0.radii(every: 16).sorted()) }
            ?? look.camera.framedRadius(positions: solver.particles.positions)
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
            strength: LookFile.diskStrength(look.armStrength, director?.look ?? look.look)))
    let camera: Camera
    if let director {
        // Advanced by one frame of playback rather than by wall clock, so the move reads the
        // same however long the frame took to compute.
        director.advance(
            seconds: 1 / Double(framesPerSecond),
            of: Subject(centres: scene.framedCentres(solver.centers), radius: frozenRadius))
        renderer.apply(director.look)
        camera = director.camera
    } else {
        var framed = (center: look.camera.center ?? .zero, radius: frozenRadius)
        if look.camera.mode == .auto {
            framed = autoCamera.frame(centres: scene.framedCentres(solver.centers), margins: reach)
            framed.radius /= zoom
        }
        camera = look.camera.camera(
            progress: Float(frame) / Float(max(frames - 1, 1)), radius: framed.radius,
            center: framed.center, fieldOfView: look.look.fieldOfView)
    }
    let renderStart = Date()
    // The video is drawn straight into the encoder's buffers; a still is read off the same
    // frame rather than drawn twice.
    let wantsStill = outputURL != nil || (thumbnailURL != nil && frame == thumbnailFrame)
    var still: CGImage?
    if let videoWriter {
        try videoWriter.append(
            on: renderer.device,
            drawing: { target, buffer in
                renderer.encode(camera: camera, into: buffer, present: target)
            },
            read: wantsStill ? { still = PNGWriter.image(bgra: $0) } : nil)
    } else if wantsStill {
        still = PNGWriter.image(renderer.render(camera: camera), width: width, height: height)
    }
    let renderMs = Date().timeIntervalSince(renderStart) * 1000
    if let targetDirectory, let name = targetDumps[frame] {
        if videoWriter == nil && !wantsStill { _ = renderer.render(camera: camera) }
        guard let targets = renderer.particleTargets() else {
            fail("--dump-targets: frame \(frame) not captured")
        }
        try targetManifest?.add(
            RenderTargetManifest.Capture(
                captured: Double(frame), time: solver.time, shot: nil, camera: camera,
                targets: targets),
            look: look.name, lookFile: targetLookFile, name: name,
            megayearsPerUnit: Physics.megayearsPerTimeUnit, to: targetDirectory)
        print(
            String(
                format: "targets    frame %d (%@), %d massive and %d tracers, look %@: %@", frame,
                name, targets.drawn, targets.tracers, look.name,
                targetDirectory.appendingPathComponent("targets/\(look.name)/\(name)").path))
    }
    if let outputURL {
        let url =
            frames == 1
            ? outputURL
            : outputURL.deletingPathExtension().appendingPathExtension(
                String(format: "%04d.png", frame))
        if let still { try PNGWriter.write(still, maximumWidth: nil, to: url) }
    }
    if let thumbnailURL, frame == thumbnailFrame {
        if let still { try PNGWriter.write(still, maximumWidth: 480, to: thumbnailURL) }
        print("thumbnail  \(thumbnailURL.path)")
    }

    if let massiveTake, let gpuSolver {
        massiveTake.offer(
            positions: gpuSolver.positions.contents().bindMemory(
                to: SIMD3<Float>.self, capacity: heldCount) + tracerCount,
            time: solver.time, centers: solver.centers,
            disks: (gpuSolver as? MetalBarnesHutSolver)?.diskFrames ?? [], budget: takeBudget)
    }
    func offer(_ reel: Recording) {
        if let gpuSolver {
            reel.offer(
                positions: gpuSolver.positions.contents().bindMemory(
                    to: SIMD3<Float>.self, capacity: heldCount),
                time: solver.time, centers: solver.centers,
                disks: (gpuSolver as? MetalBarnesHutSolver)?.diskFrames ?? [], budget: takeBudget)
        } else {
            solver.particles.positions.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                reel.offer(
                    positions: base, time: solver.time, centers: solver.centers,
                    budget: takeBudget)
            }
        }
    }
    if let take {
        let takeStart = Date()
        offer(take)
        takeSeconds += Date().timeIntervalSince(takeStart)
    }
    if let takeV6 { offer(takeV6) }

    if density?.wants(frame: frame) == true {
        if let gpuSolver {
            let positions = gpuSolver.positions.contents().bindMemory(
                to: SIMD3<Float>.self, capacity: heldCount)
            density?.add(positions, count: drawnCount)
            if tracerCount > 0 {
                tracerDensity?.add(positions, count: tracerCount)
                massiveDensity?.add(positions + tracerCount, count: massiveDrawn)
                // Whether the light leaves the mass: the share in tails and bridges, and the
                // spread, of each set alike.
                let centres = solver.centers
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
                let disks = tracerSolver?.diskFrames ?? []
                func heights(_ range: Range<Int>) -> [Double] {
                    var sums = [Double](repeating: 0, count: disks.count)
                    var counted = [Int](repeating: 0, count: disks.count)
                    for index in stride(from: range.lowerBound, to: range.upperBound, by: 16) {
                        let word = index < tracerCount ? tracerSolver?.tracerWord(index) : nil
                        let galaxy = Int(word?.galaxy ?? seeded.galaxyIndex[index - tracerCount])
                        let kind = word?.component ?? seeded.component[index - tracerCount]
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
        } else {
            solver.particles.positions.withUnsafeBufferPointer { buffer in
                if let base = buffer.baseAddress { density?.add(base, count: drawnCount) }
            }
        }
    }

    if let curves {
        let curvesStart = Date()
        let centres = solver.centers
        let separation =
            centres.count >= 2 ? simd_length(centres[1] - centres[0]) : Float(0)
        var closest = Float.infinity
        for i in centres.indices {
            for j in centres.indices where j > i {
                closest = min(closest, simd_length(centres[j] - centres[i]))
            }
        }
        if !closest.isFinite { closest = 0 }
        var sum: Float = 0
        var counted = 0
        var tidal = 0
        func tally(_ position: SIMD3<Float>) {
            sum += simd_length_squared(position)
            counted += 1
            for (centre, limit) in zip(centres, tidalReach)
            where simd_length_squared(position - centre) < limit * limit {
                return
            }
            tidal += 1
        }
        // Root mean square radius over a subsample: a smooth measure of how far the thing has
        // spread, for a fraction of the cost of sorting every radius. Read straight out of the
        // position buffer: `particles` on a GPU solver rebuilds the whole system on every
        // access, and calling it once per sample made each frame nine seconds slower.
        if let gpuSolver {
            let positions = gpuSolver.positions.contents().bindMemory(
                to: SIMD3<Float>.self, capacity: heldCount)
            for index in stride(from: 0, to: drawnCount, by: 64) { tally(positions[index]) }
        } else {
            let positions = solver.particles.positions
            for index in stride(from: 0, to: drawnCount, by: 64) { tally(positions[index]) }
        }
        let extent = counted > 0 ? (sum / Float(counted)).squareRoot() : 0
        let tidalFraction = counted > 0 ? Float(tidal) / Float(counted) : 0
        let states = (gpuSolver as? MetalBarnesHutSolver)?.diskFrames ?? []
        let disks = scene.galaxies.indices.map {
            String(format: ",%.3f", $0 < states.count ? states[$0].disruption : 0)
        }.joined()
        let torn = scene.galaxies.indices.map {
            String(format: ",%.3f", $0 < states.count ? states[$0].torn : 0)
        }.joined()
        // From the frame's start, the time its first step's knots carry, to just before now:
        // counted from just after the start, that step never showed (#306).
        let formed =
            (gpuSolver as? MetalBarnesHutSolver)?.formed(since: previousTime, before: solver.time) ?? 0
        let myr = Double(solver.time) * Physics.megayearsPerTimeUnit
        let track = centres.map { String(format: ",%.4f,%.4f,%.4f", $0.x, $0.y, $0.z) }.joined()
        let line =
            String(
                format: "%d,%.3f,%.4f,%.4f,%d,%.4f,%.4f", frame, myr, separation, extent, formed,
                closest, tidalFraction) + disks + track + torn + "\n"
        try curves.write(contentsOf: Data(line.utf8))
        if let sample = Story.samples(csv: curvesHeader + line).first { story?.append(sample) }
        curvesSeconds += Date().timeIntervalSince(curvesStart)
    }
    previousTime = solver.time

    if frame < frames {
        let (done, left) = runSteps(ownDone: settle + (frame + 1) * stepsPerFrame)
        var framesDone = Double(frame + 1 - firstFrame) / Double(max(frames - firstFrame, 1))
        if scheduler != nil {
            framesDone = Double(done - settleRun) / Double(max(done - settleRun + left, 1))
        }
        reporter?.update(
            progress: Double(done) / Double(max(done + left, 1)),
            detail: "frame \(frame + 1)/\(frames)",
            eta: RunStatus.eta(
                elapsed: Date().timeIntervalSince(framesStart), progress: framesDone, now: Date()))
    } else {
        // How long a story still has is not known until it ends.
        reporter?.update(
            progress: 0.99,
            detail: String(
                format: "frame %d, story going on at %.0f Myr", frame + 1,
                Double(solver.time) * Physics.megayearsPerTimeUnit))
    }

    if let profiled {
        let profile = profiled.takeProfile()
        let phases = StepProfile.phases.compactMap { phase -> String? in
            let value = profile.perStep(phase)
            return value > 0 ? String(format: "%@ %.2f", phase, value) : nil
        }
        print("profile    " + phases.joined(separator: ", "))
    }
    print(
        String(
            format:
                "frame %04d  t=%.1f Myr  sim %7.1f ms (%.3f ms/step)  smoothing %6.1f ms"
                + "  render %5.1f ms (gpu %5.2f)",
            frame, Double(solver.time) * Physics.megayearsPerTimeUnit, simulationMs,
            simulationMs / Double(frameSteps), smoothingMs, renderMs,
            (videoWriter?.lastGPUTime ?? renderer.lastGPUTime) * 1000))
}

reporter?.update(progress: 1, detail: "finishing", eta: Date())
try videoWriter?.finish()
try curves?.close()
// `--state-out <path>`: what a checkpoint keeps of the particles at the end, and the solver's
// state beside it as `<path>.json`, to compare two runs to the bit.
if let path = argument("state-out"), let barnesHut = gpuSolver as? MetalBarnesHutSolver {
    let url = try prepared(path)
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    try barnesHut.writeParticles(to: handle)
    try handle.close()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(barnesHut.state).write(to: url.appendingPathExtension("json"))
    print("state      \(url.path)")
}
if let story, let span = story.span(plannedFrames: frames) {
    print(
        String(
            format: "story      %.0f to %.0f Myr (frames %d to %d of %d), %@", span.startMyr,
            span.endMyr, span.startFrame, span.endFrame, frame,
            span.complete
                ? "over"
                : "still going at the cap: "
                    + story.activity.map(\.description).joined(separator: "; ")))
    // The clip as it ran, so a rerun and every later stage see the same stretch of time.
    if let folder = exploreRun {
        var clip = try folder.storedClip()
        clip.frames = frame
        clip.steps = frame * stepsPerFrame
        clip.story = span
        try clip.encoded().write(to: folder.clip)
    }
}
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
if curves != nil {
    print(
        String(
            format: "curves     %.1f ms in all, %.3f ms a frame", curvesSeconds * 1000,
            curvesSeconds * 1000 / Double(max(frames, 1))))
}
if let take, let path = argument("take") {
    if let failure = take.spillFailure { print("take       held in memory: \(failure)") }
    print(
        String(
            format: "take       %.1f ms a frame quantising, %d bits an axis",
            takeSeconds * 1000 / Double(max(take.capturedCount, 1)), take.bitsPerAxis))
    let captured =
        tracerSolver?.drawnAttributes() ?? gpuSolver?.capturedParticles(from: seeded) ?? seeded
    try RecordingFile.write(take, scene: drawnScene, particles: captured, to: prepared(path))
}
if let takeV6, let path = argument("take-v6") {
    let captured =
        tracerSolver?.drawnAttributes() ?? gpuSolver?.capturedParticles(from: seeded) ?? seeded
    try RecordingFile.write(takeV6, scene: drawnScene, particles: captured, to: prepared(path))
}
if let massiveTake, let path = argument("take-massive") {
    let captured = gpuSolver?.capturedParticles(from: seeded) ?? seeded
    try RecordingFile.write(massiveTake, scene: scene, particles: captured, to: prepared(path))
}
if let (folder, done) = hiresRun {
    do {
        try folder.commitHires()
    } catch {
        fail("hires: could not put the take in place: \(error)")
    }
    var record = done
    record.seconds = Date().timeIntervalSince(started)
    if let scheduler {
        record.stepsRun = scheduler.stepsRun
        record.stepSwitches = scheduler.switches
        print("schedule   \(scheduler.stepsRun) steps run for \(scheduler.ownSteps) of the run's own")
    }
    record.peakMemoryBytes = peakFootprint()
    record.takeBytes =
        (try? FileManager.default.attributesOfItem(atPath: folder.take.path)[.size] as? Int)
        ?? nil
    try record.encoded().write(to: folder.hires)
    print(
        String(
            format: "hires      %.0f s, peak %.2f GB, take %.2f GB", record.seconds ?? 0,
            Double(record.peakMemoryBytes ?? 0) / 1e9, Double(record.takeBytes ?? 0) / 1e9))
    var finished = RunEvent(RunEvent.Kind.hiresDone)
    finished.particles = record.particles
    finished.massive = record.massive
    finished.steps = record.steps
    finished.minutes = (record.seconds ?? 0) / 60
    finished.takeGB = Double(record.takeBytes ?? 0) / 1e9
    finished.pass = record.pass?.rawValue
    reporter?.record(finished)
}
reporter?.finish()
if let (folder, _) = hiresRun { refreshCosts(folder) }
if let exploreRun { refreshCosts(exploreRun) }

print(String(format: "done in %.1f s", Date().timeIntervalSince(clock)))
