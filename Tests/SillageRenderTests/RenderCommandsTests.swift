import Foundation
import Testing

@testable import SillageRender

@Suite("Command options")
struct RenderCommandsTests {
    private func check(_ words: String...) -> RenderCommands.Outcome { RenderCommands.check(words) }

    private func refusal(_ words: String...) -> String {
        if case .refused(let message) = RenderCommands.check(words) { return message }
        return ""
    }

    @Test("No argument at all is the default render")
    func noArgument() {
        #expect(RenderCommands.check([]) == .run)
    }

    @Test("--help prints the usage and renders nothing")
    func help() {
        for words in [["--help"], ["-h"], ["help"]] {
            guard case .help(let text) = RenderCommands.check(words) else {
                Issue.record("\(words) is not help")
                continue
            }
            #expect(text.contains("usage: sillage-render") && text.contains("explore"))
        }
        guard case .help(let text) = check("hires", "scene", "--help") else {
            Issue.record("hires --help is not help")
            return
        }
        #expect(text.contains("usage: sillage-render hires") && text.contains("--particles N"))
        guard case .help = check("--particles", "5", "--help") else {
            Issue.record("--help after options is not help")
            return
        }
    }

    @Test("A misspelled option is refused, with the one it is near")
    func typo() {
        let message = refusal("--partciles", "2000000")
        #expect(message.contains("unknown option --partciles") && message.contains("--particles"))
        #expect(refusal("hires", "scene", "--masive", "5").contains("--massive"))
    }

    @Test("A value that does not parse is refused, not turned into the default")
    func badValue() {
        #expect(refusal("--particles", "2M").contains("--particles wants a whole number, not \"2M\""))
        #expect(refusal("--brightness", "bright").contains("wants a number"))
        #expect(refusal("explore", "scene", "--steps", "12.5").contains("--steps"))
        #expect(check("--particles", "2e6", "--brightness", "-0.5") == .run)
        #expect(check("--seed", "18446744073709551615") == .run)
    }

    @Test("An option with no value, a stray word and a missing folder are refused")
    func shape() {
        #expect(refusal("--particles").contains("--particles needs a value"))
        #expect(refusal("--plain", "extra").contains("unexpected argument \"extra\""))
        #expect(refusal("hires", "scene", "extra").contains("unexpected argument \"extra\""))
        #expect(refusal("explore").contains("missing scene folder"))
        #expect(refusal("explor", "scene").contains("explore"))
        #expect(refusal("frobnicate").contains("no command \"frobnicate\""))
    }

    @Test("Every refusal comes with the usage")
    func usage() {
        #expect(refusal("export", "scene", "--bogus").contains("usage: sillage-render export"))
    }

