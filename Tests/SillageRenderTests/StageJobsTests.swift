import Foundation
import SillageCore
import Testing

@testable import SillageRender

@Suite("Stage jobs")
struct StageJobsTests {
    static let paris = TimeZone(identifier: "Europe/Paris")!
    let folder = SceneFolder(path: "/library/2026-10-26/scene-0023")
    let cost = CostModel.fallback(at: Date(timeIntervalSince1970: 1_800_000_000))
    let made = Date(timeIntervalSince1970: 1_800_000_000)

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.paris
        return calendar
    }

    func at(_ text: String) -> Date { RunStatus.date(text)! }

    func plan(
        _ choice: ExportChoice, _ settings: ExportSettings = ExportSettings(),
        state: ExportFolderState = ExportFolderState(), queue: JobQueue = JobQueue()
    ) -> PlannedJob {
        StageJobs.export(choice, settings, folder: folder, state: state, cost: cost, queue: queue)
    }

    @Test func aFirstExportWritesThePresetsOwnFile() {
        let job = plan(.uhd)
        #expect(job.output?.lastPathComponent == "4k.mp4")
        #expect(!job.replaces)
        #expect(job.options == ["--preset", "4k", "--out", folder.exports.path + "/4k.mp4"])
    }

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

    @Test func theSameExportAfterANewTakeReplacesItsFile() {
        let state = ExportFolderState(files: ["1080p.mp4": made], lookChanged: made.addingTimeInterval(-60))
        let job = plan(.hd, state: state)
        #expect(job.replaces && job.output?.lastPathComponent == "1080p.mp4")
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

    @Test func previewsAreAnimations() {
        let job = plan(.gif)
        #expect(job.options.prefix(2) == ["--format", "gif"])
        #expect(job.output?.lastPathComponent == "preview.gif")
        #expect(job.seconds != nil)
    }

    @Test func aRequestAlreadyQueuedIsNotAddedTwice() {
        var queue = JobQueue()
        let first = plan(.hd)
        queue.add(.export, path: folder.url.path, options: first.options, at: made)
        let again = plan(.hd, queue: queue)
        #expect(again.queued && again.output == first.output)
        // Another range of the same preset waits for its own name.
        var range = ExportSettings()
        range.start = 5
        #expect(plan(.hd, range, queue: queue).output?.lastPathComponent == "1080p-2.mp4")

        queue.add(.hires, path: folder.url.path + "/", options: ["--particles", "2000000"], at: made)
        #expect(
            StageJobs.hires(folder, particles: 5_000_000, massive: 2_000_000, cost: cost, queue: queue).queued
        )
    }

    @Test func autoTakesTheMostThatEndsBeforeTheMorning() {
        let now = at("2026-10-27T22:00:00.000+01:00")
        // An hour for each million: nine hours to seven, and Auto stops at a night's 8 M.
        let hourPerMillion = { (particles: Int) -> Double? in Double(particles) / 1_000_000 * 3600 }
        #expect(
            StageJobs.autoParticles(
                seconds: hourPerMillion, start: now, now: now, calendar: calendar, maximum: 10_000_000)
                == 8_000_000)
        // Two hours ahead in the queue leave seven.
        #expect(
            StageJobs.autoParticles(
                seconds: hourPerMillion, start: now.addingTimeInterval(7200), now: now,
                calendar: calendar, maximum: 10_000_000) == 7_000_000)
        // In the morning everything fits: a night's 8 M, or the machine's maximum below it.
        let morning = at("2026-10-28T08:00:00.000+01:00")
        #expect(
            StageJobs.autoParticles(
                seconds: hourPerMillion, start: morning, now: morning, calendar: calendar,
                maximum: 10_000_000) == 8_000_000)
        #expect(
            StageJobs.autoParticles(
                seconds: hourPerMillion, start: morning, now: morning, calendar: calendar,
                maximum: 6_200_000) == 6_200_000)
        // Nothing fits: the least offered.
        let late = at("2026-10-28T06:30:00.000+01:00")
        #expect(
            StageJobs.autoParticles(
                seconds: hourPerMillion, start: late, now: late, calendar: calendar,
                maximum: 10_000_000) == 1_000_000)
    }

    /// A merger explored at 400 000 particles, as a night's batch writes it.
    private func explored() throws -> SceneFolder {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stagejobs-\(UUID().uuidString)").appendingPathComponent("scene-0001")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let folder = SceneFolder(url)
        var scene = SceneConfig.merger(particleCount: 400_000)
        scene.solver = .barnesHut
        scene.timeStepScale = 3.5
        try SceneFile(scene).encoded().write(to: folder.scene)
        var clip = SceneFolder.Clip()
        clip.particles = 400_000
        clip.frames = 900
        clip.steps = 7_200
        clip.settle = 400
        try clip.encoded().write(to: folder.clip)
        return folder
    }

    /// Compute draws as a night does: past 2 M, 2 M carry the mass and the others are light
    /// tracers, priced as such. A real count is asked with no massive count.
    @Test func aHiresIsDrawnAsANightDrawsIt() throws {
        #expect(StageJobs.massive(drawing: 8_000_000) == 2_000_000)
        #expect(StageJobs.massive(drawing: 1_000_000) == 1_000_000)
        #expect(StageJobs.autoCeiling(maximum: 10_000_000) == 8_000_000)
        #expect(StageJobs.autoCeiling(maximum: 5_000_000) == 5_000_000)

        let scene = try explored()
        defer { try? FileManager.default.removeItem(at: scene.batch) }
        let queue = JobQueue()
        let traced = StageJobs.hires(
            scene, particles: 8_000_000, massive: 2_000_000, cost: cost, queue: queue)
        #expect(traced.options == ["--particles", "8000000", "--massive", "2000000"])
        #expect(traced.title == "8\u{A0}M (2\u{A0}M massive)")
        let real = StageJobs.hires(scene, particles: 8_000_000, massive: nil, cost: cost, queue: queue)
        #expect(real.options == ["--particles", "8000000"] && real.title == "8\u{A0}M")
        let all = StageJobs.hires(scene, particles: 2_000_000, massive: 2_000_000, cost: cost, queue: queue)
        #expect(all.options == ["--particles", "2000000"] && all.title == "2\u{A0}M")
        #expect(traced.seconds == (try cost.hiresSeconds(scene, particles: 8_000_000, massive: 2_000_000)))
        #expect((traced.seconds ?? .infinity) < (real.seconds ?? 0) * 0.6)

        let job = QueueJob(
            id: 1, kind: .hires, path: scene.url.path, options: traced.options, added: made)
        #expect(StageJobs.title(of: job) == "8\u{A0}M (2\u{A0}M massive)")
        #expect(JobEstimate.seconds(job, cost: cost) == traced.seconds)
    }

    /// A scene explored before its clip was written is priced from the runs measured at #19,
    /// which had no tracers: the massive count's run, and each tracer at a tracer step's cost.
    @Test func theMeasuredFallbackPricesTracersApart() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stagejobs-\(UUID().uuidString)").appendingPathComponent("scene-0001")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let old = SceneFolder(url)
        let twoMillion = try #require(StageJobs.hiresSeconds(old, particles: 2_000_000, cost: cost))
        #expect(twoMillion == 5_100)
        #expect(
            StageJobs.hiresSeconds(old, particles: 2_000_000, massive: 2_000_000, cost: cost) == twoMillion)
        let traced = try #require(
            StageJobs.hiresSeconds(old, particles: 8_000_000, massive: 2_000_000, cost: cost))
        let tracer = cost.tracers.secondsPerUnit / cost.hires.secondsPerUnit
        #expect(abs(traced - twoMillion * (1 + 3 * tracer)) < 1e-6)
        #expect(traced < (StageJobs.hiresSeconds(old, particles: 8_000_000, cost: cost) ?? 0) * 0.6)
        // A folder that is not there has no estimate.
        #expect(StageJobs.hiresSeconds(folder, particles: 8_000_000, massive: 2_000_000, cost: cost) == nil)
    }

    @Test func theForecastCountsTheQueueAhead() {
        let now = at("2026-10-27T22:00:00.000+01:00")
        var one = plan(.hd)
        one.seconds = 600
        var two = plan(.uhd)
        two.seconds = 1200
        let forecast = StageForecast(
            jobs: [one, two], ahead: 2, paused: false, freeAt: now.addingTimeInterval(3600), now: now,
            timeZone: Self.paris)
        #expect(
            forecast.summary == "2 jobs ahead of these · about 30 min in all · all ready around 23:30")
        #expect(forecast.line(0) == "about 10 min · ready around 23:10")

        let alone = StageForecast(
            jobs: [one], ahead: 0, paused: false, freeAt: now, now: now, timeZone: Self.paris)
        #expect(alone.summary == "Starts right away · ready around 22:10")

        let unknown = StageForecast(
            jobs: [one], ahead: 1, paused: false, freeAt: nil, now: now, timeZone: Self.paris)
        #expect(unknown.summary == "1 job ahead of this one · end time unknown")

        let paused = StageForecast(
            jobs: [one], ahead: 1, paused: true, freeAt: nil, now: now, timeZone: Self.paris)
        #expect(paused.summary == "Queue paused · 1 job ahead of this one")

        var queued = one
        queued.queued = true
        #expect(
            StageForecast(jobs: [queued], ahead: 1, paused: false, freeAt: now, now: now).summary
                == "Already in the queue")
    }

    @Test func theQueueSaysWhenItIsFree() {
        var queue = JobQueue()
        let now = at("2026-10-27T22:00:00.000+01:00")
        let job = queue.add(.hires, path: folder.url.path, options: ["--particles", "1000000"], at: now)
        let idle = QueueStatus(.init(activity: nil, queue: JobQueue(), now: now, timeZone: Self.paris))
        #expect(idle.freeAt == now && idle.ahead == 0)
        let waiting = QueueStatus(
            .init(activity: nil, queue: queue, now: now, timeZone: Self.paris, estimate: { _ in 600 }))
        #expect(waiting.freeAt == now.addingTimeInterval(600) && waiting.ahead == 1)
        _ = job
    }
}
