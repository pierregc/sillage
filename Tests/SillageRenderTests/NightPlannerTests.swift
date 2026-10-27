import Foundation
import Testing

@testable import SillageRender

@Suite("Night recipe")
struct NightRecipeTests {
    private func recipe(_ json: String) throws -> NightRecipe {
        try NightRecipe.decoded(from: Data(json.utf8))
    }

    @Test func aSettingLeftOutIsAuto() throws {
        let night = try recipe(#"{"version": 1}"#)
        #expect(night == NightRecipe())
        #expect(night.explore.scenes == .auto && night.pick == .auto && night.export == .auto)
        #expect(night.hiresParticles(maximum: 10_000_000) == 2_000_000)
        #expect(night.hiresParticles(maximum: 1_000_000) == 1_000_000)
        #expect(night.exports == ["4k", "vertical"])
    }

    @Test func everySettingTakesAutoOrAValue() throws {
        let night = try recipe(
            """
            {"version": 1, "hours": 1,
             "explore": {"scenes": 6, "particlesPerGalaxy": 50000, "archetypeShare": 0.5,
                         "archetypes": ["antennae", "mice"], "galaxies": [2, 3], "seed": "auto"},
             "pick": 2, "hires": {"particles": 150000, "frames": 300},
             "style": {"world": "telescope", "style": "auto", "palette": "auto"},
             "export": ["1080p", "webp"]}
            """)
        #expect(night.explore.scenes == .value(6) && night.explore.seed == .auto)
        #expect(night.galaxyRange == 2...3 && night.explore.archetypes.value == ["antennae", "mice"])
        #expect(night.pick == .count(2) && night.hires.frames == .value(300))
        #expect(night.style.world == .value("telescope") && night.style.palette == .auto)
        #expect(night.exports == ["1080p", "webp"])
        #expect(try NightRecipe.decoded(from: night.encoded()) == night)
        #expect(try recipe(#"{"pick": "none"}"#).pick == NightRecipe.Selection.none)
    }

    @Test func aMisspeltOrWrongSettingIsAnError() {
        #expect(throws: NightRecipe.Failure.unknownKey("explore.particles")) {
            try recipe(#"{"explore": {"particles": 5}}"#)
        }
        #expect(throws: NightRecipe.Failure.unknownKey("picks")) { try recipe(#"{"picks": 2}"#) }
        #expect(throws: NightRecipe.Failure.version(2)) { try recipe(#"{"version": 2}"#) }
        for bad in [
            #"{"pick": 5}"#, #"{"pick": "some"}"#, #"{"deliver": "07:00", "hours": 8}"#,
            #"{"deliver": "7h"}"#, #"{"export": ["8k"]}"#, #"{"style": {"world": "hubble"}}"#,
            #"{"explore": {"galaxies": [4, 2]}}"#, #"{"explore": {"archetypes": ["kite"]}}"#,
            #"{"explore": {"scenes": "many"}}"#, #"{"hours": 0}"#,
        ] {
            #expect(throws: NightRecipe.Failure.self) { try recipe(bad) }
        }
    }

    @Test func theDeliveryIsTheNextTimeTheClockReadsIt() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
        let evening = RunStatus.date("2026-10-27T22:00:00+01:00")!
        let early = RunStatus.date("2026-10-28T03:00:00+01:00")!
        var night = NightRecipe()
        #expect(
            try night.deliverBy(now: evening, calendar: calendar)
                == RunStatus.date("2026-10-28T07:00:00+01:00"))
        #expect(
            try night.deliverBy(now: early, calendar: calendar) == RunStatus.date("2026-10-28T07:00:00+01:00")
        )
        night.deliver = .value("06:30")
        #expect(
            try night.deliverBy(now: evening, calendar: calendar)
                == RunStatus.date("2026-10-28T06:30:00+01:00"))
        night.deliver = .value("2026-10-29T08:00:00+01:00")
        #expect(
            try night.deliverBy(now: evening, calendar: calendar)
                == RunStatus.date("2026-10-29T08:00:00+01:00"))
        night.deliver = .auto
        night.hours = .value(8)
        #expect(try night.deliverBy(now: evening, calendar: calendar) == evening.addingTimeInterval(8 * 3600))
        #expect(NightRecipe.daySeed(evening, calendar: calendar) == 20_261_027)
    }
}

