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
                case .running: RunningView(model: model)
                }
            }
            .frame(minWidth: 1100, minHeight: 720)
            // The panel draws on the system background, so the appearance is pinned rather
            // than letting a light theme put dark text on the black canvas.
            .preferredColorScheme(.dark)
            .onAppear {
                startFrameCheck()
                PresetCheck.run(model)
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
        model.start()
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

    /// Renders the panels offscreen with `ImageRenderer` so their legibility can be checked
    /// without a window server. Catches things a running app hides, such as text drawn in a
    /// colour that matches its own background.
    @MainActor
    private static func renderInterface() {
        guard let model = SimulationModel() else { exit(1) }
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        model.start()
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
        model.start()
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
        model.rebuildPreview()
        print("selftest preview     \(model.previewParticleCount) particules")
        let url = URL(fileURLWithPath: "out/selftest.png")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? PNGWriter.write(pixels, width: 1280, height: 720, to: url)
        exit(lit > 10_000 && model.previewParticleCount > 1_000 ? 0 : 1)
    }
}
