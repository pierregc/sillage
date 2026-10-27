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
            particles=0; frames=0; preset=""; world=""
            while [ $# -gt 0 ]; do
                case "$1" in
                    --particles) particles="$2"; shift 2 ;;
                    --frames) frames="$2"; shift 2 ;;
                    --preset|--format) preset="$2"; shift 2 ;;
                    --world) world="$2"; shift 2 ;;
                    *) shift ;;
                esac
            done
            case "$command" in
                hires)
                    sleep "$(cat '\(root.path)/hires-seconds' 2>/dev/null || echo 0.2)"
                    touch "$scene/take.sillage"
                    echo "{\\"particles\\": $particles, \\"previewParticles\\": 40000, \\"width\\": 960,
                      \\"height\\": 540, \\"frames\\": $frames, \\"fps\\": 30, \\"settle\\": 1, \\"steps\\": 1,
                      \\"timeStepScale\\": 3.5, \\"timeStep\\": 0.01, \\"timeStepMyr\\": 0.05,
                      \\"previewTimeStepMyr\\": 0.1, \\"softening\\": 0.1, \\"clipStartMyr\\": 0,
                      \\"clipEndMyr\\": 100}" > "$scene/hires.json" ;;
                look) [ -f "$scene/look-raw.json" ] || cp "$scene/look.json" "$scene/look-raw.json"
                    cp '\(root.path)'/styled-"$world".look.json "$scene/look.json" ;;
                export) mkdir -p "$scene/exports"; touch "$scene/exports/$preset.mp4" ;;
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

    private func runner(_ recipe: NightRecipe) -> NightRunner {
        NightRunner(
            folder: NightFolder(batch: batch, recipe: recipe, maximumParticles: 10_000_000),
            executable: stage, exploreScript: explore, catalogue: [], poll: 0.05,
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
        // Auto alternates the worlds across the picks, best first, and says which it chose.
        let looks = calls.filter { $0.hasPrefix("look ") }
        #expect(looks.count == 2)
        #expect(looks[0].contains("scene-0002 --style auto --world telescope"))
        #expect(looks[1].contains("scene-0003 --style auto --world free"))
        let styled = events.filter { $0.kind == RunEvent.Kind.style }
        #expect(styled.map(\.world) == ["telescope", "free"])
        #expect(styled.map(\.family) == ["hubble-visible", "aurora"])
        #expect(styled.allSatisfy { $0.harmony == "analogous" && $0.seed == 7 })
        #expect(
            events.filter { $0.kind == RunEvent.Kind.phaseDone }.compactMap(\.phase) == ["explore", "pick"])
        let report = try String(contentsOf: batch.appendingPathComponent("report.md"), encoding: .utf8)
        #expect(report.contains("scene-0002 (0,90)") && report.contains("terminée"))
        #expect(FileManager.default.fileExists(atPath: batch.appendingPathComponent("recipe.json").path))
        #expect(
            ActivityFile.read(from: RunStatusFiles.activity(library: batch.deletingLastPathComponent()))?
                .night == nil)

        // The same night again: everything is there, nothing runs.
        #expect(runner(recipe()).run() == 0)
        #expect(logged() == calls)
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
        // Ten million particles at the fallback's 150 ns a step: minutes, in a night of seconds.
        #expect(runner(recipe(hours: 0.005, particles: 10_000_000)).run() == 0)
        #expect(!logged().contains { $0.hasPrefix("hires ") })
        let skips = events.filter { $0.kind == RunEvent.Kind.skip }
        #expect(skips.map(\.scene) == ["scene-0002", "scene-0003"])
        #expect(skips.allSatisfy { $0.message == "would end after the delivery time" })
        #expect(NightFile.read(from: RunStatusFiles.night(batch: batch))?.state == .done)
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
