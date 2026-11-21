import Foundation
import SillageCore
import SillageRender

/// `sillage-cuda hires <scene folder>` (#278, #378): the pass that writes the take, one pass of
/// every particle or `--pass massive`, through `TakePassRun`, or `--pass full` through
/// `FullPassRun`, on the GPU library or the CPU target, as `sillage-render hires` runs them on
/// the Mac. The folder it leaves is the Mac's: `take.sillage`, `curves-hires.csv`, `hires.mov`,
/// `hires.json` and `massive.bin`, or the full pass's videos and key frames. Both refuse an
/// engine whose check did not pass for this build.
public enum CUDAHires {
    /// Runs the pass `options` ask for on `folder`. `stop`, for tests, stops a take pass where a
    /// kill would (`TakePassRun.stop`), and a full pass after a frame.
    public static func run(
        _ folder: SceneFolder, options: [String], context: CUDAContext,
        threads: Int = ProcessInfo.processInfo.activeProcessorCount,
        checkRecord: URL = CUDAEngineCheck.defaultRecord, maximumParticles: Int? = nil,
        started: Date = Date(), stop: ((_ frame: Int?, _ checkpoints: Int) -> Bool)? = nil
    ) throws {
        let maximum =
            maximumParticles
            ?? ProcessInfo.processInfo.environment[SceneFolder.maximumParticlesVariable].flatMap(Double.init)
            .map(Int.init) ?? 2_000_000_000
        let full = SceneFolder.pass(in: options) == "full"
        let plan = try folder.hiresArguments(options, maximumParticles: maximum)
        let record = plan.record
        let reporter = StageReporter(stage: "hires", folder: folder)
        let pass = full ? "full" : record.pass?.rawValue
        reporter.start(detail: full ? "full pass, starting" : "starting")
        var begun = RunEvent(RunEvent.Kind.hiresStart)
        begun.particles = record.particles
        begun.massive = record.massive
        begun.steps = record.steps
        begun.pass = pass
        reporter.record(begun)
        print(
            String(
                format:
                    "hires      %d particles%@, step %.5f Myr, settle %d, %d steps, %d frames, clip %.1f to"
                    + " %.1f Myr, %@ on %@",
                record.particles, record.massive.map { " from \($0) massive" } ?? "", record.timeStepMyr,
                record.settle, record.steps, record.frames, record.clipStartMyr, record.clipEndMyr,
                full ? "full pass" : record.pass == .massive ? "massive pass" : "one pass",
                CUDAEngineCheck.engine))
        if let schedule = record.stepSchedule, !full {
            print(
                "schedule   \(schedule), \(record.stepsToRun) steps planned for \(record.settle + record.steps)"
            )
        }
        do {
            if full {
                let run = FullPassRun(
                    arguments: plan.arguments,
                    engine: CUDAFullPassMaker(context: context, threads: threads, checkRecord: checkRecord),
                    started: started, reporter: reporter, hires: (folder, record))
                run.stop = stop.map { stop in { frame, checkpoints in stop(frame, checkpoints) } }
                try run.run()
                print(String(format: "done in %.1f s", Date().timeIntervalSince(started)))
            } else {
                let run = TakePassRun(
                    arguments: plan.arguments,
                    engine: CUDATakePassMaker(context: context, threads: threads, checkRecord: checkRecord),
                    started: started, reporter: reporter, hires: (folder, record))
                run.stop = stop
                _ = try run.run()
            }
        } catch {
            var event = RunEvent(RunEvent.Kind.error)
            event.stage = reporter.stage
            event.message = "\(error)"
            reporter.record(event)
            reporter.finish()
            throw error
        }
        reporter.finish()
    }
}
