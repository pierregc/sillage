import Foundation
import Testing

@testable import SillageRender

@Suite("Repository root")
struct RepositoryRootTests {
    private func checkout(named name: String, in parent: URL) throws -> URL {
        let url = parent.appendingPathComponent(name, isDirectory: true)
        for folder in ["looks", "references/telescope", "scripts"] {
            try FileManager.default.createDirectory(
                at: url.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        try Data().write(to: url.appendingPathComponent("Package.swift"))
        try Data().write(to: url.appendingPathComponent("scripts/explore-batch.sh"))
        return url
    }

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func locator(
        _ environment: [String: String] = [:], plist: String? = nil, executable: URL? = nil,
        compiled: URL
    ) -> RepositoryRoot.Locator {
        .init(
            environment: environment, plistRoot: plist, executableFolder: executable,
            compiledFrom: compiled)
    }

    @Test("SILLAGE_ROOT wins over everything else")
    func environmentWins() throws {
        let parent = try scratch()
        let main = try checkout(named: "main", in: parent)
        let tree = try checkout(named: "tree", in: parent)
        let found = try RepositoryRoot.resolve(
            locator([RepositoryRoot.environmentKey: main.path], plist: tree.path, compiled: tree))
        #expect(found == main)
    }

    @Test("A SILLAGE_ROOT that is no checkout is refused, not skipped")
    func environmentRefused() throws {
        let parent = try scratch()
        let tree = try checkout(named: "tree", in: parent)
        #expect(throws: RepositoryRoot.Missing.self) {
            try RepositoryRoot.resolve(
                locator([RepositoryRoot.environmentKey: "/nowhere/sillage"], compiled: tree))
        }
        do {
            _ = try RepositoryRoot.resolve(
                locator([RepositoryRoot.environmentKey: "/nowhere/sillage"], compiled: tree))
        } catch {
            #expect("\(error)".contains("/nowhere/sillage"))
        }
    }

    @Test("The plist root, then the file beside the executable, then the compiled in checkout")
    func order() throws {
        let parent = try scratch()
        let plist = try checkout(named: "plist", in: parent)
        let marked = try checkout(named: "marked", in: parent)
        let compiled = try checkout(named: "compiled", in: parent)
        let beside = parent.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: beside, withIntermediateDirectories: true)
        try "\(marked.path)\n".write(
            to: beside.appendingPathComponent(RepositoryRoot.markerName), atomically: true,
            encoding: .utf8)
        #expect(
            try RepositoryRoot.resolve(locator(plist: plist.path, executable: beside, compiled: compiled))
                == plist)
        #expect(
            try RepositoryRoot.resolve(locator(executable: beside, compiled: compiled)) == marked)
        #expect(try RepositoryRoot.resolve(locator(compiled: compiled)) == compiled)
    }

    @Test("A build whose worktree is gone finds the checkout set in SILLAGE_ROOT")
    func removedWorktree() throws {
        let parent = try scratch()
        let main = try checkout(named: "main", in: parent)
        let gone = parent.appendingPathComponent("worktree", isDirectory: true)
        let beside = parent.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: beside, withIntermediateDirectories: true)
        try gone.path.write(
            to: beside.appendingPathComponent(RepositoryRoot.markerName), atomically: true,
            encoding: .utf8)
        let without = locator(plist: gone.path, executable: beside, compiled: gone)
        #expect(throws: RepositoryRoot.Missing.self) { try RepositoryRoot.resolve(without) }
        var with = without
        with.environment[RepositoryRoot.environmentKey] = main.path
        #expect(try RepositoryRoot.resolve(with) == main)
        #expect(try RepositoryRoot.folder("looks", with) == main.appendingPathComponent("looks"))
        #expect(
            try RepositoryRoot.file("scripts/explore-batch.sh", with).lastPathComponent == "explore-batch.sh")
    }

    @Test("A missing root says where it looked and how to set SILLAGE_ROOT")
    func missingMessage() throws {
        let gone = URL(fileURLWithPath: "/nowhere/worktree", isDirectory: true)
        do {
            _ = try RepositoryRoot.resolve(locator(plist: "/nowhere/app", compiled: gone))
            Issue.record("no root should be found")
        } catch {
            let text = "\(error)"
            #expect(text.contains("/nowhere/worktree") && text.contains("/nowhere/app"))
            #expect(text.contains("SILLAGE_ROOT"))
        }
        #expect(RepositoryRoot.problem(locator(compiled: gone))?.contains("SILLAGE_ROOT") == true)
    }

    @Test("A folder or a script missing from a real checkout is named")
    func missingFolder() throws {
        let parent = try scratch()
        let tree = try checkout(named: "tree", in: parent)
        try FileManager.default.removeItem(at: tree.appendingPathComponent("references/telescope"))
        let here = locator(compiled: tree)
        #expect(RepositoryRoot.problem(here)?.contains("references/telescope") == true)
        #expect(throws: RepositoryRoot.Missing.self) {
            try RepositoryRoot.folder("references/telescope", here)
        }
        #expect(throws: RepositoryRoot.Missing.self) { try RepositoryRoot.file("scripts/missing.sh", here) }
        #expect(RepositoryRoot.place("palettes", here).path == tree.appendingPathComponent("palettes").path)
    }

    @Test("The repository this is built in has what the commands need")
    func thisRepository() throws {
        #expect(RepositoryRoot.problem() == nil)
        #expect(try LookCatalogue.fromRepository().count > 5)
        #expect(!TelescopeReference.repository.isEmpty)
    }

    @Test("The explore stage runs the script with the binary that started it")
    func exploreStage() throws {
        let job = QueueJob(
            id: 1, kind: .explore, path: "/library/day", options: ["--scenes", "2"], added: Date())
        let line = try QueueRunner.stages(executable: "/apps/Sillage/sillage-render")(job)
        #expect(line.first == "/bin/bash")
        #expect(line[1].hasSuffix("scripts/explore-batch.sh"))
        let bin = try #require(line.firstIndex(of: "--bin"))
        #expect(line[bin + 1] == "/apps/Sillage/sillage-render")
        #expect(line.suffix(2) == ["--scenes", "2"])
    }
}