@Suite("Night planner")
struct NightPlannerTests {
    private let start = RunStatus.date("2026-10-25T21:25:24+02:00")!

    /// The library's model on 2026-10-26, fitted on 52 explored scenes and 6 hires runs.
    private let model = CostModel(
        updated: RunStatus.date("2026-10-26T19:16:04Z")!,
        explore: .init(fixedSeconds: 20.905, secondsPerUnit: 1.2171e-7, source: .fitted, samples: 52),
        hires: .init(fixedSeconds: 0, secondsPerUnit: 1.5185e-7, source: .scaled, samples: 6))

    /// The 35 scenes of the 2026-10-25 night, particles and steps from its `index.csv`.
    private static let night: [(particles: Int, steps: Int)] = [
        (200000, 3600), (200000, 3600), (300000, 3600), (200000, 4500), (100000, 3600), (200000, 3600),
        (300000, 3600), (400000, 3600), (200000, 4500), (200000, 3600), (200000, 3600), (400000, 4500),
        (300000, 3600), (200000, 3600), (200000, 5400), (100000, 3600), (400000, 3600), (300000, 3600),
        (200000, 3600), (400000, 3600), (200000, 3600), (200000, 4500), (500000, 3600), (200000, 5400),
        (200000, 3600), (300000, 5400), (400000, 3600), (200000, 4500), (200000, 4500), (200000, 3600),
        (300000, 5400), (200000, 3600), (300000, 3600), (200000, 3600), (500000, 4500),
    ]

    /// Its four picks: score, hires steps at 2 M with the settle, and the minutes they took.
    private static let picks: [(name: String, score: Double, steps: Int, minutes: Double)] = [
        ("scene-0031", 0.9988, 13_000, 64.5), ("scene-0023", 0.9659, 15_680, 78.4),
        ("scene-0034", 0.8909, 10_000, 51.9), ("scene-0018", 0.8564, 10_000, 53.6),
    ]

    private static func drawn(_ particles: Int, _ steps: Int, score: Double? = nil, name: String? = nil)
        -> NightScene
    {
        NightScene(
            name: name, score: score, exploreUnits: Double(particles) * Double(400 + steps),
            hiresUnits: 2e6 * Double(steps * 5 / 2 + 1_000), frames: 900)
    }

    private func recipe(scenes: Int? = 35, perGalaxy: Int? = 100_000) -> NightRecipe {
        var recipe = NightRecipe()
        recipe.explore.scenes = scenes.map { .value($0) } ?? .auto
        recipe.explore.particlesPerGalaxy = perGalaxy.map { .value($0) } ?? .auto
        recipe.export = .value(["4k"])
        return recipe
    }

    /// Draws whose cost grows with the count a galaxy as the night's did: steps with its square
    /// root, so a galaxy of 100 000 runs the night's own scenes.
    private static func scaled(_ perGalaxy: Int) -> [NightScene] {
        let factor = Double(perGalaxy) / 100_000
        return night.prefix(NightPlanner.sample).map {
            var scene = drawn($0.particles, $0.steps)
            scene.exploreUnits *= factor * factor.squareRoot()
            return scene
        }
    }

    private func planner(_ recipe: NightRecipe, progress: NightProgress = NightProgress())
        -> NightPlanner
    {
        NightPlanner(
            recipe: recipe, model: model, maximumParticles: 10_000_000, progress: progress,
            freeBytes: 500e9
        ) { _ in Self.night.map { Self.drawn($0.particles, $0.steps) } }
    }

    @Test func theExplorationOfTheTwentyFifthTakesItsNinetyTwoMinutes() throws {
        let plan = planner(recipe()).plan(now: start, deliverBy: start.addingTimeInterval(9 * 3600))
        let explore = try #require(plan.steps.first)
        #expect(explore.phase == .explore && explore.count == 35 && explore.particles == 100_000)
        // 35 done in 5502 s, four at once.
        #expect(abs(explore.seconds / 5_502 - 1) < 0.10)
        #expect(plan.summaries.first?.end == start.addingTimeInterval(explore.seconds))
    }

