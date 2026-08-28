import AppKit
import Foundation
import SillageCore

/// Drives the setup screen's presets with the window up, which is the only way to catch the
/// class of bug they hit: a preset that shrinks the galaxy list makes SwiftUI evaluate the
/// card of an index that no longer exists. Offscreen rendering never sees it, because the
/// view tree is built once and never updated.
enum PresetCheck {
    @MainActor
    static func run(_ model: SimulationModel) {
        guard CommandLine.arguments.contains("--presets") else { return }
        Task {
            var report = ""
            @MainActor func step(_ name: String, _ scene: SceneConfig) async {
                model.loadPreset(scene)
                model.commitDraftChange()
                try? await Task.sleep(for: .seconds(1))
                report +=
                    "\(name.padding(toLength: 10, withPad: " ", startingAt: 0)) "
                    + "\(model.draft.name) · \(model.draft.galaxies.count) galaxies · "
                    + "\(model.previewParticleCount) particules d'aperçu\n"
            }

            try? await Task.sleep(for: .seconds(1))
            let total = max(model.draft.totalParticleCount, 100_000)
            await step("flyby", .flyby(particleCount: total))
            await step("isolated", .isolatedDisk(particleCount: total))
            await step("merger", .merger(particleCount: total))

            // Removal walks the same stale-index path as a shrinking preset.
            model.removeGalaxy(at: 1)
            model.commitDraftChange()
            try? await Task.sleep(for: .seconds(1))
            report += "remove     \(model.draft.galaxies.count) galaxies\n"
            model.addGalaxy()
            model.commitDraftChange()
            try? await Task.sleep(for: .seconds(1))
            report += "add        \(model.draft.galaxies.count) galaxies\n"

            // Launched through `open` the process has no stdout, so the result goes to a file.
            try? report.write(
                to: URL(fileURLWithPath: "/tmp/sillage-presets.log"), atomically: true,
                encoding: .utf8)
            print(report)
            exit(model.draft.galaxies.count == 2 && model.failure == nil ? 0 : 1)
        }
    }
}
