import Foundation
import Testing

@testable import SillageRender

@Suite("Cost model")
struct CostModelTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func temporaryLibrary() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("costs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ url: URL, _ text: String, modified: Date? = nil) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
    }

    private func samples(_ sizes: [Double], fixed: Double, rate: Double) -> [CostModel.Sample] {
        sizes.enumerated().map { index, units in
            CostModel.Sample(
                units: units, seconds: fixed + rate * units,
                date: now.addingTimeInterval(Double(index) * 60))
        }
    }

    @Test func fitsBothTermsOnSyntheticHistory() {
        let line = CostModel.fit(
            samples([1e9, 2e9, 3e9, 5e9, 8e9], fixed: 30, rate: 200e-9),
            fallback: CostModel.fallbackExplore)
        #expect(line.source == .fitted && line.samples == 5 && line.rejected == 0)
        #expect(abs(line.fixedSeconds - 30) < 1e-6)
        #expect(abs(line.secondsPerUnit - 200e-9) < 1e-15)
    }

    @Test func fallsBackWithoutHistoryAndScalesWithLittle() {
        #expect(CostModel.fit([], fallback: CostModel.fallbackHires) == CostModel.fallbackHires)
        // One size only: the fixed part and the rate cannot be told apart.
        let line = CostModel.fit(
            samples([2e10, 2e10], fixed: 0, rate: 300e-9), fallback: CostModel.fallbackHires)
        #expect(line.source == .scaled)
        #expect(abs(line.secondsPerUnit - 300e-9) < 1e-15)

        let model = CostModel.fallback(at: now)
        #expect(abs(model.hiresSeconds(particles: 2_000_000, steps: 10_000) - 3_000) < 1e-6)
        // Four at once, 126 ns a particle step and 4 s per scene finished.
        #expect(abs(model.exploreSeconds(particles: 200_000, steps: 4_000) - 4 * 104.8) < 1e-6)
        let frames = model.exportSeconds(preset: VideoPreset.all[0], codec: .hevc, frames: 900)
        #expect(abs(frames - 30 / 1.23) < 1e-6)
        #expect(
            abs(model.exportSeconds(preset: VideoPreset.all[1], codec: .hevc, frames: 900) - 30 / 0.64) < 1e-6
        )
    }

    @Test func leavesOutRunsSlowerThanTwiceTheMedian() {
        var history = samples([1e9, 2e9, 3e9, 4e9, 6e9], fixed: 10, rate: 150e-9)
        history.append(
            CostModel.Sample(units: 3e9, seconds: 3 * (10 + 150e-9 * 3e9), date: now))
        let line = CostModel.fit(history, fallback: CostModel.fallbackHires)
        #expect(line.rejected == 1 && line.samples == 5)
        #expect(abs(line.secondsPerUnit - 150e-9) < 1e-15)
    }

    @Test func recentRunsWeighMore() {
        let old = (0..<4).map {
            CostModel.Sample(
                units: 1e10, seconds: 2_000, date: now.addingTimeInterval(-Double($0) * 60 - 10 * 86_400))
        }
        let recent = CostModel.Sample(units: 1e10, seconds: 1_500, date: now)
        let line = CostModel.fit(old + [recent], fallback: CostModel.fallbackHires)
        #expect(abs(line.seconds(1e10) - 1_500) < 5)
    }

    /// A batch of three that never ran four at once, read from the scene logs' end times.
    @Test func readsHistoryFromTheLibraryAndKeepsItInCostsJSON() throws {
        let root = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let batch = root.appendingPathComponent("2026-10-25")
        try write(
            batch.appendingPathComponent("index.csv"),
            "id,particles,settle,steps,wall_seconds,status\n"
                + "scene-0001,100000,400,3600,100,ok\nscene-0002,200000,400,3600,100,ok\n"
                + "scene-0003,300000,400,3600,100,ok\nscene-0004,300000,400,3600,,rejected\n")
        try write(batch.appendingPathComponent("batch.log"), "2026-10-25 19:05:25 start: seed 1, 4 at once\n")
        for scene in 1...3 {
            try write(batch.appendingPathComponent(".logs/scene-000\(scene).log"), "", modified: now)
        }
        try write(
            batch.appendingPathComponent("scene-0001/hires.json"),
            #"{"particles": 2000000, "previewParticles": 200000, "width": 960, "height": 540, "#
                + #""frames": 900, "fps": 30, "settle": 1000, "steps": 9000, "timeStepScale": 3.5, "#
                + #""timeStep": 0.0168, "timeStepMyr": 0.079, "previewTimeStepMyr": 0.198, "#
                + #""softening": 0.057, "clipStartMyr": 79, "clipEndMyr": 791, "seconds": 3200}"#)
        try write(
            batch.appendingPathComponent("events.jsonl"),
            #"{"t": "2026-10-26T03:12:00+01:00", "kind": "export.done", "scene": "scene-0001", "preset": "4k", "codec": "hevc", "frames": 900, "seconds": 25}"#
                + "\n" + #"{"t": "2026-10-26T03:13:00+01:00", "kind": "phase.done"}"# + "\n")

        let history = CostHistory.read(library: root)
        #expect(history.explore.count == 3)
        #expect(
            history.explore.allSatisfy { abs($0.alongside - 3) < 1e-6 && abs($0.seconds - 100.0 / 3) < 1e-6 })
        #expect(history.hires.map(\.seconds) == [3200])
        #expect(history.exports["4k/hevc"]?.map(\.units) == [900])

        let model = try CostModel.refresh(library: root, at: now)
        #expect(CostModel.stored(library: root) == model)
        #expect(model.hires.source == .scaled && model.exports["4k/hevc"]?.source == .scaled)
        #expect(abs(model.exportSeconds(preset: VideoPreset.all[1], codec: .hevc, frames: 900) - 25) < 1e-6)

        let rows = CostModel.check(history, batch: "2026-10-25")
        #expect(rows.count == 4 && rows.filter { $0.kind == "hires" }.count == 1)
    }

    @Test func aFolderWithNoRunsGetsNoFile() throws {
        let root = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        try write(root.appendingPathComponent("loose/scene-0001/scene.json"), "{}")
        _ = try CostModel.refresh(library: root)
        #expect(!FileManager.default.fileExists(atPath: CostModel.url(library: root).path))
        #expect(CostModel.current(library: root).explore == CostModel.fallbackExplore)
    }
}
