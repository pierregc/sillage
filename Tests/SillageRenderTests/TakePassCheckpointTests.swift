import AVFoundation
import Foundation
import Metal
import Testing

@testable import SillageCore
@testable import SillageRender

/// Checkpoints of the pass that writes a take (#377), in the suite of the full pass's: the runs
/// here encode their video, and two encoders side by side can wait for good.
extension CheckpointTests {
    /// The options of a short hires of `folder` that checkpoints often, keeps its last state and
    /// writes every frame as its encoder took it.
    private func asked(_ folder: SceneFolder, _ options: [String]) -> [String] {
        options + [
            "--frames", "12", "--checkpoint-frames", "5", "--checkpoint-steps", "4", "--state-out",
            folder.url.appendingPathComponent("state.bin").path, "--out",
            folder.url.appendingPathComponent("frames/f.png").path,
        ]
    }

    /// A hires of `folder` through the flow, on Metal, as `sillage-render hires` runs it.
    private func hires(_ folder: SceneFolder, _ options: [String], stop: ((Int?, Int) -> Bool)? = nil) throws
    {
        let plan = try folder.hiresArguments(asked(folder, options), maximumParticles: 1_000_000_000)
        let run = TakePassRun(
            arguments: plan.arguments, engine: MetalTakePassMaker(), hires: (folder, plan.record))
        run.stop = stop
        _ = try run.run()
    }

