import AVFoundation
import AppKit
import Darwin
import Foundation
import SillageCore
import SillageRender
import SwiftUI

/// The automatic pace in the app (#311), without a window: the style editor's playhead along the
/// pace, the scrubber that draws it, and the export panel with its Speed, on a scene of the
/// library. With `--export`, the export at Auto goes through the queue and the runner bundled in
/// the app, and its length is compared with the estimate.
///
/// `--pacecheck <scene folder> [--out <folder for the pictures>] [--export]`. Needs the GPU and a
/// take; work on a clone of a scene, the queue writes its files in the scene's library.
enum PaceCheck {
    @MainActor
    static func run() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--pacecheck"), flag + 1 < arguments.count else { return }
        func option(_ name: String) -> String? {
            arguments.firstIndex(of: name).flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
        }
        var failed = false
        func check(_ label: String, _ passed: Bool, _ detail: String = "") {
            print("\(passed ? "ok  " : "FAIL") \(label)\(detail.isEmpty ? "" : "  \(detail)")")
            fflush(stdout)
            if !passed { failed = true }
        }
        func fail(_ why: String) -> Never {
            FileHandle.standardError.write(Data("pacecheck: \(why)\n".utf8))
            exit(1)
        }
        func wait(_ seconds: Double) { RunLoop.current.run(until: Date(timeIntervalSinceNow: seconds)) }

        let folder = SceneFolder(URL(fileURLWithPath: arguments[flag + 1]))
        let out = URL(fileURLWithPath: option("--out") ?? "out", isDirectory: true)
        let library = folder.batch.deletingLastPathComponent()
        guard let model = SimulationModel() else { fail("no Metal device") }
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        model.openTake(from: folder.take, look: folder.look, folder: folder)
        let deadline = Date().addingTimeInterval(900)
        while model.mode != .playback || model.capturedFrames < 2 {
            wait(0.05)
            if let failure = model.failure { fail(failure) }
            if Date() > deadline { fail("the take did not load") }
        }
        model.resize(to: CGSize(width: 960, height: 540))
        model.isPlaying = false

        // The playhead along the pace: about a captured frame a tick in the collision, several
        // in the settling.
        let pace = PacePlayback(model: model, folder: folder)
        pace.choice = .auto
        check("Auto gives a track to the playhead", pace.isOn && pace.failure == nil, pace.failure ?? "")
        let top = pace.samples.map(\.speed).max() ?? 0
        check(
            "it starts at 1x and speeds up to the end",
            abs((pace.samples.first?.speed ?? 0) - 1) < 0.05 && (pace.samples.last?.speed ?? 0) > 2,
            String(
                format: "x%.2f at the start, x%.2f at the end, up to x%.2f", pace.samples.first?.speed ?? 0,
                pace.samples.last?.speed ?? 0, top))
        func advance(at along: Double) -> Double? {
            guard let recording = model.playedTake?.recording else { return nil }
            model.playbackPosition = along * Double(model.capturedFrames - 1)
            let before = recording.capturedPosition(atStored: model.playbackPosition)
            model.isPlaying = true
            _ = model.playbackSnapshot()
            model.isPlaying = false
            return (recording.capturedPosition(atStored: model.playbackPosition) - before) / 0.5
        }
        let early = advance(at: 0.1) ?? 0
        let late = advance(at: 0.95) ?? 0
        check(
            "playing, the take moves as fast as the track says",
            abs(early - (pace.samples.first { $0.at >= 0.1 }?.speed ?? 0)) < 0.5 && late > 2,
            String(format: "x%.2f at 10 %%, x%.2f at 95 %%", early, late))
        pace.choice = .off
        let plain = advance(at: 0.95) ?? 0
        check(
            "without a pace it plays the take as before", abs(plain - 1) < 0.01,
            String(format: "x%.2f", plain))
        pace.choice = .auto
        model.playbackPosition = Double(model.capturedFrames - 1) * 0.62

        SillageApp.write(
            AnyView(
                TransportBar(model: model, pace: pace, snapshot: true).frame(width: 1100)
                    .environment(\.offscreen, true)),
            to: out.appendingPathComponent("scrubber-auto.png").path)

        // The export panel at Auto, over the scene's own queue.
        let queue = QueueModel(library: library)
        let running = arguments.contains("--export")
        if !running { queue.runnerURL = nil }
        let quotes = StageQuotes.read([folder], library: queue.store.library)
        var sheet = ExportSheet(
            queue: queue, folders: [folder], close: {}, ticked: [.hd], settings: ExportSettings(),
            quotes: quotes)
        sheet.settings.speed = .auto
        let plainJob = StageJobs.export(
            .hd, ExportSettings(), folder: folder, state: quotes.exports[folder.url.path] ?? .init(),
            cost: quotes.cost, queue: queue.queue)
        var auto = ExportSettings()
        auto.speed = .auto
        let job = StageJobs.export(
            .hd, auto, folder: folder, state: quotes.exports[folder.url.path] ?? .init(),
            cost: quotes.cost, queue: queue.queue)
        check(
            "an export at Auto asks for it and writes a file of its own",
            job.options.contains("auto") && job.output?.lastPathComponent == "1080p-auto.mp4",
            job.options.joined(separator: " "))
        let share = VideoLength.share(of: "auto", folder: folder)
        check(
            "the queue counts the video's frames from the pace",
            share < 0.95 && (job.seconds ?? 0) < (plainJob.seconds ?? 0),
            String(
                format: "%.0f %% of the frames, %@ against %@", share * 100,
                Format.about(job.seconds ?? 0), Format.about(plainJob.seconds ?? 0)))
        let queueEnvironment = queue
        SillageApp.write(
            AnyView(
                sheet.environment(\.offscreen, true).environment(\.queue, queueEnvironment).frame(width: 760)),
            to: out.appendingPathComponent("export-panel-auto.png").path)

        if running {
            check("the export joins the queue", queue.submit([job]) == 1, queue.failure ?? "")
            let queued = queue.queue.unfinished(at: folder).first
            let limit = Date().addingTimeInterval(3 * 3600)
            var finished: QueueJob?
            while finished == nil, Date() < limit {
                wait(1)
                queue.refresh()
                finished = queue.queue.jobs.first { $0.id == queued?.id && $0.isFinished }
            }
            guard let finished else { fail("the export did not end") }
            check("it ends well", finished.state == .done, finished.message ?? "")
            if let output = job.output, finished.state == .done {
                var length: Double?
                Task { @MainActor in
                    length = (try? await AVURLAsset(url: output).load(.duration).seconds) ?? 0
                }
                while length == nil { wait(0.1) }
                let seconds = length ?? 0
                let take =
                    Double(VideoLength.takeFrames(folder) ?? 0) / Double((try? folder.capturedRate()) ?? 30)
                let ran = (finished.ended ?? Date()).timeIntervalSince(finished.started ?? Date())
                check(
                    "the video is as long as the queue counted",
                    abs(seconds - take * share) < 1.5,
                    String(
                        format: "video %.1f s, counted %.1f s, the take %.1f s", seconds, take * share, take))
                print(
                    String(
                        format: "estimate  export %.0f s planned, took %.0f s", job.seconds ?? 0, ran))
            }
        }
        exit(failed ? 1 : 0)
    }
}
