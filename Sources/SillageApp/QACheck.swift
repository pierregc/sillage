import AppKit
import Foundation
import SillageCore
import SillageRender
import simd

/// Drives the whole run flow with the window up and reports what held and what did not.
///
/// The window cannot be looked at on this machine, so every claim about the interface has to
/// come from somewhere. This walks the states a user walks: set up a scene, launch it, watch
/// it capture, stop it, replay it, scrub it, pick it back up, start over.
enum QACheck {
    private struct Result {
        var name: String
        var passed: Bool
        var detail: String
    }

    @MainActor
    private final class Report {
        private var results: [Result] = []

        func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            results.append(Result(name: name, passed: passed, detail: detail))
        }

        var failures: Int { results.filter { !$0.passed }.count }

        func rendered() -> String {
            var lines: [String] = []
            for r in results {
                let mark = r.passed ? "ok  " : "FAIL"
                let name =
                    r.name.count >= 44
                    ? r.name
                    : r.name + String(repeating: " ", count: 44 - r.name.count)
                lines.append("\(mark) \(name)\(r.detail)")
            }
            lines.append("")
            lines.append("\(results.count - failures) / \(results.count) checks passed")
            return lines.joined(separator: "\n")
        }
    }

    @MainActor
    static func run(_ model: SimulationModel) {
        guard CommandLine.arguments.contains("--qa") else { return }
        Task {
            let report = Report()

            /// Lets the run advance while the canvas keeps drawing, the way a window does.
            @MainActor func settle(_ seconds: Double) async {
                let until = Date().addingTimeInterval(seconds)
                while Date() < until {
                    model.drawOnce()
                    try? await Task.sleep(for: .milliseconds(16))
                }
            }

            try? await Task.sleep(for: .seconds(1))

            // A scene small enough to walk the whole flow quickly, on the cheap solver.
            model.draft.solver = .restricted
            model.draft.retune()
            model.setTotalParticles(200_000)
            model.commitDraftChange()
            // The preview resamples off the main actor now.
            await settle(1.0)

            let previewLit = (model.previewSnapshot() ?? []).filter { $0 > 8 }.count
            report.check("the setup preview draws", previewLit > 10_000, "\(previewLit) samples")

            // The setup screen's own contract, before anything is launched.
            let galaxiesBefore = model.draft.galaxies.count
            model.addGalaxy()
            model.commitDraftChange()
            report.check(
                "adding a galaxy", model.draft.galaxies.count == galaxiesBefore + 1,
                "\(model.draft.galaxies.count) galaxies")
            await settle(1.0)
            report.check("the preview follows the addition", model.previewParticleCount > 0)
            model.removeGalaxy(at: model.draft.galaxies.count - 1)
            model.commitDraftChange()
            report.check("removing a galaxy", model.draft.galaxies.count == galaxiesBefore)

            model.setTotalParticles(120_000)
            model.commitDraftChange()
            report.check(
                "the star count is set",
                abs(model.draft.totalParticleCount - 120_000) < 2_000,
                "\(model.draft.totalParticleCount)")

            // Softening and step are derived, and the two solvers need values orders of
            // magnitude apart, so switching has to retune rather than carry the old ones.
            model.draft.solver = .barnesHut
            model.commitDraftChange()
            let selfGravitatingStep = model.draft.timeStep
            model.draft.solver = .restricted
            model.commitDraftChange()
            report.check(
                "changing gravity retunes the step",
                model.draft.timeStep > selfGravitatingStep,
                String(format: "%.4f then %.4f", selfGravitatingStep, model.draft.timeStep))

            // From the tuned step itself, which the opening scene already multiplies.
            model.draft.timeStepScale = 1
            model.commitDraftChange()
            let tunedStep = model.draft.timeStep
            model.draft.timeStepScale = 8
            model.commitDraftChange()
            report.check(
                "the time warp multiplies the step",
                abs(model.draft.timeStep - tunedStep * 8) < tunedStep * 0.01,
                String(format: "x%.1f", model.draft.timeStep / tunedStep))
            model.draft.timeStepScale = 1
            model.setTotalParticles(200_000)
            model.commitDraftChange()
            await settle(1.0)

            // Launch.
            model.start()
            report.check("launching switches at once", model.stage == .running)
            report.check("launching announces its preparation", model.isPreparing)
            await settle(2.0)
            report.check("the preparation ends", !model.isPreparing)
            report.check("launching goes into simulation", model.mode == .running)
            report.check("launching starts playing", model.isPlaying)
            let framesAtLaunch = model.framesDrawn
            await settle(1.5)
            report.check(
                "the canvas draws", model.framesDrawn > framesAtLaunch + 10,
                "\(model.framesDrawn - framesAtLaunch) frames")
            report.check(
                "time moves on", model.elapsedMyr > 0,
                String(format: "%.1f Myr", model.elapsedMyr))
            report.check(
                "the take starts by itself", model.capturedFrames > 2,
                "\(model.capturedFrames) frames")
            report.check(
                "the take uses memory", model.capturedBytes > 0,
                String(format: "%.1f MB", model.capturedMegabytes))
            report.check("no error", model.failure == nil, model.failure ?? "")

            // Pause holds the clock.
            model.isPlaying = false
            await settle(0.6)
            let held = model.elapsedMyr
            await settle(0.6)
            report.check("pause stops the computation", abs(model.elapsedMyr - held) < 1e-9)
            model.isPlaying = true
            await settle(0.8)
            report.check("resume starts again", model.elapsedMyr > held)

            // Stop and replay.
            let capturedBeforeReplay = model.capturedFrames
            report.check("playback is offered", model.canReplay)
            model.stopAndReplay()
            report.check("stop switches to playback", model.mode == .playback)
            await settle(1.0)
            report.check(
                "playback moves on", model.playbackPosition > 0,
                String(format: "position %.1f", model.playbackPosition))
            // The clock follows the frame on screen during playback, which is what it should
            // show; what must stop is the computing behind it.
            let framesWhenStopped = model.capturedFrames
            await settle(0.8)
            report.check(
                "playback no longer computes",
                model.capturedFrames == framesWhenStopped,
                "\(model.capturedFrames) frames")

            // Scrubbing anywhere must be safe, ends included.
            for position in [0.0, Double(capturedBeforeReplay - 1), Double(capturedBeforeReplay) * 0.5] {
                model.playbackPosition = position
                model.drawOnce()
            }
            report.check("scrubbing holds at the ends", model.failure == nil)

            // Pick the run back up.
            model.resumeRunning()
            report.check("resume goes back to simulation", model.mode == .running)
            await settle(1.0)
            report.check(
                "the take picks up where it was",
                model.capturedFrames > capturedBeforeReplay,
                "\(capturedBeforeReplay) then \(model.capturedFrames)")

            // A fresh capture keeps the run but drops the frames.
            let timeBeforeNewTake = model.elapsedMyr
            model.restartCapture()
            report.check(
                "a new take starts from zero", model.capturedFrames == 1,
                "\(model.capturedFrames) frame")
            report.check(
                "a new take keeps the computation",
                abs(model.elapsedMyr - timeBeforeNewTake) < 5,
                String(format: "%.1f then %.1f Myr", timeBeforeNewTake, model.elapsedMyr))
            await settle(0.8)
            report.check("the new take fills up", model.capturedFrames > 2)

            // Restart winds the clock back. It picks straight back up, so the test is that
            // the clock fell, not that it is standing at zero by the time anyone looks.
            let clockBeforeRestart = model.elapsedMyr
            model.restart()
            await settle(0.5)
            report.check(
                "restart sets time back to zero",
                model.elapsedMyr < clockBeforeRestart / 2,
                String(format: "%.0f then %.0f Myr", clockBeforeRestart, model.elapsedMyr))
            report.check("restart begins a fresh take", model.capturedFrames >= 1)

            // The memory budget stops the capture without stopping the run.
            model.memoryBudgetGigabytes = 0.5
            model.restartCapture()
            await settle(2.5)
            let framesAtCap = model.capturedFrames
            let timeAtCap = model.elapsedMyr
            let spanAtCap = model.capturedMyr
            // Wait for the budget to actually bind rather than trusting a fixed pause to be
            // long enough. It landed at 480 MB of 512 often enough that the three checks
            // below quietly vanished and the run still reported everything green — a check
            // that disappears is worse than one that fails, so the fill is now part of the
            // first check and the rest are unconditional.
            // The cadence before the budget binds, which is the thing that must not change.
            let cadenceAtCap =
                framesAtCap > 1 ? spanAtCap / Double(framesAtCap - 1) : 0
            var waitedForFull = 0.0
            while !model.captureSpilling && waitedForFull < 15 {
                await settle(0.5)
                waitedForFull += 0.5
            }
            report.check(
                "the budget bounds the take's memory",
                model.captureSpilling && model.captureMemoryMegabytes < 600,
                String(
                    format: "%.0f MB in memory, %.0f MB on disk",
                    model.captureMemoryMegabytes, Double(model.captureDiskBytes) / 1_048_576))
            report.check(
                "the computation goes on past the budget", model.elapsedMyr > timeAtCap,
                "\(framesAtCap) frames when full")
            report.check(
                "the full take still covers the whole span",
                model.capturedMyr > spanAtCap,
                String(format: "%.0f then %.0f Myr", spanAtCap, model.capturedMyr))
            // The whole point of the scratch file: past the budget the take keeps every frame
            // at the cadence it was taking them. Thinning doubled this and it must not move.
            let cadenceNow =
                model.capturedFrames > 1
                ? model.capturedMyr / Double(model.capturedFrames - 1) : 0
            report.check(
                "the take does not thin out",
                cadenceAtCap > 0 && cadenceNow < cadenceAtCap * 1.3,
                String(format: "%.3f then %.3f Myr between frames", cadenceAtCap, cadenceNow))
            report.check(
                "frames moved to disk read back",
                model.recordedPositionsAreReadable(at: model.capturedFrames - 1),
                "last frame read back from the spill file")
            await settle(0.2)
            model.memoryBudgetGigabytes = 4

            // Rendering settings must survive both states.
            model.supersample = 2
            await settle(0.4)
            report.check("supersampling holds in simulation", model.failure == nil)
            model.stopAndReplay()
            await settle(0.4)
            model.supersample = 1
            await settle(0.4)
            report.check("supersampling holds in playback", model.failure == nil)

            // Back to the setup screen and out again.
            model.returnToSetup()
            report.check("back to setup leaves the simulation", model.stage == .setup)
            report.check("back to setup empties the take", model.capturedFrames == 0)
            model.rebuildPreview()
            report.check("the preview comes back", (model.previewSnapshot() ?? []).contains { $0 > 8 })
            model.start()
            await settle(2.0)
            report.check(
                "a second launch starts again", model.isPlaying && model.elapsedMyr > 0,
                String(format: "%.1f Myr", model.elapsedMyr))
            report.check("a second launch captures", model.capturedFrames > 1)
            report.check("nothing failed on the way", model.failure == nil, model.failure ?? "")

            // Restarting out of playback has to land back in a running scene, not leave the
            // canvas bound to a recording that no longer matches the solver.
            model.stopAndReplay()
            report.check("stop switches to playback (2)", model.mode == .playback)
            model.restart()
            await settle(0.6)
            report.check(
                "restart from playback goes back to simulation",
                model.mode == .running && model.capturedFrames > 1)

            // Switching the picture off has to actually stop the drawing, not just hide it.
            let beforeHiding = model.framesDrawn
            model.showCanvasWhileRunning = false
            await settle(1.2)
            report.check(
                "switching the picture off stops drawing", model.framesDrawn == beforeHiding,
                "\(model.framesDrawn - beforeHiding) images")
            report.check("the computation goes on without a picture", model.elapsedMyr > 0)
            model.showCanvasWhileRunning = true
            await settle(0.8)
            report.check("showing it again redraws", model.framesDrawn > beforeHiding)

            // A run left overnight has to stop by itself and write itself out. Nothing here
            // touches a button after the finish is armed.
            model.restartCapture()
            await settle(0.6)
            let finishURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("finished.sillage")
            try? FileManager.default.removeItem(at: finishURL)
            model.stopAtMyr = model.elapsedMyr + 30
            model.saveWhenFinished(to: finishURL)
            report.check("the finish is armed", model.finishDestination != nil)

            var waited = 0.0
            while !model.reachedFinish, waited < 25 {
                await settle(0.5)
                waited += 0.5
            }
            report.check(
                "the run stops by itself", model.reachedFinish,
                String(format: "%.0f Myr for a finish at %.0f", model.elapsedMyr, model.stopAtMyr))
            report.check("stop switches to playback", model.mode == .playback)
            while model.fileActivity != nil { await settle(0.3) }
            let written = (try? FileManager.default.attributesOfItem(atPath: finishURL.path)[.size])
            report.check(
                "it writes itself", (written as? Int ?? 0) > 1000,
                String(format: "%.1f MB", Double(written as? Int ?? 0) / 1_048_576))
            report.check("the destination is used up", model.finishDestination == nil)
            // The clock follows the frame on screen once it is replaying, which is right. What
            // must have stopped is the computing behind it.
            let framesAfterFinish = model.capturedFrames
            await settle(1.5)
            report.check(
                "nothing computes after the finish",
                model.capturedFrames == framesAfterFinish, "\(model.capturedFrames) frames")
            try? FileManager.default.removeItem(at: finishURL)

            model.stopAtMyr = 0
            model.resumeRunning()
            await settle(0.8)

            // A take on disk has to come back as the run, not as a video: the same frames,
            // and every setting that decides the image still live.
            let takeURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("qa.sillage")
            try? FileManager.default.removeItem(at: takeURL)
            model.stopAndReplay()
            let savedFrames = model.capturedFrames
            let savedParticles = model.particleCount
            model.saveTake(to: takeURL)
            while model.fileActivity != nil { await settle(0.2) }
            let size = (try? FileManager.default.attributesOfItem(atPath: takeURL.path)[.size])
            report.check(
                "the take is written to disk", (size as? Int ?? 0) > 1000,
                String(format: "%.1f MB", Double(size as? Int ?? 0) / 1_048_576))

            model.returnToSetup()
            model.openTake(from: takeURL)
            while model.fileActivity != nil { await settle(0.2) }
            await settle(1.0)
            report.check("the take reopens in playback", model.mode == .playback)
            report.check(
                "the reopened take has its frames", model.capturedFrames == savedFrames,
                "\(savedFrames) then \(model.capturedFrames)")
            report.check(
                "the reopened take has its particles", model.particleCount == savedParticles)
            report.check("the reopened take knows it has no solver", model.isOpenedTake)
            let opened = model.previewSnapshot()
            report.check("the reopened take draws", model.framesDrawn > 0 && opened != nil)
            await settle(1.0)
            report.check(
                "the reopened take plays", model.playbackPosition > 0,
                String(format: "position %.1f", model.playbackPosition))
            // The whole point of a file rather than a video: the look is still live.
            model.look.brightness = 0.4
            model.look.galaxyTint = 0.9
            model.drawOnce()
            report.check("image settings stay live", model.failure == nil)
            report.check(
                "resuming the computation is refused on an opened take",
                {
                    model.resumeRunning()
                    return model.mode == .playback
                }())
            // A video leaves through the queue, from a scene folder: a loose take offers none,
            // its scene's take does.
            report.check("a take outside a scene does not offer Video…", model.takeFolder == nil)
            let sceneURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("qa-\(UUID().uuidString)/scene-0001", isDirectory: true)
            let folder = SceneFolder(sceneURL)
            try? FileManager.default.createDirectory(at: sceneURL, withIntermediateDirectories: true)
            try? Data("{}".utf8).write(to: folder.scene)
            try? FileManager.default.copyItem(at: takeURL, to: folder.take)
            model.openTake(from: folder.take)
            while model.fileActivity != nil { await settle(0.2) }
            report.check(
                "a scene's take offers Video… on its scene",
                model.isOpenedTake && model.takeFolder == folder, model.takeFolder?.sceneID ?? "none")
            try? FileManager.default.removeItem(at: sceneURL.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: takeURL)

            model.returnToSetup()
            model.draft.solver = .restricted
            model.draft.retune()
            model.setTotalParticles(200_000)
            model.commitDraftChange()
            model.start()
            await settle(2.0)

            // Leaving mid-launch has to retire the sampling job rather than let it land on
            // an empty setup screen.
            model.returnToSetup()
            model.setTotalParticles(2_000_000)
            model.start()
            report.check("a big launch prepares in the background", model.isPreparing)
            model.returnToSetup()
            report.check("leaving during the preparation cancels it", !model.isPreparing)
            await settle(3.0)
            report.check(
                "the cancelled preparation does not come back",
                model.stage == .setup && !model.isPlaying)
            model.setTotalParticles(200_000)
            model.commitDraftChange()

            // The default solver is the slow one, so it gets its own pass.
            model.returnToSetup()
            model.draft.solver = .barnesHut
            model.draft.retune()
            model.setTotalParticles(60_000)
            model.commitDraftChange()
            model.start()
            await settle(4.0)
            report.check(
                "self-gravity moves on", model.elapsedMyr > 0,
                String(format: "%.2f Myr", model.elapsedMyr))
            report.check(
                "self-gravity captures", model.capturedFrames > 1,
                "\(model.capturedFrames) frames")
            report.check("self-gravity still draws", model.framesDrawn > 0)

            // Free flight, driven through the canvas the way the keyboard drives it. The
            // camera maths has its own tests; what is checked here is the wiring from a held
            // key to a moved eye, which those cannot see.
            let orbitEye = model.activeCamera.eye
            model.toggleFlight()
            report.check("free flight engages", model.isFlying)
            report.check(
                "switching to free flight does not move the eye",
                simd_length(model.activeCamera.eye - orbitEye) < 0.01)

            let restingEye = model.activeCamera.eye
            let aim = model.flight.forward
            model.hold(key: CanvasView.Key.w, true)
            await settle(0.6)
            model.hold(key: CanvasView.Key.w, false)
            let flown = model.activeCamera.eye - restingEye
            report.check(
                "a held key moves the camera forward", simd_length(flown) > 1,
                String(format: "%.0f kpc", simd_length(flown)))
            report.check(
                "it moves where the camera looks",
                simd_length(flown) > 0 && simd_length(simd_normalize(flown) - aim) < 0.01)

            let coasting = model.activeCamera.eye
            await settle(1.2)
            let stopped = model.activeCamera.eye
            report.check(
                "letting go lets the camera stop smoothly",
                simd_length(stopped - coasting) > 0.001)
            await settle(0.5)
            report.check(
                "then it comes to rest",
                simd_length(model.activeCamera.eye - stopped) < 0.5)

            model.toggleFlight()
            report.check("back to orbit is smooth", !model.isFlying)

            report.check(
                "self-gravity reports its rate", model.megayearsPerSecond > 0,
                String(format: "%.2f Myr/s", model.megayearsPerSecond))
            if model.canReplay {
                model.stopAndReplay()
                await settle(0.6)
                report.check(
                    "self-gravity plays back",
                    model.mode == .playback
                        && model.playbackPosition > 0)
            }
            report.check("no error in self-gravity", model.failure == nil, model.failure ?? "")

            let text = report.rendered()
            try? text.write(
                to: URL(fileURLWithPath: "/tmp/sillage-qa.log"), atomically: true, encoding: .utf8)
            print(text)
            exit(report.failures == 0 ? 0 : 1)
        }
    }
}