    @Test("What the nights, the queue and the batch script pass is accepted")
    func theCallers() {
        #expect(
            check(
                "explore", "batch/.scene-0001", "--seed", "20261120", "--index", "3", "--particles",
                "100000", "--width", "960", "--height", "540", "--frames", "900", "--fps", "30",
                "--steps", "1800", "--settle", "375", "--dt-scale", "7", "--pair-share", "off",
                "--look", "looks/raw.look.json", "--archetypes", "0.2") == .run)
        #expect(
            check(
                "hires", "scene", "--particles", "8000000", "--massive", "2000000", "--frames", "900",
                "--pass", "full", "--export", "4k,vertical", "--resume") == .run)
        #expect(
            check(
                "look", "scene", "--palette", "auto", "--world", "free", "--base", "webb", "--single",
                "--generated", "--camera", "director") == .run)
        #expect(check("export", "scene", "--preset", "4k", "--format", "mp4", "--speed", "story") == .run)
        #expect(check("look", "scene", "--grid", "a.look.json", "b.look.json", "--width", "480") == .run)
        #expect(check("probe-disk", "scene.json", "1", "--particles", "20000", "--calm") == .run)
        #expect(check("event", "batch", "pick", "--scene", "scene-0001", "--score", "0.4") == .run)
        #expect(check("costs", "library", "--check", "2026-11-20") == .run)
        #expect(check("queue", "list") == .run && check("night", "recipe.json") == .run)
    }

    @Test("Negative numbers and look files are values and words, not options")
    func dashes() throws {
        let spec = try #require(RenderCommands.spec(named: "look"))
        let parsed = try spec.parse(["scene", "x.look.json", "--width", "480", "--grid"])
        #expect(parsed.words == ["scene", "x.look.json"] && parsed.whole("width") == 480)
        #expect(parsed.has("grid") && !parsed.has("single"))
        #expect(try RenderCommands.plain.parse(["--elevation", "-30"]).number("elevation") == -30)
    }

    @Test("explore alone takes the batch's defaults")
    func exploreDefaults() throws {
        let folder = SceneFolder(
            FileManager.default.temporaryDirectory.appendingPathComponent(
                "explore-\(UUID().uuidString)", isDirectory: true))
        let (clip, rest) = try folder.exploreStart(["--particles", "20000"])
        #expect(clip.particles == 20_000 && clip.width == 960 && clip.height == 540)
        #expect(clip.frames == 900 && clip.fps == 30 && clip.settle == 375)
        #expect(rest == ["--span", "700.0", "--dt-scale", "7.0"])
        let given = try folder.exploreStart(["--steps", "900", "--dt-scale", "3.5"])
        #expect(given.clip.steps == 900 && given.rest == ["--dt-scale", "3.5"])
    }

    @Test("A whole number of steps a frame covers the span")
    func span() {
        #expect(SceneFolder.Clip.steps(spanMyr: 700, stepMyr: 0.2, frames: 900) == 3_600)
        #expect(SceneFolder.Clip.steps(spanMyr: 700, stepMyr: 1, frames: 900) == 900)
        #expect(SceneFolder.Clip.steps(spanMyr: 700, stepMyr: 0.5, frames: 900) == 1_800)
        #expect(SceneFolder.Clip.steps(spanMyr: 0, stepMyr: 0.5, frames: 900) == 900)
    }

    /// An option read in the sources and absent from the tables would be refused: the tables are
    /// checked against what the sources read.
    @Test("The tables hold every option the sources read")
    func tablesMatchTheSources() throws {
        let root = try RepositoryRoot.resolve()
        let held = Set(
            ([RenderCommands.plain] + RenderCommands.all).flatMap { $0.options.map(\.name) })
        // Read by commands with a parser of their own, or by the batch script and the status tools.
        let elsewhere: Set<String> = [
            "bin", "hours", "scenes", "per-galaxy", "only-archetypes", "no-build", "library", "json",
            "now", "timezone", "plan", "porcelain", "fixture", "full", "night",
        ]
        let reads = try NSRegularExpression(
            pattern:
                #"\b(?:cut|argument|number|option|value|float|flag|integer)\("([a-z0-9-]+)"|contains\("--([a-z0-9-]+)"\)"#
        )
        var missing: [String: String] = [:]
        for folder in ["Sources/sillage-render", "Sources/SillageRender"] {
            let url = root.appendingPathComponent(folder)
            for file in try FileManager.default.contentsOfDirectory(atPath: url.path)
            where file.hasSuffix(".swift") {
                let isOwn =
                    folder == "Sources/SillageRender"
                    && ["Night", "Queue", "Status", "Hole", "Notices", "Scene", "Look", "Style"]
                        .contains { file.hasPrefix($0) }
                    && file != "SceneFolder.swift"
                if isOwn
                    || ["RenderCommands.swift", "CUDACommands.swift", "CommandSpec.swift"].contains(file)
                {
                    continue
                }
                let text = try String(contentsOf: url.appendingPathComponent(file), encoding: .utf8)
                let range = NSRange(text.startIndex..., in: text)
                for match in reads.matches(in: text, range: range) {
                    for group in 1...2 {
                        guard let part = Range(match.range(at: group), in: text) else { continue }
                        let name = String(text[part].drop { $0 == "-" })
                        if !held.contains(name), !elsewhere.contains(name) { missing[name] = file }
                    }
                }
            }
        }
        #expect(missing.isEmpty, "read in the sources, in no table: \(missing.sorted { $0.key < $1.key })")
    }
}
