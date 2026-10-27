import Foundation
import SillageCore

/// A night's folder as the night reads it: what its batch was started with, what each scene
/// has done, and the plan for what is left.
public struct NightFolder: Sendable {
    public let batch: URL
    public let recipe: NightRecipe
    public let maximumParticles: Int

    public init(batch: URL, recipe: NightRecipe, maximumParticles: Int = SceneFolder.maximumParticles()) {
        self.batch = batch.standardizedFileURL
        self.recipe = recipe
        self.maximumParticles = maximumParticles
    }

    public var library: URL { batch.deletingLastPathComponent() }
    public var id: String { batch.lastPathComponent }
    public var hiresParticles: Int { recipe.hiresParticles(maximum: maximumParticles) }

    /// `batch.conf`, which `explore-batch.sh` writes on its first run and keeps to.
    public var batchConf: [String: String] {
        let text =
            (try? String(contentsOf: batch.appendingPathComponent("batch.conf"), encoding: .utf8)) ?? ""
        var values: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let equals = line.firstIndex(of: "=") else { continue }
            let value = String(line[line.index(after: equals)...])
            if !value.isEmpty { values[String(line[..<equals])] = value }
        }
        return values
    }

    public func seed(now: Date) -> UInt64 {
        batchConf["seed"].flatMap(UInt64.init) ?? recipe.explore.seed.value ?? NightRecipe.daySeed(now)
    }

    public var events: [RunEvent] {
        RunEvent.decodeLines(
            (try? String(contentsOf: RunStatusFiles.events(batch: batch), encoding: .utf8)) ?? "")
    }

    /// The batch's explored scenes, in order.
    public var scenes: [SceneFolder] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: batch.path)) ?? []
        return names.filter { $0.hasPrefix("scene-") }.sorted()
            .map { SceneFolder(batch.appendingPathComponent($0, isDirectory: true)) }
            .filter(\.isExplored)
    }

    /// The hires options the night runs with.
    public var hiresOptions: [String] {
        ["--particles", String(hiresParticles)]
            + (recipe.hires.frames.value.map { ["--frames", String($0)] } ?? [])
    }

    public func hiresDone(_ scene: SceneFolder) -> Bool {
        guard let done = scene.storedHires(), done.particles == hiresParticles else { return false }
        return recipe.hires.frames.value.map { done.frames == $0 } ?? true
    }

    /// Where an export of the recipe lands: a preset's video in its own codec, or a preview.
    public func exportFile(_ scene: SceneFolder, format: String) -> URL {
        VideoPreset.named(format) != nil
            ? scene.export(preset: format) : scene.preview("preview", extension: format)
    }

    public static func score(_ scene: SceneFolder, index: [String: [String: String]]) -> Double? {
        if let data = try? Data(contentsOf: scene.interest),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let score = (object["score"] as? NSNumber)?.doubleValue
        {
            return score
        }
        return index[scene.url.lastPathComponent]?["score"].flatMap(Double.init)
    }

    /// What is done, from the files alone: a night stopped or killed resumes from here.
    public func progress() -> NightProgress {
        var progress = NightProgress()
        progress.perGalaxy = batchConf["per_galaxy"].flatMap(Int.init)
        let index = SceneLibrary.indexRows(batch.appendingPathComponent("index.csv"))
        let ratings = SceneRatings.read(batch: batch)
        let particles = hiresParticles
        for scene in scenes {
            let name = scene.url.lastPathComponent
            let entry = ratings.scenes[name]
            if entry?.choice == .no { continue }
            let record = try? scene.hiresArguments(
                hiresOptions, maximumParticles: max(particles, maximumParticles)
            ).record
            progress.explored.append(
                NightScene(
                    name: name, score: Self.score(scene, index: index), exploreUnits: 0,
                    hiresUnits: Double(particles) * Double((record?.settle ?? 0) + (record?.steps ?? 0)),
                    frames: record?.frames ?? 0, chosenByHand: entry?.choice == .yes))
            if hiresDone(scene) { progress.hiresDone.insert(name) }
            if FileManager.default.fileExists(atPath: scene.rawLook.path) { progress.styled.insert(name) }
            for format in recipe.exports
            where FileManager.default.fileExists(atPath: exportFile(scene, format: format).path) {
                progress.exported.insert("\(name)/\(format)")
            }
        }
        let phases = Set(events.filter { $0.kind == RunEvent.Kind.phaseDone }.compactMap(\.phase))
        progress.exploreDone = phases.contains("explore") || phases.contains("pick")
        if phases.contains("pick") {
            let chosen = Set(ratings.chosen)
            progress.picks = NightPlanner.ranked(progress.explored.filter { chosen.contains($0.name ?? "") })
                .compactMap(\.name)
        }
        return progress
    }

    public static func freeBytes(_ url: URL) -> Double? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        return (try? FileManager.default.attributesOfFileSystem(forPath: probe.path))?[.systemFreeSize]
            .flatMap { ($0 as? NSNumber)?.doubleValue }
    }

    /// The draws of this night's batch, as its `batch.conf` or else its recipe has them.
    public func probe(now: Date) -> ExploreProbe {
        var probe = ExploreProbe(seed: seed(now: now))
        let conf = batchConf
        probe.archetypeShare =
            recipe.explore.archetypeShare.value ?? Double(BatchDraw.defaultArchetypeShare)
        if let range = conf["galaxy_range"] {
            let ends = range.split(separator: "-").compactMap { Int($0) }
            if ends.count == 2 { probe.galaxies = ends[0]...ends[1] }
        } else {
            probe.galaxies = recipe.galaxyRange
        }
        probe.archetypes =
            conf["only_archetypes"].map { $0.split(separator: ",").map(String.init) }
            ?? recipe.explore.archetypes.value
        return probe
    }

    /// The planner for this folder now. `probe` keeps the draws it has sized between plans;
    /// `draws` stands in for it.
    public func planner(
        now: Date, progress: NightProgress? = nil, probe: ExploreProbe? = nil,
        draws: (@Sendable (Int) -> [NightScene])? = nil
    ) -> NightPlanner {
        let particles = hiresParticles
        let frames = recipe.hires.frames.value
        let sizer = probe ?? self.probe(now: now)
        return NightPlanner(
            recipe: recipe, model: CostModel.current(library: library),
            maximumParticles: maximumParticles, progress: progress ?? self.progress(),
            freeBytes: Self.freeBytes(batch)
        ) { perGalaxy in
            draws?(perGalaxy)
                ?? sizer.draws(perGalaxy: perGalaxy, count: NightPlanner.sample).map {
                    sizer.scene($0, hiresParticles: particles, frames: frames)
                }
        }
    }
}

