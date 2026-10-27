import AppKit
import Foundation
import SillageRender
import SwiftUI

/// `--nightcheck`: the new night sheet without a window. The model against the real batch
/// draws on a library of its own: the plan comes, follows every change within half a second,
/// warns without blocking, and a launch puts a night in the queue with its own recipe and
/// leaves its settings for the next sheet. Then the sheet in `out/ui-night-sheet*.png`. No GPU.
@MainActor
enum NightSheetCheck {
    private static var lines: [String] = []
    private static var failures = 0

    static func run() {
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sillage-nightcheck-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        exercise(root)
        pictures()
        if failures == 0 { try? FileManager.default.removeItem(at: root) }
        let report = lines.joined(separator: "\n") + "\n\n\(failures) échec(s)"
        try? report.write(
            to: URL(fileURLWithPath: "/tmp/sillage-night.log"), atomically: true, encoding: .utf8)
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
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return true
    }

    /// Waits for the plan a change asks for and returns how long it took.
    private static func replanned(_ model: NightSheetModel, _ change: () -> Void) -> TimeInterval? {
        let before = model.lastLatency
        let clock = Date()
        change()
        guard wait(5, until: { model.lastLatency != before && model.lastLatency != nil }) else {
            return nil
        }
        return Date().timeIntervalSince(clock)
    }

    private static func exercise(_ root: URL) {
        let model = NightSheetModel(library: root)
        let started = Date()
        check("le plan vient (les tirages réels de la nuit)", wait(60) { model.plan != nil })
        let first = Date().timeIntervalSince(started)
        check("la feuille s'ouvre sur Prêt à 7 h 00", model.sheet == NightSheet(), "plan en \(ms(first))")
        guard let plan = model.plan else { return }
        check(
            "une ligne par étape, puis la livraison",
            plan.lines.map(\.title) == ["Aperçus", "Haute résolution", "Style", "Vidéos"]
                && plan.delivery.hasPrefix("Prêt "),
            plan.lines.map(\.text).joined(separator: " | "))
        check(
            "chaque ligne dit sa durée et sa fin",
            plan.lines.allSatisfy { !$0.duration.isEmpty && $0.until.hasPrefix("jusqu'à ") })

        let changes: [(String, () -> Void)] = [
            (
                "Pendant 6 h",
                {
                    model.sheet.timing = .hours
                    model.sheet.hours = 6
                }
            ),
            (
                "Prêt à 6 h 30",
                {
                    model.sheet.timing = .deliver
                    model.sheet.deliverMinutes = 390
                }
            ),
            ("3 scènes en haute résolution", { model.sheet.hiresScenes = 3 }),
            ("Monde Télescope", { model.sheet.world = "telescope" }),
            ("sans la vidéo verticale", { model.sheet.vertical = false }),
            ("exploration seulement", { model.sheet.exploreOnly = true }),
        ]
        var slowest = 0.0
        var before = model.plan
        for (name, change) in changes {
            if let seconds = replanned(model, change) {
                slowest = max(slowest, seconds)
                check("le plan suit : \(name)", model.plan != before, "en \(ms(seconds))")
            } else {
                check("le plan suit : \(name)", false, "pas de nouveau plan")
            }
            before = model.plan
        }
        check("chaque plan vient en moins d'une demi-seconde", slowest < 0.5, "au plus \(ms(slowest))")
        check(
            "exploration seulement ne garde que les aperçus",
            model.plan?.lines.map(\.title) == ["Aperçus"])

        // Launching: a night in the queue, its own recipe, the settings kept.
        model.sheet = NightSheet()
        model.sheet.hiresScenes = 2
        _ = wait(5) { model.plan?.lines.count == 4 }
        let queue = QueueStore(library: root)
        let launched = model.launch { _ = try $0.launch(library: root, runner: nil) }
        let waiting = queue.read().waiting
        check("lancer ajoute la nuit à la file", launched && waiting.count == 1 && waiting[0].kind == .night)
        if let file = waiting.first?.options.first,
            let recipe = try? NightRecipe.read(URL(fileURLWithPath: file))
        {
            check("avec sa recette", recipe.pick == .count(2) && recipe.deliver == .value("07:00"))
        } else {
            check("avec sa recette", false)
        }
        check("les derniers réglages sont gardés", NightSheetModel(library: root).sheet == model.sheet)

        // A night too big for the disk or the time warns and can still be launched.
        let small = NightSheetModel(
            library: root,
            planner: NightSheetPlanner(library: root, freeBytes: 1e9, draws: fixedDraws))
        small.sheet.timing = .hours
        small.sheet.hours = 8
        check("un plan trop gros prévient", wait(5) { small.plan?.warnings.isEmpty == false })
        let kinds = small.plan?.warnings.map(\.kind) ?? []
        check("le disque est signalé", kinds.contains("disk"), kinds.joined(separator: ", "))
        small.sheet.hours = 1
        check(
            "une nuit trop courte est signalée",
            wait(5) { small.plan?.warnings.contains { $0.kind != "disk" } == true },
            small.plan?.warnings.map(\.kind).joined(separator: ", ") ?? "")
        check(
            "sans bloquer le lancement",
            small.launch { _ in } && !small.launching && small.failure == nil)
    }

    private static func ms(_ seconds: TimeInterval) -> String { String(format: "%.0f ms", seconds * 1000) }

    // MARK: Pictures

    /// The draws of a night of the size of the 2026-10-25 one, so the pictures do not wait for
    /// the real ones.
    static let fixedDraws: @Sendable (Int) -> [NightScene] = { perGalaxy in
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

    static let costs = CostModel(
        updated: Date(),
        explore: .init(fixedSeconds: 20.905, secondsPerUnit: 1.2171e-7, source: .fitted, samples: 52),
        hires: .init(fixedSeconds: 0, secondsPerUnit: 1.5185e-7, source: .scaled, samples: 6))

    /// The sheet as it opens, and with a custom night that does not fit, at the evening of a
    /// fixed day so the pictures can be compared.
    static func pictures() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sillage-nightsheet-picture-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let queue = QueueModel(library: root, watch: false)
        let evening = Calendar.current.date(bySettingHour: 21, minute: 40, second: 0, of: Date()) ?? Date()
        func planner(free: Double) -> NightSheetPlanner {
            NightSheetPlanner(
                library: root, now: evening, model: costs, maximumParticles: 10_000_000,
                freeBytes: free, draws: fixedDraws)
        }
        let pictures: [(name: String, free: Double, change: (inout NightSheet) -> Void)] = [
            ("", 500e9, { _ in }),
            (
                "-warning", 12e9,
                { sheet in
                    sheet.timing = .hours
                    sheet.hours = 3
                    sheet.hiresScenes = 4
                    sheet.world = "telescope"
                    sheet.vertical = false
                }
            ),
        ]
        for (name, free, change) in pictures {
            let model = NightSheetModel(library: root, planner: planner(free: free), debounce: .zero)
            _ = wait(10) { model.lastLatency != nil }
            let before = model.lastLatency
            var sheet = NightSheet()
            change(&sheet)
            model.sheet = sheet
            if sheet != NightSheet() { _ = wait(10) { model.lastLatency != before } }
            SillageApp.write(
                AnyView(NightSheetView(model: model, queue: queue, snapshot: true)),
                to: "out/ui-night-sheet\(name).png")
        }
    }
}
