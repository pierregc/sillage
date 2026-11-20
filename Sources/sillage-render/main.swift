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

// Any other run writes a take, or a plain render: one flow on every engine (#376), with Metal's
// measuring options beside it.
let takePass = TakePassRun(
    arguments: arguments, engine: MetalTakePassMaker(), measures: MetalMeasures(), started: started,
    reporter: reporter, hires: hiresRun, explore: exploreRun)
do {
    switch try takePass.run() {
    case .done:
        break
    case .checked:
        exit(0)
    case .rejected:
        reporter?.finish()
        exit(3)
    }
} catch {
    fail("\(error)")
}
reporter?.finish()
if let (folder, _) = hiresRun { refreshCosts(folder) }
if let exploreRun { refreshCosts(exploreRun) }