/// `sillage-render night`: a whole night, one step after another, each in a process of its own
/// within the night's process group, so the queue's pause suspends the step with the night and
/// its cancel stops both. Between steps it reads its job in the queue for a skip or a stop
/// after the step, and before each step it plans again from the files, so a step that cannot
/// end before the delivery time is not started.
public final class NightRunner: @unchecked Sendable {
    public enum Outcome: Equatable {
        case finished(Int32)
        case skipped
        case stopped
        case late
    }

    public let folder: NightFolder
    let executable: URL
    let exploreScript: URL
    let catalogue: [LookFile]
    let say: (String) -> Void
    let poll: TimeInterval
    let handlesSignals: Bool
    let draws: (@Sendable (Int) -> [NightScene])?

    private var deliverBy = Date()
    private var night: NightFile
    private let stop = Flag()
    private var signalSources: [DispatchSourceSignal] = []
    private var skipsSeen = 0
    private var stopAfterStep = false
    private var skipNext = false
    /// Scenes left out tonight, by hand, for time or after a failure; a resumed night tries
    /// them again.
    private var leftOut: Set<String> = []
    private var counts: [String: (failed: Int, skipped: Int)] = [:]
    private lazy var probe = folder.probe(now: Date())

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var raised = false
        func raise() {
            lock.lock()
            raised = true
            lock.unlock()
        }
        var isRaised: Bool {
            lock.lock()
            defer { lock.unlock() }
            return raised
        }
    }

    public init(
        folder: NightFolder, executable: URL, exploreScript: URL = QueueRunner.exploreScript,
        catalogue: [LookFile], poll: TimeInterval = 1, handlesSignals: Bool = true,
        draws: (@Sendable (Int) -> [NightScene])? = nil, say: @escaping (String) -> Void = { print($0) }
    ) {
        self.folder = folder
        self.handlesSignals = handlesSignals
        self.draws = draws
        self.executable = executable
        self.exploreScript = exploreScript
        self.catalogue = catalogue
        self.poll = poll
        self.say = say
        night = NightFile(id: folder.id, phases: [], startedAt: Date())
    }

    private var batch: URL { folder.batch }
    private var recipe: NightRecipe { folder.recipe }
    private var nightURL: URL { RunStatusFiles.night(batch: batch) }
    private var logs: URL { batch.appendingPathComponent(".logs", isDirectory: true) }

    // MARK: Run

    /// 0 when the night is done, 3 when it stopped on request, 1 when it failed.
    public func run() -> Int32 {
        let now = Date()
        do {
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            try recipe.encoded().write(to: batch.appendingPathComponent("recipe.json"), options: .atomic)
            deliverBy = try recipe.deliverBy(now: now)
        } catch {
            say("night      \(error)")
            return 1
        }
        if handlesSignals { catchSignals() }
        let earlier = NightFile.read(from: nightURL)
        night = NightFile(
            id: folder.id, phases: [], state: .running, startedAt: earlier?.startedAt ?? now,
            deliverBy: deliverBy)
        var started = RunEvent(RunEvent.Kind.nightStart)
        started.night = folder.id
        record(started)
        let plan = update(phase: "explore")
        say("night      \(folder.id) into \(batch.path), deliver by \(Self.clock(deliverBy))")
        for line in NightCommand.lines(plan) { say(line) }

        // Exploration.
        if !folder.progress().exploreDone {
            let outcome = explore(plan)
            // Scenes cut short in their hidden folders.
            if outcome != .finished(0) { SceneFolder.removePartialOutputs(inBatch: batch) }
            switch outcome {
            case .stopped: return finish(.stopped)
            case .finished(let status) where status != 0 && folder.scenes.isEmpty:
                return finish(.failed, message: "exploration failed with status \(status)")
            default: break
            }
            phaseDone("explore", count: folder.scenes.count)
        }
        if stop.isRaised { return finish(.stopped) }
        if stopAfterStep { return finish(.stopped) }
        if case .none = recipe.pick { return finish(.done) }

        // The pick.
        if folder.progress().picks == nil { pick() }
        update(phase: "hires")

        // Each pick to its end, best first.
        for (index, name) in (folder.progress().picks ?? []).enumerated() {
            let scene = SceneFolder(batch.appendingPathComponent(name, isDirectory: true))
            skipNext = false
            readControls()
            if stop.isRaised { return finish(.stopped) }
            if stopAfterStep { return finish(.stopped) }
            if !finishScene(scene, pick: index) { return finish(.stopped) }
        }
        return finish(stop.isRaised || stopAfterStep ? .stopped : .done)
    }

    /// Hires, style and exports of one scene. False when the night is to stop.
    private func finishScene(_ scene: SceneFolder, pick: Int) -> Bool {
        let name = scene.url.lastPathComponent
        let steps: [(phase: NightPlan.Phase, format: String?)] =
            [(.hires, nil), (.style, nil)] + recipe.exports.map { (.export, $0) }
        for (phase, format) in steps {
            readControls()
            if stop.isRaised { return false }
            if skipNext || leftOut.contains(name) {
                if skipNext { leaveOut(name, phase: phase, why: "skipped by hand") }
                return true
            }
            let plan = update(phase: phase.rawValue)
            guard
                let step = plan.steps.first(where: {
                    $0.phase == phase && $0.scene == name && $0.format == format
                })
            else { continue }
            if step.done { continue }
            guard step.fits else {
                leaveOut(name, phase: phase, why: "would end after the delivery time")
                return true
            }
            let outcome: Outcome
            switch phase {
            case .hires: outcome = hires(scene)
            case .style: outcome = style(scene, pick: pick)
            default: outcome = export(scene, format: format ?? "1080p")
            }
            switch outcome {
            case .finished(0): break
            case .finished(let status):
                count(phase.rawValue, failed: 1)
                leftOut.insert(name)
                say("night      \(name) \(phase.rawValue) failed with status \(status)")
                if status > 128 {
                    var event = RunEvent(RunEvent.Kind.error, scene: name)
                    event.stage = phase.rawValue
                    event.message = "ended by signal \(status - 128)"
                    record(event)
                }
                return true
            case .skipped:
                leaveOut(name, phase: phase, why: "skipped by hand")
                return true
            case .late:
                leaveOut(name, phase: phase, why: "stopped at the delivery time")
                return true
            case .stopped:
                return false
            }
            if stopAfterStep { return false }
        }
        return true
    }

    // MARK: Steps

    private func explore(_ plan: NightPlan) -> Outcome {
        let explore = plan.steps.first { $0.phase == .explore }
        let seconds = max(plan.exploreBudget, (explore?.seconds ?? 0) * 1.25, 300)
        var arguments = [
            exploreScript.path, "--no-build", "--out", batch.path, "--scenes", String(plan.scenes),
            "--hours", String(format: "%.3f", seconds / 3600),
        ]
        if !FileManager.default.fileExists(atPath: batch.appendingPathComponent("batch.conf").path) {
            arguments += [
                "--seed", String(folder.seed(now: Date())), "--per-galaxy", String(plan.particlesPerGalaxy),
            ]
            if let range = recipe.galaxyRange {
                arguments += ["--galaxies", "\(range.lowerBound)-\(range.upperBound)"]
            }
            if let names = recipe.explore.archetypes.value {
                arguments += ["--only-archetypes", names.joined(separator: ",")]
            }
            if let share = recipe.explore.archetypeShare.value {
                arguments += ["--", "--archetypes", String(share)]
            }
        }
        say("night      explore \(plan.scenes) scenes at \(plan.particlesPerGalaxy) a galaxy")
        return runChild(
            "/bin/bash", arguments, log: logs.appendingPathComponent("night-explore.log")
        ) { [self] in
            update(phase: "explore", quiet: true)
        }
    }

    /// The best scenes by score, as many as the recipe or the time allows, written as picks:
    /// a scene marked yes by hand stays a choice and is not written over.
    private func pick() {
        let plan = folder.planner(now: Date(), probe: probe, draws: draws).plan(
            now: Date(), deliverBy: deliverBy)
        let names = plan.steps.filter { $0.phase == .hires }.compactMap(\.scene)
        let progress = folder.progress()
        let ratings = SceneRatings.read(batch: batch)
        for name in names {
            let score = progress.explored.first { $0.name == name }?.score ?? 0
            if ratings.scenes[name]?.choice != .yes {
                _ = try? SceneRatings.update(batch: batch, scene: name) {
                    $0.picked = SceneRatings.Pick(score: score, date: Date())
                }
            }
            var event = RunEvent(RunEvent.Kind.pick, scene: name)
            event.chosen = true
            event.score = score
            record(event)
            say(String(format: "night      picked %@, score %.3f", name, score))
        }
        phaseDone("pick", count: names.count)
    }

    private func hires(_ scene: SceneFolder) -> Outcome {
        let name = scene.url.lastPathComponent
        say("night      hires \(name), \(folder.hiresParticles) particles")
        let outcome = runChild(
            executable.path, ["hires", scene.url.path] + folder.hiresOptions,
            log: logs.appendingPathComponent("\(name).hires.log")
        ) { [self] in
            update(phase: "hires", quiet: true)
        }
        if outcome != .finished(0) { scene.removePartialOutputs() }
        return outcome
    }

    /// The style of the pick: Auto's choice of rendering and palette in the pick's world
    /// (#124), or the rendering the recipe names with a palette of that world.
    private func style(_ scene: SceneFolder, pick: Int) -> Outcome {
        let name = scene.url.lastPathComponent
        do {
            let chosen = try NightStyle.resolve(
                recipe.style, pick: pick, catalogue: catalogue, references: TelescopeReference.repository)
            say(
                "night      style \(name): \(chosen.rendering ?? "auto") in the \(chosen.world.rawValue) world, palette \(chosen.palette)"
            )
            let outcome = runChild(
                executable.path, chosen.arguments(scene: scene.url.path),
                log: logs.appendingPathComponent("\(name).style.log")
            ) {}
            if outcome == .finished(0) { styled(scene) }
            return outcome
        } catch {
            var event = RunEvent(RunEvent.Kind.error, scene: name)
            event.stage = "style"
            event.message = "\(error)"
            record(event)
            return .finished(1)
        }
    }

    private func styled(_ scene: SceneFolder) {
        var event = RunEvent(RunEvent.Kind.style, scene: scene.url.lastPathComponent)
        let look = (try? Data(contentsOf: scene.look)).flatMap { try? LookFile.decoded(from: $0) }
        event.style = look?.name
        event.setPalette(look?.paletteRecipe)
        event.path = scene.look.path
        record(event)
    }

    private func export(_ scene: SceneFolder, format: String) -> Outcome {
        let name = scene.url.lastPathComponent
        let option = VideoPreset.named(format) != nil ? "--preset" : "--format"
        say("night      export \(name) \(format)")
        let outcome = runChild(
            executable.path, ["export", scene.url.path, option, format],
            log: logs.appendingPathComponent("\(name).export.log")
        ) { [self] in
            update(phase: "export", quiet: true)
        }
        if outcome != .finished(0) { scene.removePartialOutputs() }
        return outcome
    }

    // MARK: Children

    /// Runs one step to its end, or until it is skipped, stopped or past the delivery time
    /// and its grace. `explore-batch.sh` takes its own scenes down when it is stopped.
    private func runChild(
        _ executable: String, _ arguments: [String], log: URL, tick: () -> Void
    ) -> Outcome {
        let pid: Int32
        do {
            pid = try Spawn.member(executable, arguments, log: log)
        } catch {
            say("night      \(executable) did not start: \(error)")
            return .finished(127)
        }
        var lastTick = Date()
        while true {
            var raw: Int32 = 0
            if waitpid(pid, &raw, WNOHANG) == pid {
                // Stopped with the night, by the queue's signal to the whole group.
                if stop.isRaised { return .stopped }
                let signal = raw & 0x7f
                return .finished(signal == 0 ? (raw >> 8) & 0xff : 128 + signal)
            }
            readControls()
            var ending: Outcome?
            if stop.isRaised {
                ending = .stopped
            } else if skipNext {
                ending = .skipped
            } else if Date() > deliverBy.addingTimeInterval(NightPlanner.grace) {
                ending = .late
            }
            if let ending {
                say(
                    "night      stopping \(URL(fileURLWithPath: arguments.first ?? executable).lastPathComponent)"
                )
                end(pid)
                clearJob()
                return ending
            }
            if Date().timeIntervalSince(lastTick) >= 5 {
                tick()
                lastTick = Date()
            }
            Thread.sleep(forTimeInterval: poll)
        }
    }

    /// SIGTERM, then SIGKILL after ten seconds.
    private func end(_ pid: Int32) {
        kill(pid, SIGTERM)
        kill(pid, SIGCONT)
        let asked = Date()
        var raw: Int32 = 0
        while waitpid(pid, &raw, WNOHANG) != pid {
            if Date().timeIntervalSince(asked) > 10 { kill(pid, SIGKILL) }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    /// The night's own job in the queue: a skip asked for, or a stop after the step.
    private func readControls() {
        let me = getpid()
        guard let job = QueueStore(library: folder.library).read().jobs.first(where: { $0.pid == me })
        else { return }
        if job.stopAfterStep == true, !stopAfterStep {
            stopAfterStep = true
            say("night      will stop after this step")
        }
        let skips = job.skips ?? 0
        if skips > skipsSeen {
            skipsSeen = skips
            skipNext = true
            say("night      skipping the current scene")
        }
    }

    private func catchSignals() {
        for number in [SIGTERM, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            let flag = stop
            source.setEventHandler { flag.raise() }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Status

    /// Plans again from the files and rewrites `night.json` and the night in `activity.json`.
    @discardableResult
    private func update(phase: String, quiet: Bool = false) -> NightPlan {
        var progress = folder.progress()
        progress.skipped = leftOut
        let plan = folder.planner(now: Date(), progress: progress, probe: probe, draws: draws).plan(
            now: Date(), deliverBy: deliverBy)
        let explored = progress.explored.count
        let picks = progress.picks ?? []
        let index = SceneLibrary.indexRows(batch.appendingPathComponent("index.csv"))
        func entry(_ name: NightPlan.Phase, planned: Int, done: Int, failed: Int = 0) -> NightFile.Phase {
            let summary = plan.summaries.first { $0.phase == name }
            let counted = counts[name.rawValue] ?? (0, 0)
            return NightFile.Phase(
                name: name.rawValue, planned: planned, done: done, failed: failed + counted.failed,
                skipped: counted.skipped > 0 ? counted.skipped : nil,
                estimatedStart: summary?.start, estimatedEnd: summary?.end)
        }
        let finishing = progress.picks.map { $0.count } ?? plan.picks
        night.phases = [
            entry(
                .explore, planned: plan.scenes, done: explored,
                failed: index.values.filter { $0["status"]?.hasPrefix("failed") == true }.count),
            entry(.pick, planned: plan.picks, done: picks.count),
            entry(.hires, planned: finishing, done: picks.filter(progress.hiresDone.contains).count),
            entry(.style, planned: finishing, done: picks.filter(progress.styled.contains).count),
            entry(
                .export, planned: finishing * recipe.exports.count,
                done: picks.reduce(0) { total, name in
                    total + recipe.exports.filter { progress.exported.contains("\(name)/\($0)") }.count
                }),
        ]
        night.recipe = resolved(plan)
        night.deliverBy = deliverBy
        night.estimatedEnd = plan.end
        night.state = .running
        writeNight()
        publish(phase: phase, eta: plan.end)
        if !quiet { for warning in plan.warnings { say("warning    \(warning.message)") } }
        return plan
    }

    private func resolved(_ plan: NightPlan) -> [String: String] {
        var values = [
            "deliverBy": RunStatus.string(deliverBy), "scenes": String(plan.scenes),
            "particlesPerGalaxy": String(plan.particlesPerGalaxy),
            "seed": String(folder.seed(now: night.startedAt)),
            "pick": {
                switch recipe.pick {
                case .auto: "auto"
                case .none: "none"
                case .count(let count): String(count)
                }
            }(),
            "hiresParticles": String(plan.hiresParticles), "exports": plan.exports.joined(separator: ","),
            "style": recipe.style.style.value ?? "standard",
            "palette": recipe.style.palette.value ?? (recipe.style.world.value == nil ? "scene" : "auto"),
            "world": recipe.style.world.value ?? "auto",
        ]
        if let frames = recipe.hires.frames.value { values["hiresFrames"] = String(frames) }
        if let range = recipe.galaxyRange { values["galaxies"] = "\(range.lowerBound)-\(range.upperBound)" }
        if let names = recipe.explore.archetypes.value { values["archetypes"] = names.joined(separator: ",") }
        if let share = recipe.explore.archetypeShare.value { values["archetypeShare"] = String(share) }
        return values
    }

    private func writeNight() {
        if let data = try? night.encoded() { try? RunStatusFiles.write(data, to: nightURL) }
    }

    /// The night's line in `activity.json`, kept beside whatever job a step writes there.
    private func publish(phase: String?, eta: Date?) {
        let url = RunStatusFiles.activity(library: folder.library)
        var activity = ActivityFile.read(from: url) ?? ActivityFile(state: .idle, updated: Date())
        activity.night = phase.map { ActivityFile.Night(id: folder.id, phase: $0, eta: eta) }
        if phase != nil, activity.state == .idle { activity.state = .running }
        activity.updated = Date()
        if let data = try? activity.encoded() { try? RunStatusFiles.write(data, to: url) }
    }

    /// A step ended before it could say so: its job leaves `activity.json`.
    private func clearJob() {
        let url = RunStatusFiles.activity(library: folder.library)
        guard var activity = ActivityFile.read(from: url), activity.job?.batch == folder.id else { return }
        activity.job = nil
        activity.updated = Date()
        if let data = try? activity.encoded() { try? RunStatusFiles.write(data, to: url) }
    }

    private func record(_ event: RunEvent) {
        try? RunStatusFiles.append(event, to: RunStatusFiles.events(batch: batch))
    }

    private func phaseDone(_ phase: String, count: Int) {
        var event = RunEvent(RunEvent.Kind.phaseDone)
        event.night = folder.id
        event.phase = phase
        event.count = count
        record(event)
        writeReport()
    }

    private func count(_ phase: String, failed: Int = 0, skipped: Int = 0) {
        let counted = counts[phase] ?? (0, 0)
        counts[phase] = (counted.failed + failed, counted.skipped + skipped)
    }

    private func leaveOut(_ name: String, phase: NightPlan.Phase, why: String) {
        leftOut.insert(name)
        count(phase.rawValue, skipped: 1)
        var event = RunEvent(RunEvent.Kind.skip, scene: name)
        event.stage = phase.rawValue
        event.message = why
        record(event)
        say("night      \(name) left out at \(phase.rawValue): \(why)")
        skipNext = false
    }

    private func writeReport() {
        let text = NightReport.markdown(night, events: folder.events, batch: batch)
        try? text.write(to: batch.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
    }

    private func finish(_ state: NightFile.State, message: String? = nil) -> Int32 {
        if state != .failed { update(phase: "export", quiet: true) }
        let now = Date()
        night.state = state
        night.endedAt = now
        night.estimatedEnd = now
        writeNight()
        var event = RunEvent(RunEvent.Kind.nightDone)
        event.night = folder.id
        event.status = state.rawValue
        event.seconds = now.timeIntervalSince(night.startedAt)
        event.message = message
        record(event)
        writeReport()
        publish(phase: nil, eta: nil)
        say("night      \(state.rawValue)\(message.map { ": \($0)" } ?? "")")
        switch state {
        case .done: return 0
        case .stopped: return 3
        default: return 1
        }
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = Calendar.current.isDateInToday(date) ? "HH:mm" : "EEE HH:mm"
        return formatter.string(from: date)
    }
}
