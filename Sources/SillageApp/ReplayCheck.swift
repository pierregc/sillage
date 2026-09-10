import AppKit
import Foundation
import SillageCore
import SillageRender

/// Plays a take and says where each frame's time went.
///
/// A played-back frame does four things on the main thread one after another: it waits for
/// the snapshot the reader was supposed to have fetched, it reads what that snapshot was
/// taken at, it blends two of them on the GPU and waits for that, and then it encodes the
/// picture. Each of those has looked like the cause of a stutter at one time or another, and
/// only a split of the frame tells them apart.
///
/// Headless, and run before the window ever opens: a machine whose screen is asleep never
/// shows one, and every check that waits on `onAppear` sits there for ever. Half an hour went
/// into that before `screencapture` said "could not create image from display".
enum ReplayCheck {
    @MainActor
    static func run() {
        guard let flag = CommandLine.arguments.firstIndex(of: "--replay"),
            flag + 1 < CommandLine.arguments.count
        else { return }
        let take = CommandLine.arguments[flag + 1]
        let frames =
            flag + 2 < CommandLine.arguments.count
            ? Int(CommandLine.arguments[flag + 2]) ?? 300 : 300
        guard let model = SimulationModel() else {
            FileHandle.standardError.write(Data("replay: pas de périphérique Metal\n".utf8))
            exit(1)
        }
        model.openTake(from: URL(fileURLWithPath: take))
        // The read happens on the simulation queue and lands back through the main queue, so
        // the run loop has to turn for it even though `NSApplication` has not started yet.
        let deadline = Date().addingTimeInterval(600)
        while model.mode != .playback || model.capturedFrames < 2 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            if let failure = model.failure {
                FileHandle.standardError.write(Data("replay: \(failure)\n".utf8))
                exit(1)
            }
            if Date() > deadline {
                FileHandle.standardError.write(Data("replay: la prise n'a pas chargé\n".utf8))
                exit(1)
            }
        }
        // A canvas on this machine is a retina panel, and fill rate is most of what a splat
        // costs: measuring at 1280x720 measures a picture nobody is watching.
        model.resize(to: CGSize(width: 2560, height: 1440))

        var whole: [Double] = []
        var gpu: [Double] = []
        // The first frames pay for a cold cache and a first use of every pipeline, and are
        // not what anyone is complaining about.
        let warmup = 20
        for index in 0..<(frames + warmup) {
            let start = CACurrentMediaTime()
            guard model.playbackSnapshot() != nil else {
                FileHandle.standardError.write(Data("replay: rien à dessiner\n".utf8))
                exit(1)
            }
            guard index >= warmup else {
                model.playbackFetch.removeAll()
                model.playbackExpand.removeAll()
                model.playbackMeta.removeAll()
                model.playbackWaits = 0
                continue
            }
            whole.append((CACurrentMediaTime() - start) * 1000)
            gpu.append(model.lastOffscreenGPUMilliseconds)
        }

        func split(_ name: String, _ samples: [Double]) -> String {
            guard !samples.isEmpty else { return "\(name) aucun" }
            let sorted = samples.sorted()
            return String(
                format: "%@ médiane %6.1f ms, 99e %6.1f, pire %6.1f", name,
                sorted[sorted.count / 2],
                sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))],
                sorted.last ?? 0)
        }
        let report = """
            prise            \(model.particleCount) particules, \(model.capturedFrames) images, \(String(format: "%.1f", model.capturedMegabytes / 1024)) Go
            surface          \(Int(model.drawableSize.width)) x \(Int(model.drawableSize.height)) à \(model.supersample)x
            vitesse          \(model.playbackSpeed) images de prise par seconde affichée
            \(split("image entière   ", whole))
            \(split("attente snapshot", model.playbackFetch))
            \(split("entêtes + centres", model.playbackMeta))
            \(split("mélange GPU     ", model.playbackExpand))
            \(split("rendu GPU       ", gpu))
            snapshot en retard \(model.playbackWaits) images sur \(model.playbackFetch.count)
            """
        try? report.write(
            to: URL(fileURLWithPath: "/tmp/sillage-replay.log"), atomically: true, encoding: .utf8)
        print(report)
        exit(0)
    }
}
