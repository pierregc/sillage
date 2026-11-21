import Foundation
import SillageCore
import Testing

@testable import SillageRender

extension StageJobsTests {
    @Test func anotherCodecOrStyleWritesAFileOfItsOwn() {
        var settings = ExportSettings()
        settings.codec = .prores
        settings.look = StageLook(name: "aurora", file: URL(fileURLWithPath: "/l/aurora.look.json"))
        let state = ExportFolderState(files: ["1080p.mp4": made])
        let job = plan(.hd, settings, state: state)
        #expect(job.output?.lastPathComponent == "1080p-aurora-prores.mov")
        #expect(ExportedFile.names(of: "1080p-aurora-prores").style == "aurora")
        #expect(job.options.contains("--look") && job.options.contains("--codec"))
        // WhatsApp keeps its codec whatever Advanced says.
        #expect(plan(.whatsapp, settings).output?.lastPathComponent == "whatsapp-aurora.mp4")
    }

    @Test func aNewStyleOrARangeKeepsTheOldFile() {
        let newStyle = ExportFolderState(files: ["1080p.mp4": made], lookChanged: made.addingTimeInterval(60))
        let job = plan(.hd, state: newStyle)
        #expect(!job.replaces && job.output?.lastPathComponent == "1080p-2.mp4")
        #expect(ExportedFile.names(of: "1080p-2").preset == "1080p")

        var range = ExportSettings()
        range.duration = 20
        let state = ExportFolderState(files: ["1080p.mp4": made, "1080p-2.mp4": made])
        #expect(plan(.hd, range, state: state).output?.lastPathComponent == "1080p-3.mp4")
    }
}
