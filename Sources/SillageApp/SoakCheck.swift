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

    /// How many knots the run has made, and how many of them are still lit.
    ///
    /// The same test the shader makes: only gas glows, and it glows as `exp(-age/ionisedMyr)`,
    /// so a knot is counted as lit while that weight is above the threshold the renderer
    /// itself uses to widen a point. The formation array is read straight out of the solver's
    /// buffer rather than through `particles`, which copies the whole system.
    @MainActor
    private static func knots(_ model: SimulationModel, nursery: inout [Bool]) -> (Int, Int) {
        guard let solver = model.solver as? MetalBarnesHutSolver else { return (0, 0) }
        if nursery.isEmpty {
            nursery = solver.particles.component.map {
                $0 == ParticleComponent.hiiRegion.rawValue || $0 == ParticleComponent.dust.rawValue
            }
        }
        let count = nursery.count
        guard count > 0 else { return (0, 0) }
        let born = solver.formation.contents().bindMemory(to: Float.self, capacity: count)
        let now = solver.time
        let cutoff = -log(Float(0.15)) * StarFormation.ionisedMyr
        var formed = 0
        var lit = 0
        for index in 0..<count where nursery[index] {
            let at = born[index]
            guard abs(at) < 1e8 else { continue }
            let age = (now - at) * Float(Physics.megayearsPerTimeUnit)
            guard age >= 0 else { continue }
            formed += 1
            if age < cutoff { lit += 1 }
        }
        return (formed, lit)
    }

    @MainActor
    static func run(_ model: SimulationModel) {
        guard let flag = CommandLine.arguments.firstIndex(of: "--soak") else { return }
        let particles =
            flag + 1 < CommandLine.arguments.count
            ? Int(CommandLine.arguments[flag + 1]) ?? 400_000 : 400_000
        let path = "/tmp/sillage-soak.log"
        // The isolated disk is the control every star formation measurement here needs: a
        // merger always has a bump somewhere, and only a galaxy with nothing to collide with
        // says whether the rate holds on its own.
        let quiet = CommandLine.arguments.contains("disque")
        model.draft =
            quiet ? .isolatedDisk(particleCount: particles) : .merger(particleCount: particles)
        // Nothing is being looked at, and the picture is not free: the canvas and the solver
        // pull on the same GPU, so a soak that draws is a soak that measures itself competing
        // with its own display. `écran` puts it back for when somebody does want to watch.
        model.showCanvasWhileRunning = CommandLine.arguments.contains("écran")
        model.draft.solver = .barnesHut
        model.draft.retune()
        model.setTotalParticles(particles)
        model.start()

        Task {
            let clock = Date()
            let stamp = DateFormatter()
            stamp.dateFormat = "HH:mm:ss"
            var lines = [
                "heure     wall s   cpu s   Myr      Myr/s  cpu/s  pas   images  formés  +formés  allumés  écran"
            ]
            var lastWall = 0.0
            var lastMyr = 0.0
            var lastCPU = 0.0
            var lastSteps = 0
            var lastFormed = 0
            // Which particles can ever glow. Read once: it never changes, and the whole
            // system is several megabytes a copy.
            var nursery: [Bool] = []
            while true {
                try? await Task.sleep(for: .seconds(5))
                let wall = Date().timeIntervalSince(clock)
                let cpu = processorSeconds()
                let myr = model.elapsedMyr
                let span = max(wall - lastWall, 1e-6)
                let awake = NSApp.windows.contains { $0.occlusionState.contains(.visible) }
                let (formed, lit) = knots(model, nursery: &nursery)
                lines.append(
                    String(
                        format:
                            "%@  %6.0f  %6.0f  %7.1f  %5.2f  %5.2f  %5d  %6d  %6d  %7d  %7d  %@",
                        stamp.string(from: Date()), wall, cpu, myr,
                        (myr - lastMyr) / span, (cpu - lastCPU) / span,
                        model.solverSteps - lastSteps, model.framesDrawn,
                        formed, formed - lastFormed, lit,
                        awake ? "allumé" : "éteint"))
                lastFormed = formed
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
