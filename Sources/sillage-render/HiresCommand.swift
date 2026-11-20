import CoreGraphics
import Foundation
import SillageCore
import SillageRender
import simd

/// Every scene of a batch marked yes, one after another, each in a process of its own: at these
/// sizes one scene fills the GPU. A scene already done at the same size is skipped, so an
/// interrupted batch picks up where it stopped.
func hiresBatch(_ batch: URL, options: [String]) -> Int32 {
    let scenes = SceneFolder.chosen(inBatch: batch)
    guard !scenes.isEmpty else {
        fail("hires: \(batch.path) is neither a scene folder nor a batch with scenes marked yes")
    }
    let maximum = SceneFolder.maximumParticles()
    var failed = 0
    for (index, scene) in scenes.enumerated() {
        let name = scene.url.lastPathComponent
        if scene.hiresDone(options, maximumParticles: maximum) {
            print("hires      \(index + 1)/\(scenes.count) \(name): done already")
            continue
        }
        print("hires      \(index + 1)/\(scenes.count) \(name)")
        let process = Process()
        process.executableURL = Bundle.main.executableURL
        process.arguments = ["hires", scene.url.path] + options
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            print("hires      \(name) did not start: \(error)")
        }
        if process.terminationStatus != 0 {
            failed += 1
            print("hires      \(name) failed with status \(process.terminationStatus)")
            var event = RunEvent(RunEvent.Kind.error, scene: name)
            event.stage = "hires"
            event.message = "failed with status \(process.terminationStatus)"
            try? RunStatusFiles.append(event, to: RunStatusFiles.events(batch: batch))
        }
    }
    print("hires      \(scenes.count - failed) of \(scenes.count) scenes")
    return failed == 0 ? 0 : 1
}
