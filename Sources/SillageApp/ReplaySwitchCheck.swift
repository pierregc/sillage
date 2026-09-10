import AppKit
import Foundation
import SillageCore
import SillageRender

/// Does the solver actually stop when a run switches to playing itself back?
///
/// It is the one question the replay path never answered. `stopAndReplay` retires the
/// stepping chain and then sets `isPlaying`, whose observer starts a chain again whenever the
/// mode still says `.running` — which it does, because the mode is set on the next line. A
/// run that was paused first, and every run that reaches its finish, therefore replays with a
/// solver still taking the GPU behind the picture.
enum ReplaySwitchCheck {
    @MainActor
    static func run() {
        guard CommandLine.arguments.contains("--replayswitch") else { return }
        guard let model = SimulationModel() else { exit(1) }
        model.draft = .merger(particleCount: 200_000)
        model.draft.solver = .barnesHut
        model.draft.retune()
        model.setTotalParticles(200_000)
        model.start(waiting: true)
        model.resize(to: CGSize(width: 640, height: 400))

        func settle(_ seconds: Double) {
            RunLoop.current.run(until: Date().addingTimeInterval(seconds))
        }
        // Enough batches to have a capture worth replaying.
        settle(6)
        let stepping = model.solverSteps
        // The sequence `checkFinish` walks when a run reaches its end: pause, then replay.
        model.isPlaying = false
        model.stopAndReplay()
        let atSwitch = model.solverSteps
        settle(6)
        let afterwards = model.solverSteps

        let quiet = afterwards == atSwitch
        let report = """
            mode             \(model.mode)
            pas avant l'arrêt \(stepping)
            pas au bascule    \(atSwitch)
            pas 6 s plus tard \(afterwards)
            solveur arrêté    \(quiet ? "OUI" : "NON, +\(afterwards - atSwitch) pas pendant la relecture")
            """
        print(report)
        exit(quiet ? 0 : 1)
    }
}
