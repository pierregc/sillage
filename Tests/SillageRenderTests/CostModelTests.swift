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
        #expect(abs(model.hiresSeconds(particles: 2_000_000, steps: 10_000) - 1_240) < 1e-6)
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

    /// The massive steps fitted as before on the runs without tracers, the tracers on what the
    /// runs with tracers took past that, through zero: every night draws 8 M from 2 M, so its
    /// runs alone could not tell the two apart.
    @Test func fitsTheTracersApartFromTheMassiveSteps() {
        var history = samples([1e10, 2e10, 3e10, 5e10], fixed: 100, rate: 60e-9)
        for (index, steps) in [9_000.0, 15_000, 28_000].enumerated() {
            history.append(
                CostModel.Sample(
                    units: 2e6 * steps, tracerUnits: 6e6 * steps,
                    seconds: 100 + 60e-9 * 2e6 * steps + 22e-9 * 6e6 * steps,
                    date: now.addingTimeInterval(600 + Double(index) * 60)))
        }
        let (massive, tracers) = CostModel.fitHires(history)
        #expect(massive.source == .fitted && massive.samples == 4)
        #expect(abs(massive.fixedSeconds - 100) < 1e-6 && abs(massive.secondsPerUnit - 60e-9) < 1e-15)
        #expect(tracers.source == .scaled && tracers.samples == 3 && tracers.fixedSeconds == 0)
        #expect(abs(tracers.secondsPerUnit - 22e-9) < 1e-15)

        let model = CostModel(
            updated: now, explore: CostModel.fallbackExplore, hires: massive, tracers: tracers)
        #expect(
            abs(model.hiresSeconds(particles: 8_000_000, massive: 2_000_000, steps: 10_000) - 2_620) < 1e-6)
        // Without tracers a run is priced as it always was.
        #expect(model.hiresSeconds(particles: 2_000_000, steps: 10_000) == massive.seconds(2e10))
        #expect(
            model.hiresSeconds(particles: 2_000_000, massive: 8_000_000, steps: 10_000)
                == massive.seconds(2e10))
        // No run with tracers yet: the fallback's 21 ns a tracer step (#187, #241).
        #expect(CostModel.fitHires(Array(history.prefix(4))).tracers == CostModel.fallbackTracers)
        #expect(model.lines.contains { $0.hasPrefix("tracers    22.0 ns a light tracer step") })
    }

    /// scene-0031 drawn at 8 M from 2 M in 38 min (#187): its steps read apart, and with no
    /// run without tracers the massive part is the fallback's.
    @Test func aHiresWithTracersCountsItsMassiveAndTracerStepsApart() throws {
        let root = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let batch = root.appendingPathComponent("2026-11-04")
        try write(
            batch.appendingPathComponent("scene-0031/hires.json"),
            #"{"particles": 8000000, "massive": 2000000, "previewParticles": 200000, "width": 1600, "#
                + #""height": 900, "frames": 923, "fps": 30, "settle": 1584, "steps": 7384, "#
                + #""timeStepScale": 3.5, "timeStep": 0.0021, "timeStepMyr": 0.0989, "#
                + #""previewTimeStepMyr": 0.2, "softening": 0.0546, "clipStartMyr": 157, "#
                + #""clipEndMyr": 887, "seconds": 2280}"#, modified: now)
        let history = CostHistory.read(library: root)
        let sample = try #require(history.hires.first)
        #expect(sample.units == 2e6 * 8_968 && sample.tracerUnits == 6e6 * 8_968)
        let model = try CostModel.refresh(library: root, at: now)
        #expect(model.hires == CostModel.fallbackHires && model.tracers.source == .scaled)
        #expect(
            abs(model.hiresSeconds(particles: 8_000_000, massive: 2_000_000, steps: 8_968) - 2_280) < 1e-6)
        #expect(CostModel.stored(library: root) == model)
        let rows = CostModel.check(history, batch: "2026-11-04")
        #expect(rows.count == 1 && rows[0].kind == "hires" && rows[0].took == 2_280)
    }

    /// Two passes (#239): the massive pass is a run without tracers, the full pass one with
    /// them less its drawing, and each preset's frame is priced against the particles drawn.
    /// The full pass's videos are left out of the exports' lines.
    @Test func twoPassesPriceTheMassiveRunTheTracersAndTheDrawingApart() throws {
        let root = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let batch = root.appendingPathComponent("2026-11-10")
        try write(
            batch.appendingPathComponent("scene-0031/hires.json"),
            #"{"particles": 8000000, "massive": 2000000, "pass": "massive", "previewParticles": 200000, "#
                + #""width": 960, "height": 540, "frames": 923, "fps": 30, "settle": 1584, "#
                + #""steps": 7384, "timeStepScale": 3.5, "timeStep": 0.021, "timeStepMyr": 0.0989, "#
                + #""previewTimeStepMyr": 0.2, "softening": 0.0546, "clipStartMyr": 157, "#
                + #""clipEndMyr": 887, "seconds": 1000, "full": {"presets": ["4k", "vertical"], "#
                + #""frames": 923, "seconds": 2600, "drawSeconds": {"4k": 92.3, "vertical": 46.15}, "#
                + #""keyFrames": [0, 207, 922], "drift": 0, "checkedFrames": 232}}"#, modified: now)
        try write(
            batch.appendingPathComponent("events.jsonl"),
            #"{"t": "2026-11-10T03:12:00+01:00", "kind": "export.done", "preset": "4k", "codec": "hevc", "frames": 923, "seconds": 92.3, "pass": "full"}"#
                + "\n")
        let history = CostHistory.read(library: root)
        #expect(history.hires.count == 2 && history.exports.isEmpty)
        let alone = try #require(history.hires.first { $0.tracerUnits == 0 })
        #expect(alone.units == 2e6 * 8_968 && alone.seconds == 1_000)
        let traced = try #require(history.hires.first { $0.tracerUnits > 0 })
        #expect(traced.tracerUnits == 6e6 * 8_968 && abs(traced.seconds - (2_600 - 138.45)) < 1e-6)
        #expect(history.draws["4k/hevc"]?.map(\.units) == [8e6])
        #expect(abs((history.draws["4k/hevc"]?.first?.seconds ?? 0) - 0.1) < 1e-9)

        let model = try CostModel.refresh(library: root, at: now)
        #expect(model.hires.source == .scaled && model.tracers.source == .scaled)
        let uhd = try #require(VideoPreset.named("4k"))
        #expect(abs(model.drawSeconds(preset: uhd, particles: 8_000_000, frames: 923) - 92.3) < 1e-6)
        #expect(model.draws["vertical/hevc"]?.source == .scaled)
        #expect(
            abs(
                model.fullPassSeconds(
                    particles: 8_000_000, massive: 2_000_000, steps: 8_968, frames: 923,
                    presets: ["4k", "vertical"]) - 2_600) < 1e-6)
        #expect(model.lines.contains { $0.hasPrefix("draw       4k/hevc") })
        // Without a full pass yet, the fallback: a frame at 4K and at 1080p's pixels.
        let fallback = CostModel.fallback()
        #expect(fallback.drawLine(preset: uhd) == CostModel.fallbackDraw(uhd))
        let vertical = try #require(VideoPreset.named("vertical"))
        #expect(CostModel.fallbackDraw(vertical).fixedSeconds == CostModel.fallbackDrawFixed1080p)
    }

    /// A `costs.json` written before light tracers has no line for them, and reads with theirs.
    @Test func aCostsFileWrittenBeforeTracersReadsWithTheirFallback() throws {
        let root = try temporaryLibrary()
        defer { try? FileManager.default.removeItem(at: root) }
        let line =
            #""fixedSeconds": 108.3, "rejected": 0, "samples": 9, "#
            + #""secondsPerUnit": 6.24e-08, "source": "fitted""#
        try write(
            CostModel.url(library: root),
            #"{"explore": {\#(line)}, "exports": {}, "hires": {\#(line)}, "#
                + #""updated": "2026-10-31T07:46:40Z", "version": 1}"#)
        let model = try #require(CostModel.stored(library: root))
        #expect(model.hires.secondsPerUnit == 6.24e-8 && model.tracers == CostModel.fallbackTracers)
        #expect(abs(model.hiresSeconds(particles: 2_000_000, steps: 10_000) - (108.3 + 1_248)) < 1e-6)
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
