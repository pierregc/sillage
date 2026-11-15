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

    /// A schedule is a spike option for a hires in one pass, and its record keeps it.
    @Test func aHiresRecordsItsSchedule() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch-\(UUID().uuidString)").appendingPathComponent("scene-0001")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let folder = SceneFolder(url)
        defer { try? FileManager.default.removeItem(at: folder.batch) }
        var scene = SceneConfig.merger(particleCount: 400_000)
        scene.solver = .barnesHut
        try SceneFile(scene).encoded().write(to: folder.scene)
        try SceneFolder.Clip().encoded().write(to: folder.clip)
        let plain = try folder.hiresArguments(["--particles", "2e6"], maximumParticles: 10_000_000)
        let scheduled = try folder.hiresArguments(
            ["--particles", "2e6", "--dt-schedule", "0:2,160:1"], maximumParticles: 10_000_000)
        #expect(plain.record.stepSchedule == nil)
        #expect(!String(decoding: try plain.record.encoded(), as: UTF8.self).contains("stepSchedule"))
        #expect(scheduled.record.stepSchedule?.description == "0:2,160:1")
        #expect(scheduled.arguments.contains("--dt-schedule"))
        let read = try JSONDecoder().decode(SceneFolder.Hires.self, from: scheduled.record.encoded())
        #expect(read == scheduled.record)
        #expect(throws: SceneFolder.HiresError.self) {
            try folder.hiresArguments(
                ["--particles", "8e6", "--massive", "2e6", "--pass", "massive", "--dt-schedule", "0:2"],
                maximumParticles: 10_000_000)
        }
    }
}
