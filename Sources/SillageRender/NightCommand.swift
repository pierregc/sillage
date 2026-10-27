import Foundation

/// `sillage-render night <recipe> [--out DIR] [--plan [--json]]`: adds the night to the
/// queue, or prints its plan. The queue's runner starts the same command for the night's job,
/// and that one runs the night.
public enum NightCommand {
    public static let usage = """
        usage: sillage-render night <recipe.json> [--out DIR] [--plan [--json]]
        Queues the night (library/<date> unless --out says otherwise); --plan prints what it
        would compute, how long each step takes and when it would be done.
        """

    public enum Failure: Error, CustomStringConvertible {
        case usage
        case noStyle(String)
        case tooManyParticles(Int, Int)

        public var description: String {
            switch self {
            case .usage: NightCommand.usage
            case .noStyle(let name): "recipe: style.style: no look \"\(name)\" in the catalogue"
            case .tooManyParticles(let asked, let maximum):
                "recipe: hires.particles \(asked) is above this Mac's maximum of \(maximum)"
            }
        }
    }

    /// The repository's looks, which a recipe's style names.
    public static var catalogue: [LookFile] {
        LookCatalogue.load(
            from: QueueRunner.exploreScript.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("looks", isDirectory: true))
    }

    public static func main(
        _ arguments: [String], executable: URL, say: @escaping (String) -> Void = { print($0) }
    ) -> Int32 {
        var arguments = arguments
        func take(_ name: String) -> String? {
            guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
                return nil
            }
            let value = arguments[index + 1]
            arguments.removeSubrange(index...index + 1)
            return value
        }
        let out = take("--out").map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
        let planOnly = arguments.contains("--plan")
        let json = arguments.contains("--json")
        arguments.removeAll { $0 == "--plan" || $0 == "--json" }
        guard arguments.count == 1 else {
            say(usage)
            return 2
        }
        let recipeURL = URL(fileURLWithPath: arguments[0]).standardizedFileURL
        let batch =
            out
            ?? QueueCommand.defaultLibrary().appendingPathComponent(day(Date()), isDirectory: true)
        do {
            let recipe = try checked(NightRecipe.read(recipeURL))
            let folder = NightFolder(batch: batch, recipe: recipe)
            if planOnly {
                let now = Date()
                let plan = folder.planner(now: now).plan(now: now, deliverBy: try recipe.deliverBy(now: now))
                if json {
                    say(String(decoding: try plan.encoded(), as: UTF8.self))
                } else {
                    for line in lines(plan) { say(line) }
                }
                return 0
            }
            let store = QueueStore(library: folder.library)
            let me = getpid()
            // Under the queue's lock, which the runner holds until it has written the pid of
            // the process it started.
            let isTheJob = try store.change { queue in
                queue.running.map { $0.kind == .night && $0.pid == me } ?? false
            }
            if isTheJob {
                // Its log is a file: a line as it comes, not a block at the end.
                setvbuf(stdout, nil, _IOLBF, 0)
                return NightRunner(folder: folder, executable: executable, catalogue: catalogue, say: say)
                    .run()
            }
            try submit(recipe: recipeURL, batch: batch, executable: executable, say: say)
            return 0
        } catch {
            say("\(error)")
            return 2
        }
    }

    /// A recipe this Mac can run.
    public static func checked(_ recipe: NightRecipe) throws -> NightRecipe {
        _ = try NightStyle.resolve(
            recipe.style, pick: 0, catalogue: catalogue, references: TelescopeReference.repository)
        let maximum = SceneFolder.maximumParticles()
        if let particles = recipe.hires.particles.value, particles > maximum {
            throw Failure.tooManyParticles(particles, maximum)
        }
        return recipe
    }

    /// The night as a job of its library's queue, a runner started if none is at work.
    public static func submit(
        recipe: URL, batch: URL, executable: URL, say: @escaping (String) -> Void
    ) throws {
        _ = try checked(NightRecipe.read(recipe))
        let store = QueueStore(library: batch.deletingLastPathComponent())
        let (added, runner) = try store.submit(
            .night, path: batch.path, options: [recipe.path], night: batch.lastPathComponent,
            runner: executable)
        let queue = store.read()
        let ahead = queue.waiting.count - 1 + (queue.running == nil ? 0 : 1)
        say("queue      job \(added.id) added: \(added.summary), \(ahead) before it")
        if let runner { say("runner     started, pid \(runner), log \(store.runnerLog.path)") }
    }

    /// The plan as `--plan` prints it, one line a step.
    public static func lines(_ plan: NightPlan) -> [String] {
        func time(_ date: Date) -> String { NightRunner.clock(date) }
        func duration(_ seconds: Double) -> String {
            let minutes = Int((seconds / 60).rounded())
            return minutes >= 60 ? String(format: "%d h %02d", minutes / 60, minutes % 60) : "\(minutes) min"
        }
        func thousands(_ value: Int) -> String {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.usesGroupingSeparator = true
            formatter.groupingSeparator = " "
            return formatter.string(from: NSNumber(value: value)) ?? String(value)
        }
        var lines = [
            "plan       deliver by \(time(plan.deliverBy)), \(duration(plan.deliverBy.timeIntervalSince(plan.start))) from now"
        ]
        for step in plan.steps {
            let state =
                step.done
                ? "done"
                : step.fits
                    ? "\(duration(step.seconds)) · \(time(step.start)) to \(time(step.end))" : "left out"
            let line: String
            switch step.phase {
            case .explore:
                line =
                    "explore    \(step.count ?? 0) scenes at \(thousands(step.particles ?? 0)) a galaxy · \(state)"
            case .pick:
                line =
                    "pick       \(step.count ?? 0) scenes"
                    + (step.done ? " · done" : " · at \(time(step.start))")
            case .hires:
                line =
                    "hires      \(step.scene ?? "") · \(thousands(step.particles ?? 0)) particles · \(state)"
            case .style:
                line = "style      \(step.scene ?? "") · \(state)"
            case .export:
                line = "export     \(step.scene ?? "") \(step.format ?? "") · \(state)"
            }
            lines.append(line)
        }
        let early = plan.deliverBy.timeIntervalSince(plan.end)
        lines.append(
            "end        \(time(plan.end)), "
                + (early >= 0
                    ? "\(duration(early)) before the delivery" : "\(duration(-early)) after the delivery"))
        lines.append(
            String(format: "disk       %.1f GB needed", plan.diskBytes / 1e9)
                + (plan.freeBytes.map { String(format: ", %.1f GB free", $0 / 1e9) } ?? ""))
        for warning in plan.warnings { lines.append("warning    \(warning.message)") }
        return lines
    }

    static func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
