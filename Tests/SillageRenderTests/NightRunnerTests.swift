import Foundation
import SillageCore
import Testing

@testable import SillageRender

/// A night run against stand-ins for `explore-batch.sh` and the stages: scenes copied from a
/// template, a hires that writes its record after a pause, an export that touches its file.
/// Every call is logged, so a resumed night can be seen to call nothing.
@Suite("Night runner")
struct NightRunnerTests {
    let root: URL
    let batch: URL
    let calls: URL
    let stage: URL
    let explore: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("night-\(UUID().uuidString)", isDirectory: true)
        batch = root.appendingPathComponent("library/2026-10-28", isDirectory: true)
        calls = root.appendingPathComponent("calls.log")
        stage = root.appendingPathComponent("sillage-render")
        explore = root.appendingPathComponent("explore-batch.sh")
        let template = root.appendingPathComponent("template", isDirectory: true)
        for (index, score) in [(1, 0.4), (2, 0.9), (3, 0.7)] {
            let folder = SceneFolder(template.appendingPathComponent(String(format: "scene-%04d", index)))
            try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
            var file = SceneFile(BatchDraw(batchSeed: 1).scene(at: index, particleCount: 40_000))
            file.solver = .barnesHut
            file.timeStepScale = 3.5
            try file.encoded().write(to: folder.scene)
            var clip = SceneFolder.Clip()
            clip.particles = 40_000
            clip.frames = 30
            clip.steps = 300
            clip.settle = 50
            try clip.encoded().write(to: folder.clip)
            var look = LookFile.raw
            look.palette = [GalaxyColours(SIMD3(1, 0.5, 0.2)), GalaxyColours(SIMD3(0.3, 0.7, 1))]
            try look.encoded().write(to: folder.look)
            try Data(#"{"score": \#(score)}"#.utf8).write(to: folder.interest)
        }
        for (world, family) in [(Palette.World.telescope, "hubble-visible"), (.free, "aurora")] {
            var styled = LookFile.standard
            styled.name = "styled-\(world.rawValue)"
            styled.world = world
            styled.paletteRecipe = Palette(
                world: world, family: family, harmony: .analogous, seed: 7,
                colours: [SIMD3(1, 0.5, 0.2), SIMD3(0.3, 0.7, 1)])
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try styled.encoded().write(to: root.appendingPathComponent("styled-\(world.rawValue).look.json"))
        }
        try write(
            explore,
            """
            #!/bin/bash
            echo "explore $*" >> '\(calls.path)'
            while [ $# -gt 0 ]; do case "$1" in --out) out="$2"; shift 2 ;; *) shift ;; esac; done
            cp -R '\(template.path)'/scene-* "$out"/
            printf 'seed=1\\nper_galaxy=20000\\n' > "$out/batch.conf"
            """)
        try write(
            stage,
            """
            #!/bin/bash
            echo "$*" >> '\(calls.path)'
            command="$1"; scene="$2"; shift 2
            particles=0; frames=0; preset=""; format=""; world=""; extra=""; pass=""; export=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --particles) particles="$2"; shift 2 ;;
                    --massive) extra="$extra\\"massive\\": $2, "; shift 2 ;;
                    --pass) pass="$2"; shift 2 ;;
                    --export) export="$2"; shift 2 ;;
                    --frames) frames="$2"; shift 2 ;;
                    --preset) preset="$2"; shift 2 ;;
                    --format) format="$2"; shift 2 ;;
                    --world) world="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done
            [ "$pass" = massive ] && extra="$extra\\"pass\\": \\"massive\\", "
            case "$command" in
                hires)
                    sleep "$(cat '\(root.path)/hires-seconds' 2>/dev/null || echo 0.2)"
                    if [ "$pass" = full ]; then
                        mkdir -p "$scene/exports"
                        for name in ${export//,/ }; do touch "$scene/exports/$name.mp4"; done
                        sed -i '' 's/}$/, "full": {"presets": [], "frames": 1, "seconds": 1, "drawSeconds": {}, "keyFrames": [], "drift": 0, "checkedFrames": 0}}/' "$scene/hires.json"
                        exit 0
                    fi
                    touch "$scene/take.sillage"
                    echo "{$extra\\"particles\\": $particles, \\"previewParticles\\": 40000, \\"width\\": 960,
                      \\"height\\": 540, \\"frames\\": $frames, \\"fps\\": 30, \\"settle\\": 1, \\"steps\\": 1,
                      \\"timeStepScale\\": 3.5, \\"timeStep\\": 0.01, \\"timeStepMyr\\": 0.05,
                      \\"previewTimeStepMyr\\": 0.1, \\"softening\\": 0.1, \\"clipStartMyr\\": 0,
                      \\"clipEndMyr\\": 100}" > "$scene/hires.json" ;;
                look) [ -f "$scene/look-raw.json" ] || cp "$scene/look.json" "$scene/look-raw.json"
                    cp '\(root.path)'/styled-"$world".look.json "$scene/look.json" ;;
                export) mkdir -p "$scene/exports"
                    if [ -n "$format" ]; then touch "$scene/exports/preview.$format"
                    else touch "$scene/exports/$preset.mp4"; fi ;;
            esac
            """)
    }

