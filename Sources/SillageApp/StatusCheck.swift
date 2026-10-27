import AppKit
import Foundation
import SillageRender
import SwiftUI

/// `--statuscheck`: the status line and the queue view against the fixtures of
/// `Tests/Fixtures/queue-status/`. The app's model and the bundled `sillage-render status`
/// read each fixture library and must print the same lines, the golden ones. Then a library
/// that changes under a running model, which must follow within two seconds, and the pictures
/// of the sidebar line and the view for each fixture in `out/`. No GPU and no window.
@MainActor
enum StatusCheck {
    private static var lines: [String] = []
    private static var failures = 0

    static func run() {
        guard CommandLine.arguments.contains("--statuscheck") else { return }
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        exercise()
        let report = lines.joined(separator: "\n") + "\n\n\(failures) échec(s)"
        try? report.write(
            to: URL(fileURLWithPath: "/tmp/sillage-status.log"), atomically: true, encoding: .utf8)
        print(report)
        exit(failures == 0 ? 0 : 1)
    }

    private static func check(_ name: String, _ passed: Bool, _ detail: String = "") {
        lines.append("\(passed ? "ok  " : "FAIL") \(name)\(detail.isEmpty ? "" : "  (\(detail))")")
        if !passed { failures += 1 }
    }

    private static func wait(_ seconds: Double, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return true
    }

    /// The fixtures, found above the application as the library is.
    private static func fixtures() -> URL? {
        var folder = Bundle.main.bundleURL
        for _ in 0..<6 {
            folder = folder.deletingLastPathComponent()
            let candidate = folder.appendingPathComponent("Tests/Fixtures/queue-status")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static func exercise() {
        guard let fixtures = fixtures(), let runner = QueueModel.runnerExecutable else {
            check("les fixtures et le runner sont trouvés", false)
            return
        }
        let paris = TimeZone(identifier: "Europe/Paris")!
        let names =
            ((try? FileManager.default.contentsOfDirectory(atPath: fixtures.path)) ?? []).filter {
                !$0.hasPrefix(".")
            }.sorted()
        check("les fixtures sont là", names.count >= 7, "\(names.count)")
        for name in names {
            let folder = fixtures.appendingPathComponent(name)
            let read = { (file: String) in
                (try? String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            }
            let now = RunStatus.date(read("now.txt")) ?? Date()
            let count = Int(read("processes.txt")) ?? 0
            let processes = (0..<count).map {
                QueueStatus.ProcessInfo(pid: Int32(1_000 + $0), arguments: ["sillage-render", "render"])
            }
            let library = folder.appendingPathComponent("library")
            let model = QueueModel(
                library: library, watch: false,
                status: {
                    QueueStatus.read(
                        library: $0, now: now, timeZone: paris, processes: processes,
                        isAlive: { _ in true })
                })
            let expected = read("expected.txt").split(separator: "\n").map(String.init)
            check("\(name) : l'app dit ce que disent les fichiers", model.status.lines == expected)

            let printed = status(runner, library: library, now: read("now.txt"), processes: count)
            check(
                "\(name) : `sillage-render status` dit la même chose",
                printed == model.status.lines,
                printed.first ?? "aucune sortie")

            write(
                AnyView(QueueView(queue: model).frame(width: 760, height: 620)),
                to: "out/ui-queue-\(name).png")
            write(
                AnyView(
                    SidebarStatus(
                        model: SimulationModel()!, queue: model, openQueue: {}, openWorkshop: {}
                    )
                    .frame(width: 230)),
                to: "out/ui-queue-sidebar-\(name).png")
        }
        live()
        realProcess()
    }

    /// What the command prints for a library, as lines.
    private static func status(
        _ executable: URL, library: URL, now: String, processes: Int
    ) -> [String] {
        let process = Process()
        process.executableURL = executable
        process.arguments = [
            "status", "--library", library.path, "--now", now, "--timezone", "Europe/Paris",
            "--fixture", String(processes),
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// A library edited while the model watches it: the sidebar's line follows in two seconds.
    private static func live() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sillage-statuscheck-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = QueueModel(
            library: root,
            status: { QueueStatus.read(library: $0, processes: [], isAlive: { _ in true }) })
        check(
            "bibliothèque vide : le Mac est libre",
            model.status.statusLine == "Rien en cours · le Mac est libre")

        func follows(_ name: String, _ change: () throws -> Void, until: () -> Bool) {
            let started = Date()
            do { try change() } catch { check(name, false, "\(error)") }
            let seen = wait(2) { until() }
            check(
                "\(name) en moins de 2 s", seen,
                String(format: "%.2f s", Date().timeIntervalSince(started)))
        }

        let batch = root.appendingPathComponent("2026-10-27")
        let job = ActivityFile.Job(
            kind: "hires", batch: "2026-10-27", scene: "scene-0001", startedAt: Date(),
            progress: 0.25, detail: "frame 225/900", eta: Date().addingTimeInterval(3_600))
        follows(
            "une étape lancée à la main apparaît",
            {
                let activity = ActivityFile(state: .running, job: job, waiting: 0, updated: Date())
                try RunStatusFiles.write(
                    activity.encoded(), to: RunStatusFiles.activity(library: root))
            },
            until: { model.status.running?.detail == "image 225/900" })
        follows(
            "une tâche mise en file est comptée",
            {
                _ = try model.store.submit(
                    .hires, path: batch.appendingPathComponent("scene-0002").path, runner: nil)
            },
            until: { model.status.waitingCount == 1 && model.status.waiting.count == 1 })
        follows(
            "la file annulée repart à zéro",
            {
                try model.cancel(model.queue.waiting[0].id)
            },
            until: { model.status.waitingCount == 0 && model.status.finished.count == 1 })
        follows(
            "l'étape finie rend le Mac libre",
            {
                try RunStatusFiles.write(
                    ActivityFile(state: .idle, updated: Date()).encoded(),
                    to: RunStatusFiles.activity(library: root))
            },
            until: { model.status.statusLine == "Rien en cours · le Mac est libre" })
    }

    /// A real `sillage-render` process that wrote no status: "le Mac est libre" must not be said.
    /// It is started suspended, so it does nothing and takes no GPU.
    private static func realProcess() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sillage-statuscheck-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        guard let executable = QueueModel.runnerExecutable else { return }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_START_SUSPENDED))
        let arguments = ["sillage-render", "hires", root.path]
        var pid: pid_t = 0
        let cArguments = arguments.map { strdup($0) } + [nil]
        let result = posix_spawn(&pid, executable.path, nil, &attributes, cArguments, environ)
        for pointer in cArguments { free(pointer) }
        posix_spawnattr_destroy(&attributes)
        guard result == 0 else {
            check("un processus sillage-render sans état", false, "posix_spawn \(result)")
            return
        }
        defer {
            kill(pid, SIGKILL)
            var code: Int32 = 0
            waitpid(pid, &code, 0)
        }
        let model = QueueModel(library: root, watch: false)
        let said = wait(2) {
            model.refresh()
            return model.status.headline == "Calcul en cours (sans détail)"
        }
        check(
            "un sillage-render sans état : « Calcul en cours (sans détail) »", said,
            model.status.headline)
    }

    private static func write(_ view: AnyView, to path: String) {
        let renderer = ImageRenderer(
            content: view.environment(\.colorScheme, .dark).background(Palette.panel))
        renderer.scale = 1
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else {
            check("\(path) est dessiné", false)
            return
        }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? png.write(to: url)
        check("\(path) est dessiné", png.count > 2_000, "\(png.count) octets")
    }
}
