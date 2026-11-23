import Foundation
import Testing

@testable import SillageRender

@Suite("The JSON summary of a run")
struct RunSummaryTests {
    @Test("It lists the files written since the start, outside hidden folders")
    func written() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
            "summary-\(UUID().uuidString)")
        let manager = FileManager.default
        try manager.createDirectory(
            at: folder.appendingPathComponent(".checkpoint"), withIntermediateDirectories: true)
        try manager.createDirectory(
            at: folder.appendingPathComponent("exports"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: folder) }
        let old = folder.appendingPathComponent("scene.json")
        try Data("{}".utf8).write(to: old)
        try manager.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old.path)
        let started = Date()
        try Data(count: 1234).write(to: folder.appendingPathComponent("exports/1080p.mp4"))
        try Data(count: 5).write(to: folder.appendingPathComponent(".checkpoint/state"))
        let summary = RunSummary(
            command: "export", engine: "metal", target: folder, extra: nil, destination: "-", started: started
        )
        summary.status = 0
        let record = summary.record()
        #expect(record.written.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["1080p.mp4"])
        #expect(record.written.first?.bytes == 1234)
        #expect(record.command == "export" && record.status == 0 && record.error == nil)
    }

    @Test("The destination is read from the arguments")
    func destination() {
        #expect(RunSummary.destination(in: ["--preset", "4k", "--summary", "-"]) == "-")
        #expect(RunSummary.destination(in: ["--summary"]) == nil)
        #expect(RunSummary.destination(in: []) == nil)
    }
}