    private func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func recipe(hours: Double = 10, particles: Int = 100_000) -> NightRecipe {
        var recipe = NightRecipe()
        recipe.hours = .value(hours)
        recipe.explore.scenes = .value(3)
        recipe.explore.particlesPerGalaxy = .value(20_000)
        recipe.pick = .count(2)
        recipe.hires.particles = .value(particles)
        recipe.hires.frames = .value(30)
        recipe.export = .value(["1080p"])
        return recipe
    }

    private func runner(_ recipe: NightRecipe, catalogue: [LookFile] = []) -> NightRunner {
        NightRunner(
            folder: NightFolder(batch: batch, recipe: recipe, maximumParticles: 10_000_000),
            executable: stage, exploreScript: explore, catalogue: catalogue, poll: 0.05,
            handlesSignals: false,
            draws: { perGalaxy in
                [
                    NightScene(
                        name: nil, score: nil, exploreUnits: Double(perGalaxy) * 1_000, hiresUnits: 1e6,
                        frames: 30)
                ]
            }, say: { _ in })
    }

    private func logged() -> [String] {
        ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    private var events: [RunEvent] {
        RunEvent.decodeLines(
            (try? String(contentsOf: RunStatusFiles.events(batch: batch), encoding: .utf8)) ?? "")
    }

    /// The night's own job in its library's queue, running in this process.
    private func queueJob(_ change: (inout QueueJob) -> Void = { _ in }) throws -> QueueStore {
        let store = QueueStore(library: batch.deletingLastPathComponent())
        try store.change { queue in
            let job = queue.add(.night, path: batch.path, options: [], at: Date())
            try queue.start(job.id, pid: getpid(), pidStarted: nil, log: nil, at: Date())
            if let index = queue.jobs.firstIndex(where: { $0.id == job.id }) { change(&queue.jobs[index]) }
        }
        return store
    }

    @Test func aNightRunsEveryStepThenResumesWithNothingLeftToDo() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(runner(recipe()).run() == 0)
        let calls = logged()
        #expect(calls.filter { $0.hasPrefix("explore ") }.count == 1)
        #expect(
            calls.filter { $0.hasPrefix("hires ") }.map {
                URL(fileURLWithPath: $0.split(separator: " ")[1].description).lastPathComponent
            } == ["scene-0002", "scene-0003"])
        #expect(calls.filter { $0.hasPrefix("export ") }.count == 2)
        #expect(calls.contains { $0.contains("--particles 100000 --frames 30") })

