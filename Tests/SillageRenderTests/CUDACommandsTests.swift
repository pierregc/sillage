import Foundation
import Testing

@testable import SillageRender

@Suite("sillage-cuda's options")
struct CUDACommandsTests {
    private func check(_ words: String...) -> RenderCommands.Outcome {
        CUDACommands.check(words, overview: "overview")
    }

    private func refusal(_ words: String...) -> String {
        if case .refused(let message) = CUDACommands.check(words, overview: "overview") { return message }
        return ""
    }

    @Test("No argument and help print the overview")
    func overview() {
        for words in [[], ["help"], ["--help"]] {
            #expect(CUDACommands.check(words, overview: "overview") == .help("overview"))
        }
        guard case .help(let text) = check("export", "scene", "--help") else {
            Issue.record("export --help is not help")
            return
        }
        #expect(text.contains("usage: sillage-cuda export") && text.contains("--flight TEXT"))
    }

    @Test("What each command runs with passes")
    func runs() {
        #expect(check("explore", "s", "--particles", "200000", "--threads", "8") == .run)
        #expect(check("hires", "s", "--pass", "full", "--export", "4k,vertical", "--resume") == .run)
        #expect(
            check("export", "s", "--flight", "dive", "--preset", "4k", "--part", "1/2", "--device", "1")
                == .run)
        #expect(check("still", "t", "--look", "webb", "--frames", "0,12", "--out", "o") == .run)
        #expect(check("black-hole", "still", "f", "o.png", "--elevation", "-10", "--straight") == .run)
        #expect(check("take", "extract", "t", "--at", "300", "o.sillage") == .run)
        #expect(check("match", "s", "m.map.json", "--kpc-across", "48.6") == .run)
        #expect(check("check") == .run)
        #expect(check("status", "s") == .run)
    }

    @Test("A mistyped option, a bad value, a stray word and a wrong command are refused")
    func refused() {
        let typo = refusal("export", "s", "--flihgt", "dive")
        #expect(typo.contains("unknown option --flihgt") && typo.contains("--flight"))
        #expect(typo.contains("usage: sillage-cuda export"))
        #expect(refusal("hires", "s", "--particles", "8M").contains("whole number"))
        #expect(refusal("still", "t", "extra").contains("unexpected argument"))
        #expect(refusal("hires").contains("missing scene folder"))
        #expect(refusal("exprt", "s").contains("did you mean export?"))
        #expect(refusal("black-hole", "run", "f", "o.png").contains("only still"))
        #expect(refusal("palettes", "s").contains("no command \"palettes\""))
    }

    /// An option read by the CUDA sources and absent from the tables would be refused.
    @Test("The tables hold every option sillage-cuda reads")
    func tablesMatchTheSources() throws {
        let root = try RepositoryRoot.resolve()
        let held = Set(CUDACommands.all.flatMap { $0.options.map(\.name) })
        let reads = try NSRegularExpression(
            pattern: #"\b(?:option|value|flag|integer|double|float|int)\("([a-z0-9-]+)"\)|"--([a-z0-9-]+)""#)
        var missing: [String: String] = [:]
        for folder in ["Sources/sillage-cuda", "Sources/SillageCUDA"] {
            let url = root.appendingPathComponent(folder)
            for file in try FileManager.default.contentsOfDirectory(atPath: url.path)
            where file.hasSuffix(".swift") {
                let text = try String(contentsOf: url.appendingPathComponent(file), encoding: .utf8)
                for match in reads.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    for group in 1...2 {
                        guard let part = Range(match.range(at: group), in: text) else { continue }
                        let name = String(text[part])
                        if !held.contains(name) { missing[name] = file }
                    }
                }
            }
        }
        #expect(missing.isEmpty, "read by sillage-cuda, in no table: \(missing.sorted { $0.key < $1.key })")
    }
}
