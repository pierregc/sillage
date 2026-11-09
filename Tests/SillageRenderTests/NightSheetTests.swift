import Foundation
import Testing

@testable import SillageRender

/// A class, so that each test's libraries go when Swift Testing drops the instance it ran on.
@Suite("Night sheet")
final class NightSheetTests {
    private static let paris = TimeZone(identifier: "Europe/Paris")!
    private static let evening = RunStatus.date("2026-10-27T21:40:00+01:00")!

    private static let model = CostModel(
        updated: RunStatus.date("2026-10-26T19:16:04Z")!,
        explore: .init(fixedSeconds: 20.905, secondsPerUnit: 1.2171e-7, source: .fitted, samples: 52),
        hires: .init(fixedSeconds: 0, secondsPerUnit: 1.5185e-7, source: .scaled, samples: 6))

    /// Sixteen draws of the size of the 2026-10-25 night, scaled with the count a galaxy.
    private static func draws(_ perGalaxy: Int) -> [NightScene] {
        let factor = Double(perGalaxy) / 100_000
        return (0..<16).map { index in
            let particles = 200_000 + 100_000 * (index % 3)
            let steps = 3_600 + 900 * (index % 3)
            return NightScene(
                name: nil, score: nil,
                exploreUnits: Double(particles) * Double(400 + steps) * factor * factor.squareRoot(),
                hiresUnits: 2e6 * Double(steps * 5 / 2 + 1_000), frames: 900)
        }
    }

    private let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("sillage-nightsheet-\(UUID().uuidString)", isDirectory: true)

    deinit { try? FileManager.default.removeItem(at: root) }

    private func library() throws -> URL {
        let url = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func planner(_ library: URL, free: Double? = 500e9) -> NightSheetPlanner {
        NightSheetPlanner(
            library: library, now: Self.evening, model: Self.model, maximumParticles: 10_000_000,
            freeBytes: free, timeZone: Self.paris, draws: Self.draws)
    }

    @Test func aSheetLeftAloneIsAnAutoNightForSevenInTheMorning() throws {
        let recipe = NightSheet().recipe()
        #expect(recipe.deliver == .value("07:00") && recipe.hours == .auto)
        #expect(recipe.pick == .auto && recipe.style.world == .auto && recipe.export == .auto)
        #expect(recipe.exports == ["4k", "vertical"])
        #expect(!NightSheet().customised)
        try recipe.validate()
    }

    @Test func eachSettingOfTheSheetReachesTheRecipe() throws {
        var sheet = NightSheet()
        sheet.timing = .hours
        sheet.hours = 6.5
        sheet.hiresScenes = 3
        sheet.world = "telescope"
        sheet.vertical = false
        var recipe = sheet.recipe()
        #expect(recipe.hours == .value(6.5) && recipe.deliver == .auto)
        #expect(recipe.pick == .count(3) && recipe.style.world == .value("telescope"))
        #expect(recipe.exports == ["4k"])
        #expect(sheet.customised)
        try recipe.validate()

        sheet.timing = .deliver
        sheet.deliverMinutes = 6 * 60 + 5
        sheet.exploreOnly = true
        sheet.fourK = false
        recipe = sheet.recipe()
        #expect(recipe.deliver == .value("06:05") && recipe.pick == NightRecipe.Selection.none)
        #expect(recipe.exports.isEmpty)
        try recipe.validate()
        // What was written is read back by the night.
        #expect(try NightRecipe.decoded(from: recipe.encoded()) == recipe)
    }

    @Test func theLastSettingsStartTheNextSheet() throws {
        let library = try library()
        #expect(NightSheet.last(library: library) == NightSheet())
        var sheet = NightSheet()
        sheet.timing = .hours
        sheet.hours = 9
        sheet.world = "free"
        try sheet.keep(library: library)
        #expect(NightSheet.last(library: library) == sheet)
        try Data("nope".utf8).write(to: NightSheet.url(library: library))
        #expect(NightSheet.last(library: library) == NightSheet())
    }

    @Test func thePlanGivesEachStepItsDurationAndEnd() throws {
        let plan = planner(try library()).plan(NightSheet(), now: Self.evening)
        let titles = plan.lines.map(\.title)
        #expect(titles == ["Previews", "High resolution", "Style", "Videos"])
        let explore = try #require(plan.lines.first)
        #expect(explore.detail.hasPrefix("about ") && explore.detail.hasSuffix("scenes"))
        #expect(explore.until.hasPrefix("until ") && explore.duration.contains("h"))
        #expect(explore.text == "Previews · \(explore.detail) · \(explore.duration) · \(explore.until)")
        #expect(plan.lines[1].detail.hasSuffix(" at 8 M particles"))
        #expect(plan.delivery == "Ready tomorrow by 07:00")
        #expect(plan.margin.hasPrefix("Expected to end at ") && plan.margin.hasSuffix(" to spare"))
        #expect(plan.warnings.isEmpty)
    }

    @Test func aChangeShowsInTheNextPlan() throws {
        let planner = planner(try library())
        var sheet = NightSheet()
        let base = planner.nightPlan(sheet, now: Self.evening)
        sheet.exploreOnly = true
        #expect(planner.plan(sheet, now: Self.evening).lines.map(\.title) == ["Previews"])
        sheet.exploreOnly = false
        sheet.hiresScenes = 2
        let two = planner.nightPlan(sheet, now: Self.evening)
        #expect(two.picks == 2 && two.steps.filter { $0.phase == .hires }.count == 2)
        #expect(base.picks >= 2 && base.end <= base.deliverBy)
        sheet.vertical = false
        sheet.fourK = false
        let none = planner.plan(sheet, now: Self.evening)
        #expect(none.lines.map(\.title) == ["Previews", "High resolution", "Style"])
        sheet.timing = .hours
        sheet.hours = 3
        let short = planner.nightPlan(sheet, now: Self.evening)
        #expect(short.deliverBy == Self.evening.addingTimeInterval(3 * 3600))
    }

    @Test func eachStyleIsPlannedInTheWorldItsPickWillBeDrawn() throws {
        let planner = planner(try library())
        var sheet = NightSheet()
        sheet.timing = .hours
        sheet.hours = 24
        sheet.hiresScenes = 4
        // No batch yet: the night will be drawn from the day's seed.
        let seed = NightRecipe.daySeed(Self.evening)
        let styles = planner.nightPlan(sheet, now: Self.evening).steps.filter { $0.phase == .style }
        #expect(
            styles.map(\.seconds)
                == (0..<4).map {
                    NightStyle.drawnWorld(pick: $0, seed: seed, share: NightRecipe.defaultFreeShare) == .free
                        ? NightPlanner.freeStyleSeconds : NightPlanner.telescopeStyleSeconds
                })
        sheet.world = "free"
        let free = planner.nightPlan(sheet, now: Self.evening).steps.filter { $0.phase == .style }
        #expect(free.count == 4 && free.allSatisfy { $0.seconds == NightPlanner.freeStyleSeconds })
    }