        let ratings = SceneRatings.read(batch: batch)
        #expect(ratings.chosen == ["scene-0002", "scene-0003"])
        #expect(
            ratings.scenes["scene-0002"]?.picked?.score == 0.9 && ratings.scenes["scene-0002"]?.choice == nil)
        for name in ["scene-0002", "scene-0003"] {
            let scene = SceneFolder(batch.appendingPathComponent(name))
            #expect(FileManager.default.fileExists(atPath: scene.rawLook.path))
            let look = try LookFile.decoded(from: Data(contentsOf: scene.look))
            #expect(look.name.hasPrefix("styled-") && look.paletteRecipe?.seed == 7)
            #expect(FileManager.default.fileExists(atPath: scene.export(preset: "1080p").path))
        }

        let night = try #require(NightFile.read(from: RunStatusFiles.night(batch: batch)))
        #expect(night.state == .done && night.endedAt != nil && night.deliverBy != nil)
        #expect(night.phases.map(\.name) == ["explore", "pick", "hires", "style", "export"])
        #expect(
            night.phases.map(\.done) == [3, 2, 2, 2, 2] && night.phases.map(\.planned) == [3, 2, 2, 2, 2])
        #expect(night.recipe["hiresParticles"] == "100000" && night.recipe["scenes"] == "3")
        let kinds = events.map(\.kind)
        #expect(kinds.first == RunEvent.Kind.nightStart && kinds.last == RunEvent.Kind.nightDone)
        #expect(kinds.filter { $0 == RunEvent.Kind.pick }.count == 2)
        #expect(kinds.filter { $0 == RunEvent.Kind.style }.count == 2)
        // Auto draws each pick's world from the batch seed, best first, and says which it chose.
        let worlds = (0..<2).map {
            NightStyle.drawnWorld(pick: $0, seed: 1, share: NightRecipe.defaultFreeShare).rawValue
        }
        let looks = calls.filter { $0.hasPrefix("look ") }
        #expect(looks.count == 2)
        #expect(looks[0].contains("scene-0002 --style auto --world \(worlds[0])"))
        #expect(looks[1].contains("scene-0003 --style auto --world \(worlds[1])"))
        let styled = events.filter { $0.kind == RunEvent.Kind.style }
        #expect(styled.map(\.world) == worlds)
        #expect(styled.map(\.family) == worlds.map { $0 == "free" ? "aurora" : "hubble-visible" })
        #expect(styled.allSatisfy { $0.harmony == "analogous" && $0.seed == 7 })
        #expect(
            events.filter { $0.kind == RunEvent.Kind.phaseDone }.compactMap(\.phase) == ["explore", "pick"])
        let report = try String(contentsOf: batch.appendingPathComponent("report.md"), encoding: .utf8)
        #expect(report.contains("scene-0002 (0.90)") && report.contains("- State: finished"))
        #expect(FileManager.default.fileExists(atPath: batch.appendingPathComponent("recipe.json").path))
        #expect(
            ActivityFile.read(from: RunStatusFiles.activity(library: batch.deletingLastPathComponent()))?
                .night == nil)

        // The same night again: everything is there, nothing runs.
        #expect(runner(recipe()).run() == 0)
        #expect(logged() == calls)
    }

    @Test func aResumedNightGivesEachPickTheWorldItWasDrawn() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        var recipe = recipe()
        // Seed 1 draws 0.76 for the first pick and 0.56 for the second.
        recipe.style.freeShare = .value(0.6)
        let worlds = (0..<2).map { NightStyle.drawnWorld(pick: $0, seed: 1, share: 0.6) }
        try #require(worlds == [.telescope, .free])
        let store = try queueJob()
        try Data("2".utf8).write(to: root.appendingPathComponent("hires-seconds"))
        // Stopped once the first pick has its style, before the second pick's.
        let calls = calls
        Thread.detachNewThread {
            while !((try? String(contentsOf: calls, encoding: .utf8)) ?? "").contains("look ") {
                Thread.sleep(forTimeInterval: 0.05)
            }
            try? store.change { queue in
                if let id = queue.running?.id { try queue.stopAfterStep(id, at: Date()) }
            }
        }
        #expect(runner(recipe).run() == 3)
        var looks = logged().filter { $0.hasPrefix("look ") }
        #expect(
            looks.count == 1 && looks.first?.contains("scene-0002 --style auto --world telescope") == true)

        // The plan the folder makes in between has the second pick in the world it was drawn.
        let folder = NightFolder(batch: batch, recipe: recipe, maximumParticles: 10_000_000)
        let plan = folder.planner(now: Date(), draws: { _ in [] }).plan(
            now: Date(), deliverBy: Date().addingTimeInterval(3600))
        let style = try #require(plan.steps.first { $0.phase == .style && $0.scene == "scene-0003" })
        #expect(!style.done && style.seconds == NightPlanner.freeStyleSeconds)

        // Resumed by a runner of its own, as the queue starts one.
        try store.change { $0.jobs.removeAll() }
        #expect(runner(recipe).run() == 0)
        looks = logged().filter { $0.hasPrefix("look ") }
        #expect(looks.count == 2 && looks.last?.contains("scene-0003 --style auto --world free") == true)
        #expect(events.filter { $0.kind == RunEvent.Kind.style }.map(\.world) == ["telescope", "free"])
        #expect(NightFile.read(from: RunStatusFiles.night(batch: batch))?.recipe["freeShare"] == "0.6")
    }

    /// Auto's styles hold the dust back by themselves; a named one is promoted as generated so
    /// it does too (#174).
    @Test func aNamedStyleIsPromotedAsAGeneratedOne() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        var recipe = recipe()
        recipe.style.style = .value("hubble")
        var hubble = LookFile.standard
        hubble.name = "hubble"
        hubble.world = .telescope
        #expect(runner(recipe, catalogue: [hubble]).run() == 0)
        let looks = logged().filter { $0.hasPrefix("look ") }
        #expect(looks.count == 2)
        #expect(looks.allSatisfy { $0.contains("--world telescope --base hubble --generated") })
    }

    @Test func theFolderPlansWithTheNightsSeedAndTheNamedPalettesWorld() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        var recipe = recipe()
        recipe.explore.seed = .value(5)
        func planner(_ recipe: NightRecipe, seed: UInt64? = nil) -> NightPlanner {
            NightFolder(batch: batch, recipe: recipe, maximumParticles: 10_000_000)
                .planner(now: Date(), seed: seed, draws: { _ in [] })
        }
        #expect(planner(recipe).seed == 5)
        try Data("seed=7\nper_galaxy=20000\n".utf8).write(to: batch.appendingPathComponent("batch.conf"))
        #expect(planner(recipe).seed == 7 && planner(recipe, seed: 9).seed == 9)
        #expect(planner(recipe).paletteWorld == nil)
        recipe.style.palette = .value("ember")
        #expect(planner(recipe).paletteWorld == .free)
    }

    @Test func aSkipLeavesTheCurrentSceneOutAndTheNightGoesOn() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try queueJob()
        try Data("3".utf8).write(to: root.appendingPathComponent("hires-seconds"))
        let night = runner(recipe())
        // A thread of its own: the test pool may be full of other tests that block.
        let calls = calls
        Thread.detachNewThread {
            while !((try? String(contentsOf: calls, encoding: .utf8)) ?? "").contains("hires ") {
                Thread.sleep(forTimeInterval: 0.05)
            }
            try? store.change { queue in
                if let id = queue.running?.id { try queue.skip(id, at: Date()) }
            }
        }
        #expect(night.run() == 0)
        let skip = try #require(events.first { $0.kind == RunEvent.Kind.skip })
        #expect(skip.scene == "scene-0002" && skip.stage == "hires" && skip.message == "skipped by hand")
        let scene = SceneFolder(batch.appendingPathComponent("scene-0002"))
        #expect(scene.storedHires() == nil && !FileManager.default.fileExists(atPath: scene.rawLook.path))
        #expect(SceneFolder(batch.appendingPathComponent("scene-0003")).storedHires() != nil)
        let file = try #require(NightFile.read(from: RunStatusFiles.night(batch: batch)))
        #expect(file.state == .done && file.phases.first { $0.name == "hires" }?.skipped == 1)
    }

    /// Auto draws 8 M from 2 M massive (#211): the hires is asked with both counts, and a real
    /// 8 M already done stands for it.
    @Test func theNightAsksForEightMillionFromTwoAndTakesARealEightAsDone() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        var recipe = NightRecipe()
        let folder = NightFolder(batch: batch, recipe: recipe, maximumParticles: 10_000_000)
        #expect(folder.hiresOptions == ["--particles", "8000000", "--massive", "2000000"])
        let scene = SceneFolder(batch.appendingPathComponent("scene-0001"))
        try FileManager.default.createDirectory(at: scene.url, withIntermediateDirectories: true)
        func record(_ particles: Int, massive: Int?) throws {
            try SceneFolder.Hires(
                particles: particles, massive: massive, previewParticles: 40_000, width: 960,
                height: 540, frames: 30, fps: 30, settle: 1, steps: 1, timeStepScale: 3.5,
                timeStep: 0.01, timeStepMyr: 0.05, previewTimeStepMyr: 0.1, softening: 0.1,
                clipStartMyr: 0, clipEndMyr: 100
            ).encoded().write(to: scene.hires)
        }
        try record(8_000_000, massive: 2_000_000)
        #expect(folder.hiresDone(scene))
        try record(8_000_000, massive: nil)
        #expect(folder.hiresDone(scene))
        try record(8_000_000, massive: 1_000_000)
        #expect(!folder.hiresDone(scene))
        try record(2_000_000, massive: nil)
        #expect(!folder.hiresDone(scene))
        recipe.hires.massive = .value(8_000_000)
        let real = NightFolder(batch: batch, recipe: recipe, maximumParticles: 10_000_000)
        #expect(real.hiresOptions == ["--particles", "8000000"])
        try record(8_000_000, massive: 2_000_000)
        #expect(!real.hiresDone(scene))
    }

    /// `hires.passes: 2` (#239): each pick's massive particles run alone, the style is chosen on
    /// their take, then one full pass draws every video preset; previews still come from the
    /// take. A resumed night finds it all done.
    @Test func aNightInTwoPassesDrawsTheVideosInTheFullPass() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        var recipe = recipe()
        recipe.hires.massive = .value(50_000)
        recipe.hires.passes = .value(2)
        recipe.export = .value(["1080p", "square", "webp"])
        #expect(runner(recipe).run() == 0)
        let calls = logged()
        let hires = calls.filter { $0.hasPrefix("hires ") }
        #expect(hires.count == 4)
        let massive = "--particles 100000 --massive 50000 --frames 30 --pass massive"
        #expect(hires.filter { $0.hasSuffix(massive) }.count == 2)
        #expect(hires.filter { $0.hasSuffix("--pass full --export 1080p,square") }.count == 2)
        let exports = calls.filter { $0.hasPrefix("export ") }
        #expect(exports.count == 2 && exports.allSatisfy { $0.hasSuffix("--format webp") })
        // The massive pass, the style, then the full pass, scene after scene.
        let order = calls.filter { !$0.hasPrefix("explore ") }.map { $0.split(separator: " ")[0] }
        #expect(order == ["hires", "look", "hires", "export", "hires", "look", "hires", "export"])
        for name in ["scene-0002", "scene-0003"] {
            let scene = SceneFolder(batch.appendingPathComponent(name))
            for format in ["1080p", "square"] {
                #expect(FileManager.default.fileExists(atPath: scene.export(preset: format).path))
            }
            #expect(scene.storedHires()?.pass == .massive && scene.storedHires()?.full != nil)
        }
        let night = try #require(NightFile.read(from: RunStatusFiles.night(batch: batch)))
        #expect(night.phases.map(\.done) == [3, 2, 2, 2, 6] && night.recipe["hiresPasses"] == "2")

        #expect(runner(recipe).run() == 0)
        #expect(logged() == calls)
    }

    @Test func stopAfterTheStepEndsTheNightStopped() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try queueJob { $0.stopAfterStep = true }
        #expect(runner(recipe()).run() == 3)
        #expect(logged().map { String($0.prefix(7)) } == ["explore"])
        let night = try #require(NightFile.read(from: RunStatusFiles.night(batch: batch)))
        #expect(night.state == .stopped)
        #expect(events.last?.kind == RunEvent.Kind.nightDone && events.last?.status == "stopped")
        #expect(SceneRatings.read(batch: batch).chosen.isEmpty)
    }

    @Test func aHiresThatCannotEndBeforeTheDeliveryIsNotStarted() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        // Ten million particles at the fallback's 62 ns a step: minutes, in a night of seconds.
        #expect(runner(recipe(hours: 0.005, particles: 10_000_000)).run() == 0)
        #expect(!logged().contains { $0.hasPrefix("hires ") })
        let skips = events.filter { $0.kind == RunEvent.Kind.skip }
        #expect(skips.map(\.scene) == ["scene-0002", "scene-0003"])
        #expect(skips.allSatisfy { $0.message == "would end after the delivery time" })
        #expect(NightFile.read(from: RunStatusFiles.night(batch: batch))?.state == .done)
        let report = batch.appendingPathComponent("report.md")
        #expect(
            try String(contentsOf: report, encoding: .utf8).contains("- Left out: 2 · errors: 0"))

        // Resumed with the time it lacked, as 2026-10-30-b was.
        #expect(runner(recipe()).run() == 0)
        #expect(logged().filter { $0.hasPrefix("hires ") }.count == 2)
        let resumed = try String(contentsOf: report, encoding: .utf8)
        #expect(resumed.contains("- Left out: 0 · errors: 0") && !resumed.contains("would end"))
    }

    @Test func theFolderReadsEachScenesGalaxiesAndTheBatchsPairShare() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let drafts = BatchDraw(batchSeed: 1).drafts(2, particleCount: 40_000)
        try #require(drafts[0].galaxyCount != 2 && drafts[1].galaxyCount == 2)
        for (index, draft) in drafts.enumerated() {
            let folder = SceneFolder(batch.appendingPathComponent(String(format: "scene-%04d", index + 1)))
            try FileManager.default.createDirectory(at: folder.url, withIntermediateDirectories: true)
            try SceneFile(draft).encoded().write(to: folder.scene)
            try SceneFolder.Clip().encoded().write(to: folder.clip)
        }
        let folder = NightFolder(batch: batch, recipe: recipe(), maximumParticles: 10_000_000)
        #expect(folder.progress().explored.map(\.galaxies) == drafts.map(\.galaxyCount))
        // The recipe's share until the batch has a batch.conf, then the batch's own, and none
        // for a batch started before the share.
        #expect(folder.probe(now: Date()).pairShare == 0.8)
        let conf = batch.appendingPathComponent("batch.conf")
        for (line, share) in [("pair_share=0.5\n", 0.5), ("pair_share=off\n", nil), ("", nil)]
            as [(String, Double?)]
        {
            try Data("seed=1\nper_galaxy=20000\n\(line)".utf8).write(to: conf)
            #expect(folder.probe(now: Date()).pairShare == share, "\(line)")
        }
        try FileManager.default.removeItem(at: conf)
        var ranged = recipe()
        ranged.explore.galaxies = .value([2, 4])
        #expect(NightFolder(batch: batch, recipe: ranged).probe(now: Date()).pairShare == nil)
    }

    /// A new batch explores at 7 (#225); one started before keeps the step and settle it recorded.
    @Test func theProbeKeepsTheStepItsBatchStartedWith() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = NightFolder(batch: batch, recipe: recipe(), maximumParticles: 10_000_000)
        let fresh = folder.probe(now: Date())
        #expect(fresh.dtScale == 7 && fresh.settle == 375)
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        try Data("seed=1\nper_galaxy=20000\ndt_scale=3.5\nsettle=750\n".utf8).write(
            to: batch.appendingPathComponent("batch.conf"))
        let started = folder.probe(now: Date())
        #expect(started.dtScale == 3.5 && started.settle == 750)
    }

    @Test func theExplorationIsGivenThePairShareTheRecipeNames() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        var recipe = recipe()
        recipe.pick = .none
        var asked: [String] = []
        for share in [nil, 0.5] as [Double?] {
            for galaxies in [nil, [2, 4]] as [[Int]?] {
                try? FileManager.default.removeItem(at: batch)
                recipe.explore.pairShare = share.map { .value($0) } ?? .auto
                recipe.explore.galaxies = galaxies.map { .value($0) } ?? .auto
                #expect(runner(recipe).run() == 0)
                asked.append(logged().last { $0.hasPrefix("explore ") } ?? "")
            }
        }
        // Auto is the script's own default, and a galaxy range turns the share off there.
        #expect(asked.map { $0.contains("--pair-share 0.5") } == [false, false, true, false])
        #expect(asked.filter { $0.contains("--pair-share") }.count == 1)
    }

    @Test func theQueueMarksANightItHadToStop() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: batch, withIntermediateDirectories: true)
        let started = NightFile(id: "2026-10-28", phases: [], startedAt: Date())
        try RunStatusFiles.write(started.encoded(), to: RunStatusFiles.night(batch: batch))
        NightFile.mark(batch, .paused)
        #expect(NightFile.read(from: RunStatusFiles.night(batch: batch))?.state == .paused)
        NightFile.mark(batch, .stopped, ended: Date())
        let night = try #require(NightFile.read(from: RunStatusFiles.night(batch: batch)))
        #expect(night.state == .stopped && night.endedAt != nil)
        // A night that ended on its own keeps its state.
        NightFile.mark(batch, .failed, ended: Date())
        #expect(NightFile.read(from: RunStatusFiles.night(batch: batch))?.state == .stopped)
    }
}
