import AppKit
import Foundation
import SillageCore

/// Measures how long the main actor is held while a scene runs. Every control on the window
/// is driven from there, so the longest stall is the answer to whether the panel is usable.
enum ResponsivenessCheck {
    @MainActor
    static func run(_ model: SimulationModel) {
        guard CommandLine.arguments.contains("--responsive") else { return }
        Task {
            model.draft.solver = .barnesHut
            model.draft.retune()
            model.setTotalParticles(400_000)
            model.start()
            try? await Task.sleep(for: .seconds(1))

            // A wake-up asked for every 16 ms comes back late by exactly as long as the main
            // actor was busy, so the gaps are the stall.
            let interval = Duration.milliseconds(16)
            var gaps: [Double] = []
            let started = Date()
            var last = Date()
            while Date().timeIntervalSince(started) < 8 {
                try? await Task.sleep(for: interval)
                let now = Date()
                gaps.append((now.timeIntervalSince(last) - 0.016) * 1000)
                last = now
                model.drawOnce()
            }

            gaps.sort()
            let worst = gaps.last ?? 0
            let median = gaps.isEmpty ? 0 : gaps[gaps.count / 2]
            let over100 = gaps.filter { $0 > 100 }.count
            let report = """
                particles      \(model.particleCount) simulated
                main-actor stall
                  median       \(String(format: "%.1f", median)) ms
                  worst        \(String(format: "%.0f", worst)) ms
                  over 100 ms  \(over100) of \(gaps.count) wake-ups
                simulated      \(String(format: "%.1f", model.elapsedMyr)) Myr in 8 s
                frames drawn   \(model.framesDrawn)
                """
            try? report.write(
                to: URL(fileURLWithPath: "/tmp/sillage-responsive.log"), atomically: true,
                encoding: .utf8)
            print(report)
            exit(0)
        }
    }
}
