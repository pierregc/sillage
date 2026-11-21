import Foundation
import SillageCore
import SillageRender

/// `sillage-cuda explore <scene folder>` (#430): a scene's preview, run through `TakePassRun` as
/// `sillage-render explore` runs it on the Mac, from the same options. The folder it leaves is the
/// Mac's: `clip.json` with the story the run followed, `scene.json`, `look.json`, `preview.mov`,
/// `curves.csv` and `thumbnail.png`, so `hires` can follow here or on the Mac. A generated scene
/// that would show nothing is `.rejected`, as on the Mac.
public enum CUDAExplore {
    public static func run(
        _ folder: SceneFolder, options: [String], context: CUDAContext,
        threads: Int = ProcessInfo.processInfo.activeProcessorCount,
        checkRecord: URL = CUDAEngineCheck.defaultRecord, started: Date = Date()
    ) throws -> TakePassRun.Outcome {
        let arguments = try folder.explorePlan(options)
        let reporter = StageReporter(stage: SceneFolder.Stage.explore.rawValue, folder: folder)
        reporter.start(detail: "starting")
        print("explore    \(folder.url.path) on \(CUDAEngineCheck.engine)")
        let outcome: TakePassRun.Outcome
        do {
            outcome = try TakePassRun(
                arguments: arguments,
                engine: CUDATakePassMaker(context: context, threads: threads, checkRecord: checkRecord),
                started: started, reporter: reporter, explore: folder
            ).run()
        } catch {
            var event = RunEvent(RunEvent.Kind.error)
            event.stage = reporter.stage
            event.message = "\(error)"
            reporter.record(event)
            reporter.finish()
            throw error
        }
        reporter.finish()
        return outcome
    }
}
