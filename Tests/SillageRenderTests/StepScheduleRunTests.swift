import Foundation
import Metal
import Testing

@testable import SillageCore
@testable import SillageRender

/// Step schedules in a hires (#312): the massive pass switches its step on frame boundaries as
/// `sillage-render` does, through `StepScheduler`, and records where; the full pass follows the
/// record to the bit, light tracers included, and so does a run resumed across a switch.
/// Serialized: the runs share the solver's global settings and the GPU.
@Suite("Step schedules in a hires", .serialized)
struct StepScheduleRunTests {
    static let options = ["--particles", "3000", "--massive", "1500", "--take-interval", "1"]

    /// The massive pass of scene-0031 of the fixtures, the Metal solver over the massive
    /// particles alone, stepped as `sillage-render` steps it under `schedule` (the record's
    /// times in, the option out; nil for none): its take of every frame and `hires.json`, and
    /// its time after each frame.
    static func massivePass(frames: Int = 8, schedule: (SceneFolder.Hires) -> String?) throws -> (
        folder: SceneFolder, times: [Float]
    ) {
        let folder = try FullPassTrackTests.explored()
        let asked = options + ["--frames", String(frames), "--pass", "massive"]
        let base = try folder.hiresArguments(
            asked + ["--dt-schedule", "off"], maximumParticles: 1_000_000_000)
        let plan = try folder.hiresArguments(
            asked + ["--dt-schedule", schedule(base.record) ?? "off"], maximumParticles: 1_000_000_000)
        let run = FullPassRun(arguments: plan.arguments, engine: MetalFullPassMaker())
        let scenes = try run.scenes()
        let split = try MetalBarnesHutSolver.lightTracers(drawn: scenes.drawn, massive: scenes.scene)
        let solver = try MetalBarnesHutSolver(scene: scenes.scene, massive: split.massive, tracers: nil)
        let visible = split.massive.visibleCount
        let take = Recording(particleCount: visible, galaxyCount: scenes.scene.galaxies.count, interval: 1)
        let perFrame = max(plan.record.steps / max(frames, 1), 1)
        var record = plan.record
        var scheduler = record.stepSchedule.map {
            StepScheduler(
                schedule: $0, stepMyr: Double(scenes.scene.timeStep) * Physics.megayearsPerTimeUnit,
                story: Story(scene: scenes.scene))
        }
        func advance(_ count: Int, frame: Int?) {
            if scheduler != nil {
                scheduler!.step(count, frame: frame, on: solver, ownStep: scenes.scene.timeStep)
            } else {
                solver.step(count: count)
            }
        }
        for count in StepSchedule.settleChunks(settle: record.settle, perFrame: perFrame) {
            advance(count, frame: nil)
        }
        var times: [Float] = []
        for frame in 0..<frames {
            advance(perFrame, frame: frame)
            times.append(solver.time)
            let positions = solver.positions.contents().bindMemory(to: SIMD3<Float>.self, capacity: visible)
            take.offer(
                positions: positions, time: solver.time, centers: solver.centers, disks: solver.diskFrames,
                budget: 0)
        }
        if let scheduler {
            record.stepsRun = scheduler.stepsRun
            record.stepSwitches = scheduler.switches
        }
        try RecordingFile.write(take, scene: scenes.scene, particles: solver.particles, to: folder.take)
        try record.encoded().write(to: folder.hires)
        return (folder, times)
    }

    /// Twice the step through the settle, the step from the first frame, twice again from
    /// captured frame `from`.
    static func coarseSettleAndEnd(from: Int) -> (SceneFolder.Hires) -> String? {
        { record in
            let frame = (record.clipEndMyr - record.clipStartMyr) / Double(record.frames)
            return String(
                format: "0:2,%.4f:1,%.4f:2", record.clipStartMyr - frame / 2,
                record.clipStartMyr + (Double(from) - 0.5) * frame)
        }
    }

    static func fullPass(_ folder: SceneFolder, options: [String], stop: ((Int, Int) -> Bool)? = nil) throws
        -> [String: [[UInt8]]]
    {
        try FullPassTrackTests.fullPass(folder, options: ["--take-interval", "1"] + options, stop: stop)
    }

    /// The full pass takes the massive pass's switches, through the settle and at a frame, and
    /// repeats its massive particles to the bit on every frame; the captured frames keep their
    /// cadence; checkpoints, the settle's among them, change nothing.
    @Test func aFullPassFollowsItsMassivePassAcrossTheSwitches() throws {
        let (folder, times) = try Self.massivePass(schedule: Self.coarseSettleAndEnd(from: 4))
        defer { try? FileManager.default.removeItem(at: folder.batch.deletingLastPathComponent()) }
        let record = try #require(folder.storedHires())
        let switches = try #require(record.stepSwitches)
        let perFrame = record.steps / record.frames
        try #require(perFrame % 2 == 0, "\(perFrame) steps a frame")
        #expect(switches.map(\.scale) == [2, 1, 2])
        #expect(switches[1].step == record.settle && switches[1].frame == 0)
        #expect(switches[2].step == record.settle + 4 * perFrame && switches[2].frame == 4)
        #expect(
            record.stepsRun
                == StepSwitches(switches).steps(from: 0, to: record.settle + record.steps))
        #expect((record.stepsRun ?? 0) < record.settle + record.steps)

