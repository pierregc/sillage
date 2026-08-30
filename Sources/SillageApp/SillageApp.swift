import AppKit
import Foundation
import SillageRender
import SwiftUI

/// Pins the AppKit appearance to dark. SwiftUI's `preferredColorScheme` recolours SwiftUI's
/// own text but leaves NSColor-derived backgrounds following the system theme, which is how
/// a light system ends up drawing dark labels on the black canvas.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
    }
}

@main
struct SillageApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = SimulationModel()!

    init() {
        if CommandLine.arguments.contains("--selftest") {
            MainActor.assumeIsolated { SillageApp.runSelfTest() }
        }
        if CommandLine.arguments.contains("--uishot") {
            MainActor.assumeIsolated { SillageApp.renderInterface() }
        }
    }

    var body: some Scene {
        WindowGroup("Sillage") {
            Group {
                switch model.stage {
                case .setup: SetupView(model: model)
                case .running:
                    if model.contemplating {
                        ContemplationView(model: model)
                    } else {
                        RunningView(model: model)
                    }
                }
            }
            .frame(minWidth: 1100, minHeight: 720)
            // The panel draws on the system background, so the appearance is pinned rather
            // than letting a light theme put dark text on the black canvas.
            .preferredColorScheme(.dark)
            .onAppear {
                startFrameCheck()
                startCinemaCheck()
                PresetCheck.run(model)
                ResponsivenessCheck.run(model)
                QACheck.run(model)
            }
        }
        .windowResizability(.contentMinSize)
    }

    /// Opens the real window, lets the display link run, then reports how many frames the
    /// MTKView delegate actually drew. Proves the windowed path, not just the offscreen one.
    @MainActor
    private func startFrameCheck() {
        guard CommandLine.arguments.contains("--verify") else { return }
        model.draft.solver = .restricted
        model.draft.retune()
        model.setTotalParticles(1_000_000)
        model.start(waiting: true)
        Task {
            // Give SwiftUI a moment to build the canvas, then drive it directly rather than
            // waiting on a display link the window server has parked.
            try? await Task.sleep(for: .seconds(1))
            let clock = Date()
            while Date().timeIntervalSince(clock) < 3 {
                model.drawOnce()
                await Task.yield()
            }
            let drawn = model.framesDrawn
            let report = """
                frames drawn   \(drawn)
                frame time     \(String(format: "%.1f", model.frameMilliseconds)) ms
                particles      \(model.particleCount)
                stage          \(model.stage)
                draw attempts  \(model.drawAttempts)
                solver         \(model.solver == nil ? "nil" : model.scene.solver.rawValue)
                renderer       \(model.renderer == nil ? "nil" : "ready")
                failure        \(model.failure ?? "none")
                onscreen       \(NSApp.windows.contains { $0.occlusionState.contains(.visible) })
                gpu            \(model.gpuName)
                """
            // Launched through `open` the process has no stdout and its working directory
            // is the root, so the result goes to an absolute path.
            try? report.write(
                to: URL(fileURLWithPath: "/tmp/sillage-verify.log"), atomically: true,
                encoding: .utf8)
            print(report)
            exit(drawn > 30 ? 0 : 1)
        }
    }

    /// Runs contemplation for a while through the real draw path and reports what it cost.
    /// A mode whose whole promise is "no stutter" needs a number rather than an opinion, and
    /// there is no watching the screen on this machine.
    @MainActor
    private func startCinemaCheck() {
        guard CommandLine.arguments.contains("--cinema") else { return }
        let seconds =
            CommandLine.arguments.firstIndex(of: "--cinema").map { index -> Double in
                index + 1 < CommandLine.arguments.count
                    ? Double(CommandLine.arguments[index + 1]) ?? 45 : 45
            } ?? 45
        // Deliberately not overriding the particle count: a check that measures a size the
        // mode never runs at measures nothing. This one did, and reported a stutter that was
        // its own doing.
        // "classic" runs an ordinary scene through the identical harness. Contemplation
        // stutters where a classic run of nine times the particles does not, so the only
        // useful measurement is the difference between the two with everything else equal.
        if CommandLine.arguments.contains("classic") {
            model.draft = .merger(particleCount: 700_000)
            model.draft.solver = .barnesHut
            for index in model.draft.galaxies.indices {
                model.draft.galaxies[index].haloParticleRatio = 0
            }
            model.draft.retune()
            model.start()
        } else {
            let pace: SimulationModel.Pace =
                CommandLine.arguments.contains("slow") ? .slow : .brisk
            model.startContemplation(pace: pace)
        }
        Task {
            try? await Task.sleep(for: .seconds(2))
            // Paced to sixty hertz and measured on lateness, not on the cost of a draw. The
            // first version of this ran draws back to back and reported a healthy median
            // while the real thing stuttered: what a viewer sees is whether a frame arrives
            // on time, and a solver that holds the GPU for eight milliseconds at the wrong
            // moment blows the deadline without moving the median at all.
            let period = 1.0 / 60.0
            var late: [Double] = []
            var visible: [Double] = []
            var moves: Set<String> = []
            var scenes: Set<UInt64> = []
            let clock = Date()
            var due = Date().timeIntervalSince(clock)
            while Date().timeIntervalSince(clock) < seconds {
                let before = Date().timeIntervalSince(clock)
                model.drawOnce()
                let after = Date().timeIntervalSince(clock)
                if !model.isPreparing {
                    let slip = max(after - due, 0)
                    late.append(slip)
                    // A frame nobody can see cannot stutter: the swap between scenes happens
                    // under a fade that is already at black. Counted separately rather than
                    // excused, so the two are never confused.
                    if model.renderFade > 0.15 { visible.append(slip) }
                }
                moves.insert("\(model.director.move)")
                scenes.insert(model.scene.seed)
                due += period
                // Wait out the rest of the frame, so the solver gets the idle time it would
                // really have between two presentations.
                let slack = due - after
                if slack > 0 {
                    try? await Task.sleep(for: .seconds(slack))
                } else {
                    due = after
                    await Task.yield()
                }
                _ = before
            }
            let sorted = late.sorted()
            func percentile(_ share: Double) -> Double {
                sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * share))]
            }
            // A frame is late enough to see when it misses its slot by most of another one.
            let missed = late.filter { $0 > period }.count
            let report = """
                scene          \(model.scene.galaxies.count) galaxies, \(model.particleCount) particles, \(model.scene.solver.rawValue)
                pace           \(model.contemplationPace.rawValue)
                rate           \(String(format: "%.2f", model.megayearsPerSecond)) Myr/s stepping, asking \(String(format: "%.1f", model.contemplationMyrPerSecond))
                immersed       \(model.director.immersed)
                frames         \(late.count) in \(String(format: "%.0f", seconds)) s
                late median    \(String(format: "%.1f", percentile(0.5) * 1000)) ms
                late 99th      \(String(format: "%.1f", percentile(0.99) * 1000)) ms
                late worst     \(String(format: "%.1f", (sorted.last ?? 0) * 1000)) ms
                missed a slot  \(missed) of \(late.count)
                missed on show \(visible.filter { $0 > period }.count) of \(visible.count)
                really drew    \(model.framesDrawn) of \(late.count) calls
                drawable       \(Int(model.drawableSize.width)) x \(Int(model.drawableSize.height)) at \(model.supersample)x
                renderer built \(model.rendererBuilds) times
                frame cpu      \(String(format: "%.1f", model.frameMilliseconds)) ms encoding
                frame gpu      \(String(format: "%.1f", model.renderer?.lastGPUMilliseconds ?? 0)) ms drawing
                pixels shaded  \(String(format: "%.1f", Double(model.drawableSize.width * model.drawableSize.height) * Double(model.supersample * model.supersample) / 1e6)) M
                solver steps   \(String(format: "%.0f", Double(model.solverSteps) / max(seconds, 1))) a second
                solver burst   \(burstReport(model.solverBursts))
                longest hold   \(String(format: "%.1f", model.longestDispatch)) ms in one dispatch
                frame gap      \(gapReport(model.frameGaps))
                step split     drift \(String(format: "%.0f", model.stepDrift)) ms, tree \(String(format: "%.0f", model.stepTree)) ms (build \(String(format: "%.0f", model.stepBuild))), forces \(String(format: "%.0f", model.stepForce)) ms
                draw attempts  \(model.drawAttempts)
                moves seen     \(moves.sorted().joined(separator: " "))
                scenes seen    \(scenes.count)
                failure        \(model.failure ?? "none")
                """
            try? report.write(
                to: URL(fileURLWithPath: "/tmp/sillage-cinema.log"), atomically: true,
                encoding: .utf8)
            print(report)
            // Judged on what a viewer can actually see.
            let seen = visible.filter { $0 > period }.count
            let clean = Double(seen) / Double(max(visible.count, 1)) < 0.002
            exit(visible.count > 100 && clean ? 0 : 1)
        }
    }

    /// What a viewer actually sees: the interval between consecutive frames.
    private func gapReport(_ gaps: [Double]) -> String {
        guard !gaps.isEmpty else { return "none" }
        let sorted = gaps.sorted()
        let stalled = gaps.filter { $0 > 50 }.count
        return String(
            format: "median %.1f ms, 99th %.0f, worst %.0f, %d of %d over 50 ms",
            sorted[sorted.count / 2], sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))],
            sorted.last ?? 0, stalled, gaps.count)
    }

    /// The length of the solver's uninterrupted holds on the GPU, which is what a visible
    /// window waits behind and an occluded one never sees.
    private func burstReport(_ bursts: [Double]) -> String {
        guard !bursts.isEmpty else { return "none" }
        let sorted = bursts.sorted()
        let over = bursts.filter { $0 > 8 }.count
        return String(
            format: "median %.0f ms, worst %.0f ms, %d of %d over 8 ms",
            sorted[sorted.count / 2], sorted.last ?? 0, over, bursts.count)
    }

    /// Renders the panels offscreen with `ImageRenderer` so their legibility can be checked
    /// without a window server. Catches things a running app hides, such as text drawn in a
    /// colour that matches its own background.
    @MainActor
    private static func renderInterface() {
        guard let model = SimulationModel() else { exit(1) }
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        model.start(waiting: true)
        write(AnyView(SetupContent(model: model).padding(20).frame(width: 720)), to: "out/ui-setup.png")
        write(
            AnyView(ControlPanelContent(model: model).padding(14).frame(width: 276)), to: "out/ui-panel.png")
        exit(0)
    }

    @MainActor
    private static func write(_ view: AnyView, to path: String) {
        let renderer = ImageRenderer(
            content: view.environment(\.colorScheme, .dark).background(Palette.panel))
        renderer.proposedSize = .unspecified
        renderer.scale = 2
        guard let image = renderer.nsImage,
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("uishot: render failed for \(path)\n".utf8))
            return
        }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? png.write(to: url)
        print("uishot wrote \(path)")
    }

    /// Exercises model creation, resize, stepping and rendering without opening a window,
    /// then exits. Keeps the app path verifiable on machines where a window cannot be shown.
    @MainActor
    private static func runSelfTest() {
        guard let model = SimulationModel() else {
            FileHandle.standardError.write(Data("selftest: no Metal device\n".utf8))
            exit(1)
        }
        // The render path is what is under test here, so it runs on the cheap solver: a
        // self-gravitating run of the same length would take the best part of an hour.
        model.draft.solver = .restricted
        model.draft.retune()
        model.setTotalParticles(1_000_000)
        model.start(waiting: true)
        model.resize(to: CGSize(width: 1280, height: 720))
        guard let pixels = model.snapshot(steps: 1_200) else {
            FileHandle.standardError.write(Data("selftest: renderer unavailable\n".utf8))
            exit(1)
        }
        let lit = pixels.enumerated().filter { $0.offset % 4 != 3 && $0.element > 8 }.count
        print("selftest stage       \(model.stage)")
        print("selftest particles   \(model.particleCount)")
        print("selftest lit samples \(lit)")

        // The setup screen's preview has its own pipeline; check it samples too.
        model.returnToSetup()
        model.rebuildPreview(waiting: true)
        print("selftest preview     \(model.previewParticleCount) particules")
        let preview = model.previewSnapshot() ?? []
        let previewLit = preview.enumerated().filter { $0.offset % 4 != 3 && $0.element > 8 }.count
        print("selftest preview lit \(previewLit)")
        print("selftest failure     \(model.failure ?? "none")")
        let url = URL(fileURLWithPath: "out/selftest.png")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? PNGWriter.write(pixels, width: 1280, height: 720, to: url)
        exit(lit > 10_000 && model.previewParticleCount > 1_000 && previewLit > 10_000 ? 0 : 1)
    }
}
