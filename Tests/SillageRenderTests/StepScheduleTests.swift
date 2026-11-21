import Foundation
import SillageCore
import Testing

@testable import SillageRender

@Suite("Step schedule")
struct StepScheduleTests {
    @Test func aScheduleReadsItsEntriesInOrderOfTime() throws {
        let schedule = try StepSchedule(parsing: "610:2,0:4,162:1")
        #expect(schedule.description == "0:4,162:1,610:2")
        #expect(schedule.scale(atMyr: 0) == 4 && schedule.scale(atMyr: 161.9) == 4)
        #expect(schedule.scale(atMyr: 162) == 1 && schedule.scale(atMyr: 700) == 2)
        #expect(schedule.scale(atMyr: 700, count: 3) == 1 && schedule.scale(atMyr: 700, count: 4) == 2)
        #expect(try StepSchedule(parsing: "760:2").scale(atMyr: 10) == 1)
        try schedule.check(stepsPerFrame: 8)
        #expect(throws: StepSchedule.Problem.self) { try schedule.check(stepsPerFrame: 2) }
        #expect(throws: StepSchedule.Problem.self) {
            try StepSchedule(parsing: "0:3").check(stepsPerFrame: 6)
        }
        for text in ["", "0", "0:x", "-1:2", "0:0", "1:2:3"] {
            #expect(throws: StepSchedule.Problem.self, "\(text)") { try StepSchedule(parsing: text) }
        }
    }

    @Test func theOptionAsksForNothingAPlanOrEntries() throws {
        #expect(try StepSchedule.Asked(nil) == StepSchedule.standard.map { .story($0) } ?? .off)
        #expect(try StepSchedule.Asked("off") == .off)
        let standard = StepSchedule.standard ?? StepSchedule.Plan(before: 2, after: 2)
        #expect(try StepSchedule.Asked("story") == .story(standard))
        #expect(
            try StepSchedule.Asked("story:4:2") == .story(.init(before: 4, after: 2, margin: standard.margin))
        )
        #expect(try StepSchedule.Asked("story:1:2:150") == .story(.init(before: 1, after: 2, margin: 150)))
        #expect(try StepSchedule.Asked("0:2,160:1") == .entries(try StepSchedule(parsing: "0:2,160:1")))
        for text in ["story:3", "story:2:0", "story:x", "story:2:2:-1", "story:1:1:1:1", "stories"] {
            #expect(throws: StepSchedule.Problem.self, "\(text)") { try StepSchedule.Asked(text) }
        }
    }

    /// Coarse through the settle, fine from the first captured frame, coarse again from the last
    /// engagement and the margin, judged by the run with the same margin.
    @Test func aPlanFollowsTheStoryOfThePreview() throws {
        let plan = StepSchedule.Plan(before: 2, after: 2, margin: 100)
        let frame = 0.79
        let schedule = try #require(
            StepSchedule.planned(
                plan, clipStartMyr: 157.3, clipEndMyr: 887, frameMyr: frame, perFrame: 8,
                lastEngagementMyr: 510.4))
        #expect(schedule.description == "0:2,156.9:1,610.4:2" && schedule.margin == 100)
        // The settle's last stretch, a frame before the first captured one, is coarse; the first
        // captured frame is not.
        #expect(schedule.scale(atMyr: 157.3 - frame) == 2 && schedule.scale(atMyr: 157.3 - 1e-5) == 1)
        // A frame of 2 steps holds 2 at most; of 1, nothing coarser.
        let fourTimes = StepSchedule.Plan(before: 4, after: 2)
        #expect(
            StepSchedule.planned(
                fourTimes, clipStartMyr: 157.3, clipEndMyr: 887, frameMyr: frame, perFrame: 2,
                lastEngagementMyr: nil)?.description == "0:2,156.9:1")
        #expect(
            StepSchedule.planned(
                plan, clipStartMyr: 157.3, clipEndMyr: 887, frameMyr: frame, perFrame: 1,
                lastEngagementMyr: 510.4) == nil)
        // An aftermath that would start after the story's end is left out, and so is a plan at
        // the hires step throughout.
        #expect(
            StepSchedule.planned(
                plan, clipStartMyr: 157.3, clipEndMyr: 600, frameMyr: frame, perFrame: 8,
                lastEngagementMyr: 510.4)?.description == "0:2,156.9:1")
        #expect(
            StepSchedule.planned(
                .init(before: 1, after: 2), clipStartMyr: 157.3, clipEndMyr: 887, frameMyr: frame,
                perFrame: 8, lastEngagementMyr: 510.4)?.description == "610.4:2")
        #expect(
            StepSchedule.planned(
                .init(before: 1, after: 1), clipStartMyr: 157.3, clipEndMyr: 887, frameMyr: frame,
                perFrame: 8, lastEngagementMyr: 510.4) == nil)
    }

    /// A schedule's steps, counted as a run cuts them: its settle to whole frames before the
    /// first captured one, then frame by frame.
    @Test func aScheduleCountsTheStepsARunTakes() throws {
        #expect(StepSchedule.settleChunks(settle: 21, perFrame: 8) == [5, 8, 8])
        #expect(StepSchedule.settleChunks(settle: 16, perFrame: 8) == [8, 8])
        #expect(StepSchedule.settleChunks(settle: 0, perFrame: 8).isEmpty)
        // Steps of 1 Myr, 8 a frame: settle 21 Myr, 10 frames. Coarse to 20, fine, coarse from 60.
        let schedule = try StepSchedule(parsing: "0:2,20:1,60:2")
        // The first 5 are not whole steps of 2, so they run at 1; the 16 after at 2; frames 0 to
        // 4 start before 60 at 1; frames 5 to 9 at 2.
        #expect(schedule.steps(settle: 21, frames: 10, perFrame: 8, stepMyr: 1) == 5 + 8 + 40 + 20)
        #expect(schedule.steps(settle: 21, frames: 10, perFrame: 8, stepMyr: 1, from: 61) == 20)
        var record = SceneFolder.Hires(
            particles: 1, previewParticles: 1, width: 1, height: 1, frames: 10, fps: 30, settle: 21,
            steps: 80, timeStepScale: 3.5, timeStep: 0.1, timeStepMyr: 1, previewTimeStepMyr: 1,
            softening: 0.1, clipStartMyr: 21, clipEndMyr: 101)
        #expect(record.stepsToRun == 101)
        record.stepSchedule = schedule
        #expect(record.stepsToRun == 73)
        record.stepsRun = 80
        #expect(record.stepsToRun == 80)
    }

    /// Without a judge the run takes the scales planned, switching on its stretches' starts.
    @Test func aSchedulerRecordsWhereItSwitched() throws {
        var scheduler = StepScheduler(
            schedule: try StepSchedule(parsing: "0:2,20:1,60:2"), stepMyr: 1, story: nil)
        #expect(scheduler.judge == nil)
        for count in StepSchedule.settleChunks(settle: 21, perFrame: 8) {
            _ = scheduler.next(count, frame: nil)
        }
        for frame in 0..<10 { _ = scheduler.next(8, frame: frame) }
        #expect(scheduler.stepsRun == 73 && scheduler.ownSteps == 101)
        #expect(
            scheduler.switches.map(\.step) == [5, 21, 61] && scheduler.switches.map(\.scale) == [2, 1, 2])
        #expect(scheduler.switches.map(\.frame) == [nil, 0, 5])
        let switches = StepSwitches(scheduler.switches)
        #expect(switches.description == "5:2,21:1,61:2")
        try switches.check(settle: 21, frames: 10, perFrame: 8)
        #expect(switches.steps(from: 0, to: 101) == 73 && switches.steps(from: 21, to: 61) == 40)
        #expect(switches.scale(forStep: 4) == 1 && switches.scale(forStep: 5) == 2)
        #expect(switches.scale(forStep: 20) == 2 && switches.scale(forStep: 21) == 1)
        #expect(
            switches.scale(forStep: 100) == 2 && switches.next(after: 5) == 21
                && switches.next(after: 61) == nil)
        #expect(try StepSwitches(parsing: "61:2,5:2,21:1") == switches)
    }

    @Test func switchesARunCouldNotHaveTakenAreRefused() throws {
        for text in ["5:2,24:1", "5:3", "6:2", "5:2,21:1,62:2", "x", "5:0", "5:16"] {
            #expect(throws: StepSwitches.Problem.self, "\(text)") {
                try StepSwitches(parsing: text).check(settle: 21, frames: 10, perFrame: 8)
            }
        }
        #expect(throws: StepSwitches.Problem.self) { try StepSwitches(parsing: "") }
    }

    /// A moment of the video in a frame of coarser steps: the same moment, counted in them.
    @Test func aPlaceIsCountedInTheStepsOfItsFrame() {
        let on = FullPassRun.Place(frame: 3, step: 8, fraction: 0)
        #expect(on.taking(1) == on && on.taking(2) == FullPassRun.Place(frame: 3, step: 4, fraction: 0))
        let between = FullPassRun.Place(frame: 3, step: 5, fraction: 0.5)
        #expect(between.taking(2) == FullPassRun.Place(frame: 3, step: 2, fraction: 0.75))
        #expect(
            FullPassRun.Place(frame: 3, step: 3, fraction: 0).taking(4)
                == FullPassRun.Place(frame: 3, step: 0, fraction: 0.75))
        #expect(
            FullPassRun.Place(frame: 3, step: 3, fraction: 0.9999999).taking(2)
                == FullPassRun.Place(frame: 3, step: 2, fraction: 0))
    }

    static func folder(clip: SceneFolder.Clip = SceneFolder.Clip()) throws -> SceneFolder {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch-\(UUID().uuidString)").appendingPathComponent("scene-0001")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let folder = SceneFolder(url)
        var scene = SceneConfig.merger(particleCount: 400_000)
        scene.solver = .barnesHut
        try SceneFile(scene).encoded().write(to: folder.scene)
        try clip.encoded().write(to: folder.clip)
        return folder
    }

    /// Curves of a pair that falls straight in at 300 km/s and stays merged at 2 kpc from
    /// `mergeMyr`, a sample every `frameMyr` up to `endMyr`.
    static func mergerCurves(mergeMyr: Double, endMyr: Double, frameMyr: Double) -> String {
        var csv = "frame,time_myr,separation_kpc,extent_kpc,formed,closest_kpc,tidal_fraction"
        csv += ",disruption_0,disruption_1,x_0,y_0,z_0,x_1,y_1,z_1,torn_0,torn_1\n"
        var time = frameMyr
        var frame = 0
        while time <= endMyr {
            let distance = time < mergeMyr ? 10 + 0.3 * (mergeMyr - time) : 2
            csv += String(
                format: "%d,%.3f,%.4f,20,0,%.4f,0,0,0,0,0,0,%.4f,0,0,0,0\n", frame, time, distance, distance,
                distance)
            time += frameMyr
            frame += 1
        }
        return csv
    }

    /// Every hires plans the standard schedule from its preview unless told otherwise, records
    /// it, and asks the run to judge its own; a full pass follows the switches its massive pass
    /// recorded.
    @Test func aHiresPlansItsScheduleAndAFullPassFollowsTheSwitches() throws {
        var clip = SceneFolder.Clip()
        clip.steps = 7_200
        let folder = try Self.folder(clip: clip)
        defer { try? FileManager.default.removeItem(at: folder.batch) }
        let draw = ["--particles", "8e6", "--massive", "2e6"]
        // Without curves, the settle alone.
        let settleOnly = try folder.hiresArguments(draw, maximumParticles: 10_000_000).record
        let perFrame = settleOnly.steps / settleOnly.frames
        try #require(perFrame % 2 == 0)
        #expect(StepSchedule.standard == nil || settleOnly.stepSchedule?.entries.count == 2)
        let merge = settleOnly.clipEndMyr - 110
        // Engaged past `Story`'s first window, with room for the aftermath.
        try #require(merge > 170, "\(settleOnly)")
        try Self.mergerCurves(mergeMyr: merge, endMyr: settleOnly.clipEndMyr, frameMyr: 0.79).write(
            to: folder.curves, atomically: true, encoding: .utf8)
        let planned = try folder.hiresArguments(draw, maximumParticles: 10_000_000)
        let record = planned.record
        let engaged = try #require(
            StepSchedule.lastEngagement(
                csv: String(contentsOf: folder.curves, encoding: .utf8),
                story: Story(
                    scene: try SceneFile.decoded(from: Data(contentsOf: folder.scene)).scene(
                        particleCount: 700_000))))
        #expect(abs(engaged - merge) < 2)
        if let standard = StepSchedule.standard {
            let schedule = try #require(record.stepSchedule)
            #expect(schedule.margin == standard.margin)
            #expect(
                schedule.entries.count == 3
                    && schedule.entries[0] == .init(fromMyr: 0, scale: standard.before))
            #expect(schedule.entries[1].scale == 1 && schedule.entries[1].fromMyr < record.clipStartMyr)
            #expect(abs(schedule.entries[2].fromMyr - engaged - standard.margin) < 0.11)
            #expect(
                planned.arguments.contains("--dt-judge") && planned.arguments.contains(schedule.description))
            #expect(record.stepsToRun < record.settle + record.steps)
        }
        let off = try folder.hiresArguments(draw + ["--dt-schedule", "off"], maximumParticles: 10_000_000)
        #expect(off.record.stepSchedule == nil && !off.arguments.contains("--dt-schedule"))
        #expect(!String(decoding: try off.record.encoded(), as: UTF8.self).contains("stepSchedule"))
        #expect(off.record.stepsToRun == off.record.settle + off.record.steps)
        let given = try folder.hiresArguments(
            draw + ["--dt-schedule", "0:2,160:1", "--pass", "massive"], maximumParticles: 10_000_000)
        #expect(
            given.record.stepSchedule?.description == "0:2,160:1" && given.record.stepSchedule?.margin == nil)
        #expect(given.arguments.contains("0:2,160:1") && !given.arguments.contains("--dt-judge"))
        let read = try JSONDecoder().decode(SceneFolder.Hires.self, from: given.record.encoded())
        #expect(read == given.record)

        // The massive pass ran and switched; the full pass follows it, whatever it is asked.
        var ran = given.record
        ran.stepsRun = 1_000
        ran.stepSwitches = [
            .init(step: 3, myr: 0.3, scale: 2, frame: nil),
            .init(step: record.settle, myr: 150, scale: 1, frame: 0),
        ]
        try ran.encoded().write(to: folder.hires)
        try Data().write(to: folder.take)
        let full = try folder.hiresArguments(
            draw + ["--pass", "full", "--dt-schedule", "off"], maximumParticles: 10_000_000)
        let index = try #require(full.arguments.firstIndex(of: "--dt-switches"))
        #expect(full.arguments[index + 1] == "3:2,\(record.settle):1")
        #expect(!full.arguments.contains("--dt-schedule") && full.record.stepsToRun == 1_000)
    }
}