    /// A take as its header reads and the bytes after it.
    private func take(_ url: URL) throws -> [Data] {
        let data = try Data(contentsOf: url)
        let length = Int(data[16..<24].reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) })
        let header = try JSONSerialization.jsonObject(with: data[24..<(24 + length)])
        return [
            try JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]),
            Data(data[(24 + length)...]),
        ]
    }

    /// How many frames a video holds, decoded.
    private func frames(_ url: URL) throws -> Int {
        final class Box: @unchecked Sendable { var track: AVAssetTrack? }
        let asset = AVURLAsset(url: url)
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        asset.loadTracks(withMediaType: .video) { tracks, _ in
            box.track = tracks?.first
            done.signal()
        }
        done.wait()
        let track = try #require(box.track)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        #expect(reader.startReading())
        var count = 0
        while output.copyNextSampleBuffer() != nil { count += 1 }
        return count
    }

    /// #240's test, for the take pass: a hires never stopped against one killed just after a
    /// checkpoint in its settle, resumed, killed again after a checkpoint in its frames, a
    /// segment of its video open, and resumed to the end. One pass of every particle, one with
    /// light tracers, and a massive pass, each with the standard step schedule, judged on the
    /// run's centres, and the director. The same take past its header, the same curves, massive
    /// set, solver state and step switches, and the same frames handed to the video's encoder:
    /// compared as the stills read off them, since an encoder under load is not held to its bits.
    @Test(arguments: [
        ["--particles", "3000"], ["--particles", "3000", "--massive", "1500"],
        ["--particles", "3000", "--massive", "1500", "--pass", "massive"],
    ])
    func aTakePassKilledTwiceAndResumedWritesTheSameFiles(_ draw: [String]) throws {
        let straight = try FullPassTrackTests.explored()
        let stopped = try FullPassTrackTests.explored()
        defer {
            for folder in [straight, stopped] {
                try? FileManager.default.removeItem(at: folder.batch.deletingLastPathComponent())
            }
        }
        try hires(straight, draw)
        let whole = try #require(straight.storedHires())
        #expect(whole.resumes == nil && whole.stepSwitches?.map(\.scale) == [2, 1])
        #expect(!FileManager.default.fileExists(atPath: straight.checkpoint.path))

        // Killed in the settle, right after its first checkpoint.
        #expect(throws: TakePassRun.Failure.self) {
            try hires(stopped, draw) { frame, checkpoints in frame == nil && checkpoints == 1 }
        }
        #expect(stopped.resumesHires(asked(stopped, draw), maximumParticles: 1_000_000_000))
        #expect(
            !stopped.resumesHires(
                asked(stopped, draw + ["--take-interval", "2"]), maximumParticles: 1_000_000_000))
        // Resumed, and killed two frames after the checkpoint before frame 5.
        #expect(throws: TakePassRun.Failure.self) {
            try hires(stopped, draw + ["--resume"]) { frame, _ in frame == 6 }
        }
        #expect(!FileManager.default.fileExists(atPath: stopped.take.path))

        // Another command line, scene or look is another run; a take cut short is refused.
        func refused(_ what: String, _ options: [String] = []) {
            #expect("\(what)") {
                try hires(stopped, draw + ["--resume"] + options)
            } throws: { error in
                "\(error)".contains(what)
            }
        }
        refused("its command line", ["--take-interval", "2"])
        for (url, what) in [(stopped.scene, "scene.json"), (stopped.look, "the look")] {
            let original = try Data(contentsOf: url)
            try (original + Data("\n".utf8)).write(to: url)
            refused(what)
            try original.write(to: url)
        }
        let positions = RunCheckpoint(directory: stopped.checkpoint).takePositions
        let held = try Data(contentsOf: positions)
        // The checkpoint before frame 5 holds frames 0 and 4.
        let recorded = try #require(RunCheckpoint(directory: stopped.checkpoint).stored()?.take?.take)
        #expect(recorded.frames.count == 2 && recorded.offered == 5)
        try held.prefix(recorded.bytes - 1).write(to: positions)
        refused("holds fewer")
        try held.write(to: positions)

        try hires(stopped, draw + ["--resume"])
        let resumed = try #require(stopped.storedHires())
        #expect(resumed.resumes == 2)
        #expect(resumed.stepSwitches == whole.stepSwitches && resumed.stepsRun == whole.stepsRun)
        #expect(!FileManager.default.fileExists(atPath: stopped.checkpoint.path))
        #expect(try take(stopped.take) == take(straight.take))
        #expect(try RecordingFile.read(from: stopped.take).recording.capturedFrames == 12)
        for name in ["curves-hires.csv", "state.bin", "state.bin.json"] {
            #expect(
                try Data(contentsOf: stopped.url.appendingPathComponent(name))
                    == Data(contentsOf: straight.url.appendingPathComponent(name)), "\(name)")
        }
        #expect(try frames(stopped.hiresVideo) == 12 && frames(straight.hiresVideo) == 12)
        for frame in 0..<12 {
            let name = String(format: "frames/f.%04d.png", frame)
            let drawn = try Data(contentsOf: stopped.url.appendingPathComponent(name))
            #expect(drawn == (try Data(contentsOf: straight.url.appendingPathComponent(name))), "\(name)")
        }
        guard draw.contains("--pass") else { return }
        #expect(try Data(contentsOf: stopped.massiveSet) == Data(contentsOf: straight.massiveSet))
        // A full pass after the resumed massive pass repeats it.
        try FullPassTrackTests.fullPass(stopped, frames: 12, options: ["--checkpoint-every", "0"])
        let full = try #require(stopped.storedHires()?.full)
        #expect(full.drift == 0 && full.checkedFrames == 4)
    }

    /// A run that measures is refused with a checkpoint rather than half saved, and an
    /// exploration has none.
    @Test func aMeasuringRunDoesNotCheckpoint() throws {
        let folder = try FullPassTrackTests.explored()
        defer { try? FileManager.default.removeItem(at: folder.batch.deletingLastPathComponent()) }
        let density = folder.url.appendingPathComponent("density.png").path
        #expect {
            try hires(folder, ["--particles", "3000", "--density", density])
        } throws: { error in
            "\(error)".contains("--density")
        }
        #expect(!folder.exploreArguments([], clip: try folder.storedClip()).contains("--checkpoint"))
    }
}
