import AppKit
import Foundation
import SillageCore

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
            lines.append("\(results.count - failures) / \(results.count) vérifications passées")
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
            report.check("l'aperçu de réglage dessine", previewLit > 10_000, "\(previewLit) échantillons")

            // Launch.
            model.start()
            report.check("le lancement bascule tout de suite", model.stage == .running)
            report.check("le lancement annonce sa préparation", model.isPreparing)
            await settle(2.0)
            report.check("la préparation se termine", !model.isPreparing)
            report.check("le lancement passe en simulation", model.mode == .running)
            report.check("le lancement démarre en lecture", model.isPlaying)
            let framesAtLaunch = model.framesDrawn
            await settle(1.5)
            report.check(
                "la toile dessine", model.framesDrawn > framesAtLaunch + 10,
                "\(model.framesDrawn - framesAtLaunch) images")
            report.check(
                "le temps avance", model.elapsedMyr > 0,
                String(format: "%.1f Myr", model.elapsedMyr))
            report.check(
                "la prise démarre seule", model.capturedFrames > 2,
                "\(model.capturedFrames) images")
            report.check(
                "la prise occupe de la mémoire", model.capturedBytes > 0,
                String(format: "%.1f Mo", model.capturedMegabytes))
            report.check("aucune erreur", model.failure == nil, model.failure ?? "")

            // Pause holds the clock.
            model.isPlaying = false
            await settle(0.6)
            let held = model.elapsedMyr
            await settle(0.6)
            report.check("la pause arrête le calcul", abs(model.elapsedMyr - held) < 1e-9)
            model.isPlaying = true
            await settle(0.8)
            report.check("la reprise repart", model.elapsedMyr > held)

            // Stop and replay.
            let capturedBeforeReplay = model.capturedFrames
            report.check("la relecture est offerte", model.canReplay)
            model.stopAndReplay()
            report.check("l'arrêt bascule en relecture", model.mode == .playback)
            await settle(1.0)
            report.check(
                "la relecture avance", model.playbackPosition > 0,
                String(format: "position %.1f", model.playbackPosition))
            // The clock follows the frame on screen during playback, which is what it should
            // show; what must stop is the computing behind it.
            let framesWhenStopped = model.capturedFrames
            await settle(0.8)
            report.check(
                "la relecture ne calcule plus",
                model.capturedFrames == framesWhenStopped,
                "\(model.capturedFrames) images")

            // Scrubbing anywhere must be safe, ends included.
            for position in [0.0, Double(capturedBeforeReplay - 1), Double(capturedBeforeReplay) * 0.5] {
                model.playbackPosition = position
                model.drawOnce()
            }
            report.check("le défilement tient les bornes", model.failure == nil)

            // Pick the run back up.
            model.resumeRunning()
            report.check("la reprise revient en simulation", model.mode == .running)
            await settle(1.0)
            report.check(
                "la prise reprend où elle en était",
                model.capturedFrames > capturedBeforeReplay,
                "\(capturedBeforeReplay) puis \(model.capturedFrames)")

            // A fresh capture keeps the run but drops the frames.
            let timeBeforeNewTake = model.elapsedMyr
            model.restartCapture()
            report.check(
                "une nouvelle prise repart de zéro", model.capturedFrames == 1,
                "\(model.capturedFrames) image")
            report.check(
                "une nouvelle prise garde le calcul",
                abs(model.elapsedMyr - timeBeforeNewTake) < 5,
                String(format: "%.1f puis %.1f Myr", timeBeforeNewTake, model.elapsedMyr))
            await settle(0.8)
            report.check("la nouvelle prise se remplit", model.capturedFrames > 2)

            // Restart winds the clock back. It picks straight back up, so the test is that
            // the clock fell, not that it is standing at zero by the time anyone looks.
            let clockBeforeRestart = model.elapsedMyr
            model.restart()
            await settle(0.5)
            report.check(
                "relancer remet le temps à zéro",
                model.elapsedMyr < clockBeforeRestart / 2,
                String(format: "%.0f puis %.0f Myr", clockBeforeRestart, model.elapsedMyr))
            report.check("relancer repart d'une prise neuve", model.capturedFrames >= 1)

            // The memory budget stops the capture without stopping the run.
            model.memoryBudgetGigabytes = 0.5
            model.restartCapture()
            await settle(2.5)
            let framesAtCap = model.capturedFrames
            let timeAtCap = model.elapsedMyr
            await settle(1.5)
            report.check(
                "le budget mémoire borne la prise",
                model.captureIsFull || model.capturedMegabytes < 520,
                String(format: "%.0f Mo pour 512 Mo", model.capturedMegabytes))
            if model.captureIsFull {
                report.check(
                    "le calcul continue après le budget", model.elapsedMyr > timeAtCap,
                    "\(framesAtCap) images figées")
            }
            model.memoryBudgetGigabytes = 4

            // Rendering settings must survive both states.
            model.supersample = 2
            await settle(0.4)
            report.check("le suréchantillonnage tient en simulation", model.failure == nil)
            model.stopAndReplay()
            await settle(0.4)
            model.supersample = 1
            await settle(0.4)
            report.check("le suréchantillonnage tient en relecture", model.failure == nil)

            // Back to the setup screen and out again.
            model.returnToSetup()
            report.check("le retour au réglage quitte la simulation", model.stage == .setup)
            report.check("le retour au réglage vide la prise", model.capturedFrames == 0)
            model.rebuildPreview()
            report.check("l'aperçu revient", (model.previewSnapshot() ?? []).contains { $0 > 8 })
            model.start()
            await settle(2.0)
            report.check(
                "un second lancement repart", model.isPlaying && model.elapsedMyr > 0,
                String(format: "%.1f Myr", model.elapsedMyr))
            report.check("un second lancement capture", model.capturedFrames > 1)
            report.check("rien n'a échoué en chemin", model.failure == nil, model.failure ?? "")

            // Restarting out of playback has to land back in a running scene, not leave the
            // canvas bound to a recording that no longer matches the solver.
            model.stopAndReplay()
            report.check("l'arrêt bascule en relecture (2)", model.mode == .playback)
            model.restart()
            await settle(0.6)
            report.check(
                "relancer depuis la relecture repart en simulation",
                model.mode == .running && model.capturedFrames > 1)

            // Leaving mid-launch has to retire the sampling job rather than let it land on
            // an empty setup screen.
            model.returnToSetup()
            model.setTotalParticles(2_000_000)
            model.start()
            report.check("un gros lancement prépare en fond", model.isPreparing)
            model.returnToSetup()
            report.check("quitter pendant la préparation l'annule", !model.isPreparing)
            await settle(3.0)
            report.check(
                "la préparation annulée ne revient pas",
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
                "l'auto-gravité avance", model.elapsedMyr > 0,
                String(format: "%.2f Myr", model.elapsedMyr))
            report.check(
                "l'auto-gravité capture", model.capturedFrames > 1,
                "\(model.capturedFrames) images")
            report.check("l'auto-gravité dessine encore", model.framesDrawn > 0)
            report.check(
                "l'auto-gravité annonce son débit", model.megayearsPerSecond > 0,
                String(format: "%.2f Myr/s", model.megayearsPerSecond))
            if model.canReplay {
                model.stopAndReplay()
                await settle(0.6)
                report.check(
                    "l'auto-gravité se rejoue",
                    model.mode == .playback
                        && model.playbackPosition > 0)
            }
            report.check("aucune erreur en auto-gravité", model.failure == nil, model.failure ?? "")

            let text = report.rendered()
            try? text.write(
                to: URL(fileURLWithPath: "/tmp/sillage-qa.log"), atomically: true, encoding: .utf8)
            print(text)
            exit(report.failures == 0 ? 0 : 1)
        }
    }
}