    @Test func aPlanTakesLessThanHalfASecondOnceTheDrawsAreSized() throws {
        let planner = planner(try library())
        planner.warm(now: Self.evening)
        var sheet = NightSheet()
        let clock = ContinuousClock()
        let took = clock.measure {
            for hours in [4.0, 5, 6, 8, 10] {
                sheet.timing = .hours
                sheet.hours = hours
                _ = planner.plan(sheet, now: Self.evening)
            }
        }
        #expect(took < .milliseconds(500))
    }

    @Test func aFullDiskAndALateNightAreWarnedOfWithoutBlocking() throws {
        var sheet = NightSheet()
        sheet.timing = .hours
        sheet.hours = 2
        sheet.hiresScenes = 2
        let plan = planner(try library(), free: 1e9).plan(sheet, now: Self.evening)
        let kinds = plan.warnings.map(\.kind)
        #expect(kinds.contains("disk"))
        let disk = try #require(plan.warnings.first { $0.kind == "disk" })
        #expect(disk.text.contains(" GB is needed and 1.0 GB is left on the disk"))
        #expect(kinds.contains("explore") || kinds.contains("late") || kinds.contains("over"))
        // Still a night that can be launched.
        try sheet.recipe().validate()
    }

    @Test func fewerHiresThanAskedForIsTold() throws {
        var sheet = NightSheet()
        sheet.timing = .hours
        sheet.hours = 1
        sheet.hiresScenes = 4
        let plan = planner(try library()).plan(sheet, now: Self.evening)
        let picks = try #require(plan.warnings.first { $0.kind == "picks" })
        #expect(picks.text.hasPrefix("Only ") && picks.text.contains(" of the 4 scenes asked for"))
        #expect(plan.warnings.allSatisfy { !$0.text.isEmpty })
        // Without a number asked for, there is nothing to fall short of.
        sheet.hiresScenes = nil
        #expect(
            !planner(try library()).plan(sheet, now: Self.evening).warnings.contains { $0.kind == "picks" })
    }

    @Test func theSharedPlannerIsKeptForTheDayAndTheLibrary() throws {
        let one = try library()
        let first = NightSheetPlanner.shared(library: one, now: Self.evening)
        #expect(NightSheetPlanner.shared(library: one, now: Self.evening.addingTimeInterval(60)) === first)
        #expect(
            NightSheetPlanner.shared(library: one, now: Self.evening.addingTimeInterval(86_400)) !== first)
        let other = NightSheetPlanner.shared(library: try library(), now: Self.evening)
        #expect(other !== first)
    }

    @Test func launchingQueuesTheNightWithItsOwnRecipe() throws {
        let library = try library()
        var sheet = NightSheet()
        sheet.hiresScenes = 2
        let (job, runner) = try sheet.launch(library: library, runner: nil, at: Self.evening)
        #expect(runner == nil && job.kind == .night)
        let queue = QueueStore(library: library).read()
        #expect(queue.waiting.map(\.id) == [job.id])
        let file = try #require(job.options.first)
        #expect(file.hasPrefix(library.path))
        #expect(try NightRecipe.read(URL(fileURLWithPath: file)) == sheet.recipe())
        #expect(NightSheet.last(library: library) == sheet)

        // A second night does not overwrite the first one's recipe.
        sheet.hiresScenes = 3
        let (second, _) = try sheet.launch(
            library: library, runner: nil, at: Self.evening.addingTimeInterval(5))
        #expect(second.options != job.options)
        #expect(try NightRecipe.read(URL(fileURLWithPath: file)).pick == .count(2))
    }
}
