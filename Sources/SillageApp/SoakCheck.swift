import AppKit
import Foundation
import SillageCore
import SillageRender

/// Leaves a run going and writes down, every few seconds, whether it is still going.
///
/// A run that quietly stops overnight leaves nothing behind to look at: the window shows a
/// number that has not moved and there is no way to tell when it stopped moving, or what the
/// machine was doing at the time. This writes a line a few seconds apart with the wall clock,
/// the processor time this process has actually burned, how far the solver has got, and
/// whether the window was on a display that was awake. A stall then reads straight off the
/// file — and the processor column separates a solver that stopped from a logger that was
/// merely throttled, which the timestamps alone cannot do.
enum SoakCheck {
    /// Seconds of processor time this process has used, user and system together.
    private static func processorSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
        let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
        return user + system
    }

    @MainActor
    static func run(_ model: SimulationModel) {
        guard let flag = CommandLine.arguments.firstIndex(of: "--soak") else { return }
        let particles =
            flag + 1 < CommandLine.arguments.count
            ? Int(CommandLine.arguments[flag + 1]) ?? 400_000 : 400_000
        let path = "/tmp/sillage-soak.log"
        model.draft = .merger(particleCount: particles)
        model.draft.solver = .barnesHut
        model.draft.retune()
        model.setTotalParticles(particles)
        model.start()

        Task {
            let clock = Date()
            let stamp = DateFormatter()
            stamp.dateFormat = "HH:mm:ss"
            var lines = [
                "heure     wall s   cpu s   Myr      Myr/s  cpu/s  pas   images  écran"
            ]
            var lastWall = 0.0
            var lastMyr = 0.0
            var lastCPU = 0.0
            var lastSteps = 0
            while true {
                try? await Task.sleep(for: .seconds(5))
                let wall = Date().timeIntervalSince(clock)
                let cpu = processorSeconds()
                let myr = model.elapsedMyr
                let span = max(wall - lastWall, 1e-6)
                let awake = NSApp.windows.contains { $0.occlusionState.contains(.visible) }
                lines.append(
                    String(
                        format: "%@  %6.0f  %6.0f  %7.1f  %5.2f  %5.2f  %5d  %6d  %@",
                        stamp.string(from: Date()), wall, cpu, myr,
                        (myr - lastMyr) / span, (cpu - lastCPU) / span,
                        model.solverSteps - lastSteps, model.framesDrawn,
                        awake ? "allumé" : "éteint"))
                lastWall = wall
                lastMyr = myr
                lastCPU = cpu
                lastSteps = model.solverSteps
                // Rewritten whole every time rather than appended: the file is then always
                // complete and readable, including after a kill.
                try? lines.joined(separator: "\n").write(
                    to: URL(fileURLWithPath: path), atomically: true, encoding: .utf8)
            }
        }
    }
}