    @Test func itsFourHiresTakeFiftyFourToSeventyNineMinutes() throws {
        var progress = NightProgress()
        progress.exploreDone = true
        progress.explored = Self.picks.map {
            NightScene(
                name: $0.name, score: $0.score, exploreUnits: 0, hiresUnits: 2e6 * Double($0.steps),
                frames: 900)
        }
        progress.picks = Self.picks.map(\.name)
        let now = start.addingTimeInterval(5_502)
        var recipe = recipe()
        recipe.pick = .count(4)
        let plan = planner(recipe, progress: progress).plan(
            now: now, deliverBy: now.addingTimeInterval(8 * 3600))
        let hires = plan.steps.filter { $0.phase == .hires }
        #expect(hires.map(\.scene) == Self.picks.map(\.name) && hires.allSatisfy(\.fits))
        for (step, pick) in zip(hires, Self.picks) {
            #expect(abs(step.seconds / 60 / pick.minutes - 1) < 0.10, "\(pick.name)")
            #expect(step.particles == 2_000_000)
        }
        // Each hires is followed by its style and its 4K export, then the next scene.
        #expect(
            plan.steps.dropFirst(2).prefix(3).map(\.phase) == [.hires, .style, .export])
        #expect(plan.end == plan.steps.last?.end && plan.picks == 4)
        let summary = try #require(plan.summaries.first { $0.phase == .hires })
        #expect(summary.count == 4 && summary.start == now)
    }

    @Test func autoPicksAsManyOfTheBestAsFitAndNeverFewerThanTwo() {
        var progress = NightProgress()
        progress.exploreDone = true
        progress.explored = Self.night.enumerated().map { index, scene in
            Self.drawn(scene.particles, scene.steps, score: Double(index) / 100, name: "scene-\(index)")
        }
        let planner = planner(recipe(), progress: progress)
        let ranked = NightPlanner.ranked(progress.explored)
        #expect(ranked.first?.name == "scene-34")
        let one = planner.finishSeconds(ranked[0])
        for (hours, expected) in [(12.0, 4), (1.0, 2), (0.1, 2)] {
            let end = start.addingTimeInterval(hours * 3600)
            #expect(planner.autoPicks(ranked, from: start, deliverBy: end) == expected, "\(hours) h")
        }
        let three = ranked.prefix(3).reduce(0) { $0 + planner.finishSeconds($1) }
        #expect(planner.autoPicks(ranked, from: start, deliverBy: start.addingTimeInterval(three + 1)) == 3)
        #expect(one > 0)
        #expect(planner.autoPicks(Array(ranked.prefix(1)), from: start, deliverBy: start) == 1)
        let plan = planner.plan(now: start, deliverBy: start.addingTimeInterval(three + 1))
        #expect(plan.picks == 3 && plan.steps.filter { $0.phase == .hires }.allSatisfy(\.fits))
    }

    @Test func aHiresThatCannotBeFinishedBeforeTheDeliveryDoesNotStart() throws {
        var progress = NightProgress()
        progress.exploreDone = true
        progress.explored = [
            Self.drawn(200_000, 5_400, score: 0.9, name: "long"),
            Self.drawn(200_000, 3_600, score: 0.8, name: "short"),
        ]
        progress.picks = ["long", "short"]
        let planner = planner(recipe(), progress: progress)
        let short = planner.finishSeconds(progress.explored[1])
        let plan = planner.plan(now: start, deliverBy: start.addingTimeInterval(short + 60))
        let steps = Dictionary(grouping: plan.steps.filter { $0.scene != nil }, by: { $0.scene! })
        #expect(steps["long"]?.allSatisfy { !$0.fits } == true)
        #expect(steps["short"]?.allSatisfy(\.fits) == true)
        #expect(plan.end <= plan.deliverBy && plan.warnings.map(\.kind) == ["late"])
    }

    @Test func anExportMayEndWithinTheGraceButNotPastIt() throws {
        var progress = NightProgress()
        progress.exploreDone = true
        progress.explored = [Self.drawn(200_000, 3_600, score: 0.9, name: "scene-0001")]
        progress.picks = ["scene-0001"]
        progress.hiresDone = ["scene-0001"]
        progress.styled = ["scene-0001"]
        var recipe = recipe()
        recipe.export = .value(["1080p", "4k"])
        let planner = planner(recipe, progress: progress)
        let late = start.addingTimeInterval(-NightPlanner.grace + 30)
        let plan = planner.plan(now: start, deliverBy: late)
        let exports = plan.steps.filter { $0.phase == .export }
        #expect(exports.map(\.fits) == [true, false])
        #expect(exports[0].end <= late.addingTimeInterval(NightPlanner.grace))
    }

    @Test func whatIsDoneCostsNothing() throws {
        var progress = NightProgress()
        progress.exploreDone = true
        progress.explored = [Self.drawn(200_000, 3_600, score: 0.9, name: "scene-0001")]
        progress.picks = ["scene-0001"]
        progress.hiresDone = ["scene-0001"]
        progress.exported = ["scene-0001/4k"]
        let plan = planner(recipe(), progress: progress).plan(
            now: start, deliverBy: start.addingTimeInterval(3_600))
        #expect(plan.steps.map(\.done) == [true, true, true, false, true])
        #expect(plan.steps.filter(\.done).allSatisfy { $0.seconds == 0 })
        #expect(plan.end.timeIntervalSince(start) == NightPlanner.styleSeconds)
        #expect(plan.diskBytes == 0)
    }

    @Test func autoExploresFiftyScenesAtTheLargestCountThatLeavesRoomForFourPicks() throws {
        let planner = NightPlanner(
            recipe: recipe(scenes: nil, perGalaxy: nil), model: model,
            maximumParticles: 10_000_000, freeBytes: 500e9, draws: Self.scaled)
        let long = planner.plan(now: start, deliverBy: start.addingTimeInterval(10 * 3600))
        #expect(long.scenes == 50 && long.picks == 4)
        #expect(NightRecipe.perGalaxyLadder.contains(long.particlesPerGalaxy))
        #expect(long.end <= long.deliverBy && long.warnings.isEmpty)
        let explore = long.steps[0]
        #expect(explore.seconds <= long.exploreBudget)

        let short = planner.plan(now: start, deliverBy: start.addingTimeInterval(4 * 3600))
        #expect(short.particlesPerGalaxy <= long.particlesPerGalaxy)
        #expect(short.picks >= 2 && short.picks <= long.picks)
        #expect(short.end <= short.deliverBy)

        // Too short for anything: the smallest night, and the plan says it is late.
        let none = planner.plan(now: start, deliverBy: start.addingTimeInterval(1_800))
        #expect(none.particlesPerGalaxy == 50_000 && none.picks == 2)
        #expect(!none.warnings.isEmpty)
    }

    @Test func aBatchAlreadyStartedKeepsItsCountAndExploresOnlyWhatIsLeft() throws {
        var progress = NightProgress()
        progress.perGalaxy = 100_000
        progress.explored = Self.night.prefix(20).enumerated().map { index, scene in
            Self.drawn(scene.particles, scene.steps, score: 0.5, name: "scene-\(index)")
        }
        let whole = planner(recipe()).plan(now: start, deliverBy: start.addingTimeInterval(9 * 3600))
        let resumed = planner(recipe(perGalaxy: 200_000), progress: progress).plan(
            now: start, deliverBy: start.addingTimeInterval(9 * 3600))
        #expect(resumed.particlesPerGalaxy == 100_000 && resumed.scenes == 35)
        #expect(abs(resumed.steps[0].seconds / whole.steps[0].seconds - 15.0 / 35) < 1e-9)
    }

    @Test func noneStopsAfterExploring() {
        var recipe = recipe()
        recipe.pick = .none
        let plan = planner(recipe).plan(now: start, deliverBy: start.addingTimeInterval(9 * 3600))
        #expect(plan.steps.map(\.phase) == [.explore, .pick] && plan.picks == 0)
    }

    @Test func theDiskMustHoldThePreviewsTakesAndVideos() {
        var planner = planner(recipe())
        planner.freeBytes = 1e9
        let plan = planner.plan(now: start, deliverBy: start.addingTimeInterval(9 * 3600))
        // 35 previews, and a 2 M take of 900 frames weighs 2.76 GB.
        #expect(plan.diskBytes > 35 * 40e6 + 2.7e9)
        #expect(plan.warnings.contains { $0.kind == "disk" })
        #expect(abs(NightPlanner.videoBytes("4k", frames: 900) / 187e6 - 1) < 0.01)
        #expect(NightPlanner.videoBytes("whatsapp", frames: 1_800) <= 15e6)
    }
}
