import Foundation
import SillageRender
import SwiftUI

@main
struct SillageApp: App {
    @StateObject private var model = SimulationModel()!

    init() {
        if CommandLine.arguments.contains("--selftest") {
            MainActor.assumeIsolated { SillageApp.runSelfTest() }
        }
    }

    /// Opens the real window, lets the display link run, then reports how many frames the
    /// MTKView delegate actually drew. Proves the windowed path, not just the offscreen one.
    @MainActor
    private func startFrameCheck() {
        guard CommandLine.arguments.contains("--verify") else { return }
        Task {
            try? await Task.sleep(for: .seconds(4))
            let drawn = model.framesDrawn
            let report = """
                frames drawn   \(drawn)
                frame time     \(String(format: "%.1f", model.frameMilliseconds)) ms
                particles      \(model.particleCount)
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

    /// Exercises model creation, resize, stepping and rendering without opening a window,
    /// then exits. Keeps the app path verifiable on machines where a window cannot be shown.
    @MainActor
    private static func runSelfTest() {
        guard let model = SimulationModel() else {
            FileHandle.standardError.write(Data("selftest: no Metal device\n".utf8))
            exit(1)
        }
        model.setTotalParticles(2_000_000)
        model.resize(to: CGSize(width: 1280, height: 720))
        model.frameCamera()
        guard let pixels = model.snapshot(steps: 3_000) else {
            FileHandle.standardError.write(Data("selftest: renderer unavailable\n".utf8))
            exit(1)
        }
        let lit = pixels.enumerated().filter { $0.offset % 4 != 3 && $0.element > 8 }.count
        print("selftest particles   \(model.particleCount)")
        print("selftest time        \(String(format: "%.0f", model.elapsedMyr)) Myr")
        print("selftest lit samples \(lit)")
        let url = URL(fileURLWithPath: "out/selftest.png")
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? PNGWriter.write(pixels, width: 1280, height: 720, to: url)
        print("selftest wrote       \(url.path)")
        exit(lit > 10_000 ? 0 : 1)
    }

    var body: some Scene {
        WindowGroup("Sillage") {
            HStack(spacing: 0) {
                MetalCanvas(model: model)
                    .frame(minWidth: 640, minHeight: 400)
                Divider()
                ControlPanel(model: model)
            }
            .frame(minWidth: 1100, minHeight: 700)
            .background(.black)
            .onAppear { startFrameCheck() }
        }
        .windowResizability(.contentMinSize)
    }
}
