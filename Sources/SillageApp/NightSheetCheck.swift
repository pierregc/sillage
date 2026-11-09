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
        let report = lines.joined(separator: "\n") + "\n\n\(failures) failed"
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

    /// The check and its pictures plan at this evening: before 07:00, the real clock leaves the
    /// night under two hours and its plan no hires line.
    static let evening = Calendar.current.date(bySettingHour: 21, minute: 40, second: 0, of: Date()) ?? Date()

    private static func exercise(_ root: URL) {
        let model = NightSheetModel(library: root, clock: { evening })
        let started = Date()
        check("the plan comes (the night's real draws)", wait(60) { model.plan != nil })
        let first = Date().timeIntervalSince(started)
        check("the sheet opens on Ready by 07:00", model.sheet == NightSheet(), "plan in \(ms(first))")
        guard let plan = model.plan else { return }
        check(
            "a line per step, then the delivery",
            plan.lines.map(\.title) == ["Previews", "High resolution", "Style", "Videos"]
                && plan.delivery.hasPrefix("Ready "),
            plan.lines.map(\.text).joined(separator: " | "))
        check(
            "each line gives its duration and its end",
            plan.lines.allSatisfy { !$0.duration.isEmpty && $0.until.hasPrefix("until ") })

        let changes: [(String, () -> Void)] = [
            (
                "Duration 6 h",
                {
                    model.sheet.timing = .hours
                    model.sheet.hours = 6
                }
            ),
            (
                "Ready by 06:30",
                {
                    model.sheet.timing = .deliver
                    model.sheet.deliverMinutes = 390
                }
            ),
            ("3 scenes in high resolution", { model.sheet.hiresScenes = 3 }),
            ("Telescope world", { model.sheet.world = "telescope" }),
            ("without the vertical video", { model.sheet.vertical = false }),
            ("previews only", { model.sheet.exploreOnly = true }),
        ]
        // Auto may draw every pick tonight in the telescope world: from the free one, the change
        // of world always shows.
        _ = replanned(model) { model.sheet.world = "free" }
        var slowest = 0.0
        var before = model.plan
        for (name, change) in changes {
            if let seconds = replanned(model, change) {
                slowest = max(slowest, seconds)
                check("the plan follows: \(name)", model.plan != before, "in \(ms(seconds))")
            } else {
                check("the plan follows: \(name)", false, "no new plan")
            }
            before = model.plan
        }
        check("each plan comes in under half a second", slowest < 0.5, "at most \(ms(slowest))")
        check(
            "previews only keeps the previews alone",
            model.plan?.lines.map(\.title) == ["Previews"])

        // Launching: a night in the queue, its own recipe, the settings kept.
        model.sheet = NightSheet()
        model.sheet.hiresScenes = 2
        _ = wait(5) { model.plan?.lines.count == 4 }
        let queue = QueueStore(library: root)
        let launched = model.launch { _ = try $0.launch(library: root, runner: nil) }
        let waiting = queue.read().waiting
        check(
            "launching adds the night to the queue",
            launched && waiting.count == 1 && waiting[0].kind == .night)
        if let file = waiting.first?.options.first,
            let recipe = try? NightRecipe.read(URL(fileURLWithPath: file))
        {
            check("with its recipe", recipe.pick == .count(2) && recipe.deliver == .value("07:00"))
        } else {
            check("with its recipe", false)
        }
        check("the last settings are kept", NightSheetModel(library: root).sheet == model.sheet)

        // A night too big for the disk or the time warns and can still be launched.
        let small = NightSheetModel(
            library: root,
            planner: NightSheetPlanner(library: root, freeBytes: 1e9, draws: fixedDraws), clock: { evening })
        small.sheet.timing = .hours
        small.sheet.hours = 8
        check("a plan too big warns", wait(5) { small.plan?.warnings.isEmpty == false })
        let kinds = small.plan?.warnings.map(\.kind) ?? []
        check("the disk is flagged", kinds.contains("disk"), kinds.joined(separator: ", "))
        small.sheet.hours = 1
        check(
            "a night too short is flagged",
            wait(5) { small.plan?.warnings.contains { $0.kind != "disk" } == true },
            small.plan?.warnings.map(\.kind).joined(separator: ", ") ?? "")
        check(
            "without blocking the launch",
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
            let model = NightSheetModel(
                library: root, planner: planner(free: free), debounce: .zero, clock: { evening })
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