        // The same moments as a run at its own step throughout, within the float's rounding.
        let (plain, plainTimes) = try Self.massivePass(schedule: { _ in nil })
        defer { try? FileManager.default.removeItem(at: plain.batch.deletingLastPathComponent()) }
        #expect(plain.storedHires()?.stepSwitches == nil)
        for (a, b) in zip(times, plainTimes) { #expect(abs(a - b) <= 1e-5 * b, "\(a) against \(b)") }

        let copy = try FullPassTrackTests.copy(folder)
        let a = try Self.fullPass(folder, options: ["--checkpoint-every", "0"])
        let full = try #require(folder.storedHires()?.full)
        #expect(full.drift == 0 && full.checkedFrames == 8)
        #expect(a["4k"]?.count == 8 && a["vertical"]?.count == 8)
        let b = try Self.fullPass(copy, options: ["--checkpoint-frames", "3", "--checkpoint-steps", "5"])
        #expect(a == b)
        #expect(copy.storedHires()?.full?.drift == 0)
        // The plain run's full pass, which took no switch, draws other frames.
        let c = try Self.fullPass(plain, options: ["--checkpoint-every", "0"])
        #expect(c["4k"]?.count == 8 && c["4k"]?.last != a["4k"]?.last)
    }

    /// Stopped after a checkpoint and resumed, before a switch it then crosses or inside a coarser
    /// stretch, a full pass draws the same frames and ends in the same state, to the bit; a
    /// resume whose switches changed is refused.
    @Test func aRunResumedAcrossASwitchEndsInTheSameState() throws {
        let (straight, _) = try Self.massivePass(schedule: Self.coarseSettleAndEnd(from: 4))
        defer { try? FileManager.default.removeItem(at: straight.batch.deletingLastPathComponent()) }
        let options = ["--checkpoint-frames", "3", "--checkpoint-steps", "5"]
        let state = { (folder: SceneFolder) in
            ["--state-out", folder.url.appendingPathComponent("state.bin").path]
        }
        let before = try FullPassTrackTests.copy(straight)
        let inside = try FullPassTrackTests.copy(straight)
        let whole = try Self.fullPass(straight, options: options + state(straight))
        // Checkpoints before frames 3 and 6: stopped at frame 4 it resumes before the switch at
        // frame 4, stopped at frame 6 inside the coarser stretch after it.
        for (folder, last) in [(before, 4), (inside, 6)] {
            let kept = KeptFrames()
            #expect(throws: FullPassRun.Failure.self) {
                try FullPassTrackTests.fullPass(
                    folder, options: ["--take-interval", "1"] + options, kept: kept
                ) { frame, checkpoints in
                    checkpoints >= 1 && frame == last
                }
            }
            let first = kept.frames
            let rest = try Self.fullPass(folder, options: options + state(folder) + ["--resume"])
            for preset in ["4k", "vertical"] {
                let all = try #require(whole[preset])
                let head = try #require(first[preset])
                let tail = try #require(rest[preset])
                #expect(!tail.isEmpty && head.count + tail.count > all.count, "\(preset)")
                #expect(Array(all.prefix(head.count)) == head, "\(preset)")
                #expect(Array(all.suffix(tail.count)) == tail, "\(preset)")
            }
            for name in ["state.bin", "state.bin.json"] {
                #expect(
                    try Data(contentsOf: straight.url.appendingPathComponent(name))
                        == Data(contentsOf: folder.url.appendingPathComponent(name)), "\(name) after \(last)")
            }
            #expect(folder.storedHires()?.full?.resumes == 1 && folder.storedHires()?.full?.drift == 0)
        }
        // The state ends at the coarser step, which a checkpoint keeps.
        let saved = try JSONDecoder().decode(
            SolverState.self, from: Data(contentsOf: straight.url.appendingPathComponent("state.bin.json")))
        let record = try #require(straight.storedHires())
        let coarse = try #require(saved.timeStep)
        #expect(abs(coarse - Float(record.timeStep) * 2) < 1e-6 * coarse)

        // Another massive pass, switching elsewhere: its checkpoint is not resumed.
        let stopped = try FullPassTrackTests.copy(straight)
        #expect(throws: FullPassRun.Failure.self) {
            try Self.fullPass(stopped, options: options) { frame, checkpoints in
                checkpoints >= 1 && frame == 4
            }
        }
        var moved = record
        moved.stepSwitches = moved.stepSwitches.map { switches in
            switches.enumerated().map { index, entry in
                var entry = entry
                if index == 2 { entry.step += record.steps / record.frames }
                return entry
            }
        }
        moved.full = nil
        try moved.encoded().write(to: stopped.hires)
        do {
            _ = try Self.fullPass(stopped, options: options + ["--resume"])
            Issue.record("a resume along other switches ran")
        } catch let FullPassRun.Failure.otherRun(why) {
            #expect(why.contains("its command line"))
        }
    }
}
